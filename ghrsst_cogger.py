#!/usr/bin/env python3

import json
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Tuple, Union

import click
import fsspec
import xarray as xr
from odc.aws import s3_dump  # noqa: F401
from odc.geo.xr import assign_crs, write_cog
from pystac import Asset, Item, MediaType
from rio_stac import create_stac_item
from s3path import S3Path
from xarray import Dataset

COLLECTION = "ghrsst-to-change"
FILE_STRING = "{date:%Y%m%d}090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc"
JPL_BASE = "https://archive.podaac.earthdata.nasa.gov/podaac-ops-cumulus-protected/MUR-JPL-L4-GLOB-v4.1/"
VARIABLES = [
    "analysed_sst",
    "analysis_error",
    "mask",
    "sea_ice_fraction",
    "sst_anomaly",
    # "dt_1km_data",  # Not writing the datetime data
]


class GHRSSTException(Exception):
    """A base class for GHRSSTException exceptions."""


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


def get_simple_raster_info(data: Dataset, var: str):
    variable = data[var]

    scale = variable.attrs.get("scale_factor")
    offset = variable.attrs.get("add_offset")
    unit = variable.attrs.get("units")

    meta = {
        "nodata": int(variable.attrs["_FillValue"]),
        "data_type": str(variable.dtype.name),
    }

    if scale is not None:
        meta["scale"] = float(scale)
    if offset is not None:
        meta["offset"] = float(offset)
    if unit is not None:
        meta["unit"] = str(unit)

    import json

    json.dumps(meta)
    return [meta]


def load_data(date: datetime, input_location: Path) -> Dataset:
    if input_location.upper() == "JPL":
        # Handle authentication with the NASA Earthdata system
        earthdata_token = os.environ.get("EARTHDATA_TOKEN", None)
        if earthdata_token is None:
            raise GHRSSTException(
                "Please set the EARTHDATA_TOKEN environment variable in order to read from JPL"
            )
        headers = {"Authorization": f"Bearer {os.environ['EARTHDATA_TOKEN']}"}
        url_file = JPL_BASE + FILE_STRING.format(date=date)

        # Open the file
        with fsspec.open(url_file, headers=headers) as f:
            data = xr.open_dataset(f, mask_and_scale=False).load()
    else:
        data_file = Path(input_location) / FILE_STRING.format(date=date)
        data = xr.open_dataset(data_file, mask_and_scale=False)

    data = assign_crs(data, crs="EPSG:4326")
    return data


def process_data(data: Dataset) -> Dataset:
    return data


def write_data(
    data: Dataset,
    date: datetime,
    output_location: Union[Path, S3Path],
    overwrite: bool = False,
):
    if type(output_location) is not S3Path:
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

        if type(output_location) is S3Path:
            cog_file.write_bytes(write_cog(data[var], ":mem:"))
        else:
            write_cog(data[var], str(cog_file), overwrite=True)
        print(f"Wrote {var} to {cog_file}")
        written_files.append(cog_file)

    return written_files


def write_stac(
    data: Dataset,
    written_files: Tuple[Path],
    date: datetime,
    output_location: Union[Path, S3Path],
) -> Item:
    stac_file = output_location / FILE_STRING.format(date=date).replace(
        ".nc", ".stac-item.json"
    )

    first_item = written_files[0]
    base_cog = str(first_item)

    if type(first_item) is S3Path:
        base_cog = f"s3:/{first_item}"

    item = create_stac_item(
        base_cog,
        id=stac_file.stem,
        with_proj=True,
        with_raster=True,
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
                roles=["data"],
                extra_fields={"raster:bands": get_simple_raster_info(data, var)},
            )
            for var, file in zip(VARIABLES, written_files)
        },
    )

    if type(output_location) is S3Path:
        item.set_self_href(f"s3:/{stac_file}")
        s3_dump(
            data=json.dumps(item.to_dict(), indent=2),
            url=item.self_href,
            ACL="bucket-owner-full-control",
            ContentType="application/json",
        )
    else:
        item.set_self_href(str(stac_file))
        item.save_object()

    return item


def process_date(
    date: datetime,
    input_location: str,
    output_location: Union[Path, S3Path],
    overwrite: bool = False,
):
    """Process a date from a data source and output to a location

    Args:
        date (datetime): Date to process
        input_location (str): Either 'jpl' to grab data from JPL, or a local folder to find the data in
        output_location (str): Location to output results to
    """

    log = get_logger()

    log.info(
        f"Processing date {date:%Y-%m-%d} from {input_location} to {output_location}"
    )

    log.info(f"Loading data from {input_location}")
    data = load_data(date, input_location)

    log.info("Processing data...")
    processed = process_data(data)

    log.info("Writing data...")
    written_files = write_data(processed, date, output_location, overwrite)

    log.info("Writing STAC")
    stac_doc = write_stac(data, written_files, date, output_location)

    log.info(f"Wrote STAC document to: {stac_doc}")


@click.option("--date", type=str)
@click.option("--output-location", type=str)
@click.option("--input-location", type=str, default="JPL")
@click.option("--overwrite", is_flag=True, default=False)
@click.command("ghrsst-cogger")
def main(date, output_location, input_location, overwrite):
    date = datetime.strptime(date, "%Y-%m-%d")

    if output_location.startswith("s3://"):
        output_location = S3Path(output_location.replace("s3://", "/"))
    else:
        output_location = Path(output_location)

    # Only catch known exceptions, and otherwise let the program crash
    try:
        process_date(date, input_location, output_location, overwrite)
    except GHRSSTException as e:
        print(f"Failed to process date {date:%Y-%m-%d} with error {e}")
        exit(1)


if __name__ == "__main__":
    main()
