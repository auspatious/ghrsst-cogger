#!/usr/bin/env python3

import logging
from datetime import datetime
from pathlib import Path
from typing import Tuple

import click
import xarray as xr
from odc.aws import s3_dump  # noqa: F401
from odc.geo.xr import assign_crs, write_cog
from pystac import Asset, Item, MediaType
from rio_stac import create_stac_item
from xarray import Dataset

COLLECTION = "ghrsst-to-change"
FILE_STRING = "{date:%Y%m%d}090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc"
VARIABLES = [
    "analysed_sst",
    "analysis_error",
    "mask",
    "sea_ice_fraction",
    "sst_anomaly",
    # "dt_1km_data",  # Not writing the datetime data
]


def get_logger():
    logger = logging.getLogger(__name__)
    handler = logging.StreamHandler()
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )

    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)

    return logger


class GHRSSTException(Exception):
    """A base class for GHRSSTException exceptions."""


def load_data(date: datetime, data_source: Path) -> Dataset:
    data_file = data_source / FILE_STRING.format(date=date)
    data = xr.open_dataset(data_file)
    data = assign_crs(data, crs="EPSG:4326")
    return data


def process_data(data: Dataset) -> Dataset:
    return data


def write_data(
    data: Dataset, date: datetime, output_location: Path, overwrite: bool = False
):
    if not output_location.exists():
        output_location.mkdir(parents=True)

    written_files = []
    for var in VARIABLES:
        cog_file = output_location / FILE_STRING.format(date=date).replace(
            ".nc", f"_{var}.tif"
        )
        if cog_file.exists() and not overwrite:
            print(f"Skipping {var} as it already exists")
            written_files.append(cog_file)
            continue

        print(f"Writing {var} to {cog_file}")

        write_cog(data[var], cog_file)
        written_files.append(cog_file)

    return written_files


def write_stac(
    data: Dataset, written_files: Tuple[Path], date: datetime, output_location: Path
) -> Item:
    stac_file = output_location / FILE_STRING.format(date=date).replace(
        ".nc", ".stac-item.json"
    )

    item = create_stac_item(
        str(written_files[0]),
        id=stac_file.stem,
        with_proj=True,
        input_datetime=date,
        properties={
            "start_datetime": f"{date:%Y-%m-%d}T00:00:00Z",
            "end_datetime": f"{date:%Y-%m-%d}T23:59:59Z",
        },
        assets={
            var: Asset(
                href=str(file.name),
                title=var,
                media_type=MediaType.COG,
                roles=["data"]
            )
            for var, file in zip(VARIABLES, written_files)
        },
    )

    item.set_self_href(str(stac_file))
    item.save_object()

    return item

    # For later...
    # s3_dump(
    #     data=json.dumps(item.to_dict(), indent=2),
    #     url=item.self_href,
    #     ACL="bucket-owner-full-control",
    #     ContentType="application/json",
    # )


def process_date(
    date: datetime, data_source: Path, output_location: Path, overwrite: bool = False
):
    """Process a date from a data source and output to a location

    Args:
        date (datetime): Date to process
        data_source (str): Folder to find the data in
        output_location (str): Location to output results to
    """

    log = get_logger()

    log.info(f"Processing date {date:%Y-%m-%d} from {data_source} to {output_location}")

    log.info("Loading data...")
    data = load_data(date, data_source)

    log.info("Processing data...")
    processed = process_data(data)

    log.info("Writing data...")
    written_files = write_data(processed, date, output_location)

    log.info("Writing STAC")
    stac_doc = write_stac(data, written_files, date, output_location)

    log.info(f"Wrote STAC document to: {stac_doc}")


@click.option("--date", type=str)
@click.option("--output-location", type=str)
@click.option("--data-source", type=str)
@click.option("--overwrite/--no-overwrite", is_flag=True, default=True)
@click.command("ghrsst-cogger")
def main(date, output_location, data_source, overwrite):
    print("Hello World!")

    print(date)
    print(output_location)
    print(data_source)
    print(overwrite)

    date = datetime.strptime(date, "%Y-%m-%d")
    data_source = Path(data_source)
    output_location = Path(output_location)

    # Only catch known exceptions, and otherwise let the program crash
    try:
        process_date(date, data_source, output_location, overwrite)
    except GHRSSTException as e:
        print(f"Failed to process date {date:%Y-%m-%d} with error {e}")
        exit(1)


if __name__ == "__main__":
    main()
