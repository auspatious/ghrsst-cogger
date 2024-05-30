#!/usr/bin/env python3

import json
import logging
import os
from datetime import datetime
from logging import Logger
from pathlib import Path
from typing import Tuple, Union

import click
import fsspec
import xarray as xr
from affine import Affine
from aiohttp.client_exceptions import ClientResponseError
from odc.aws import s3_dump  # noqa: F401
from odc.geo.cog import write_cog
from odc.geo.geobox import GeoBox
from odc.geo.xr import assign_crs, xr_coords
from pystac import Asset, Item, MediaType
from rio_stac import create_stac_item
from s3path import S3Path
from xarray import Dataset

COLLECTION = "ghrsst-mur-v2"
FILE_STRING = "{date:%Y%m%d}090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc"
FOLDER_PATH = "{date:%Y}/{date:%m}/{date:%d}"
JPL_BASE = "https://archive.podaac.earthdata.nasa.gov/podaac-ops-cumulus-protected/MUR-JPL-L4-GLOB-v4.1/"
VARIABLES = [
    "analysed_sst",
    "analysis_error",
    "mask",
    "sea_ice_fraction",
    "sst_anomaly",
    "dt_1km_data",
]
# Not loading or writing the datetime data
DROP_VARIABLES = ["dt_1km_data"]
VARIABLES = [var for var in VARIABLES if var not in DROP_VARIABLES]
COG_OPTS = dict(compress="zstd")


class GHRSSTException(Exception):
    """A base class for GHRSSTException exceptions."""


def _is_s3_path(path: Union[Path, S3Path]) -> bool:
    return isinstance(path, S3Path)


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


def get_output_path(
    output_location: Union[Path, S3Path], date: datetime, extension: str
):
    return (
        output_location
        / FOLDER_PATH.format(date=date)
        / FILE_STRING.format(date=date).replace(".nc", extension)
    )


def get_input_path(input_location: str, date: datetime) -> str:
    if input_location.upper() == "JPL":
        return JPL_BASE + FILE_STRING.format(date=date)
    else:
        return str(Path(input_location) / FILE_STRING.format(date=date))


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

    return [meta]


def load_data(date: datetime, input_location: Path) -> Dataset:
    input_path = get_input_path(input_location, date)
    if input_location.upper() == "JPL":
        # Handle authentication with the NASA Earthdata system
        earthdata_token = os.environ.get("EARTHDATA_TOKEN", None)
        if earthdata_token is None:
            raise GHRSSTException(
                "Please set the EARTHDATA_TOKEN environment variable in order to read from JPL"
            )
        headers = {"Authorization": f"Bearer {os.environ['EARTHDATA_TOKEN']}"}

        # Open the file
        try:
            with fsspec.open(input_path, headers=headers) as f:
                data = xr.open_dataset(
                    f,
                    mask_and_scale=False,
                    drop_variables=DROP_VARIABLES,
                    engine="h5netcdf",
                ).load()
        except ClientResponseError as e:
            raise GHRSSTException(
                f"Failed to open {input_path} with error {e}. Please check your EARTHDATA_TOKEN."
            )
        # Don't catch this here. Catch it elsewhere and handle differently.
        # except FileNotFoundError as e:
        #     raise GHRSSTException(f"File not found for {input_path} with error {e}")
    else:
        data = xr.open_dataset(
            input_path, mask_and_scale=False, drop_variables=DROP_VARIABLES
        )

    data = assign_crs(data, crs="EPSG:4326")
    return data


def process_data(data: Dataset) -> Dataset:
    # Set up a new Affine and GeoBox
    new_affine = Affine(0.01, 0.0, -180.0, 0.0, -0.01, 89.995, 0.0, 0.0, 1.0)
    new_geobox = GeoBox(data.odc.geobox.shape, new_affine, data.odc.geobox.crs)

    # First flip the dataset
    data = data.reindex(lat=data.lat[::-1])

    # Update the coordinates of the xarray to be precise
    data = data.assign_coords(xr_coords(new_geobox))

    # Update SST metadata to be in celcius
    data["analysed_sst"].attrs["units"] = "celsius"
    data["analysed_sst"].attrs["add_offset"] = 25
    data["sst_anomaly"].attrs["units"] = "celsius"
    data["analysis_error"].attrs["units"] = "celsius"

    return data


def write_data(
    data: Dataset,
    date: datetime,
    output_location: Union[Path, S3Path],
    overwrite: bool = False,
    log: Logger | None = None,
):
    if not _is_s3_path(output_location):
        if not output_location.exists():
            output_location.mkdir(parents=True)

    written_files = []
    for var in VARIABLES:
        cog_file = get_output_path(output_location, date, f"_{var}.tif")

        if cog_file.exists() and not overwrite:
            log.info(f"Skipping {var} as it already exists")
            written_files.append(cog_file)
            continue

        data_var = data[var]
        # Rename to GDAL/ODC standard names
        data_var.attrs["scales"] = data_var.attrs.get("scale_factor")
        data_var.attrs["offsets"] = data_var.attrs.get("add_offset")
        data_var.attrs["units"] = data_var.attrs.get("units")
        data_var.attrs["nodata"] = data_var.attrs.get("_FillValue")

        if not _is_s3_path(cog_file.parent):
            cog_file.parent.mkdir(parents=True, exist_ok=True)

        cog_file.write_bytes(write_cog(data_var, ":mem:", **COG_OPTS))

        if log is not None:
            log.info(f"Wrote {var} to {cog_file}")

        written_files.append(cog_file)

    return written_files


def write_stac(
    data: Dataset,
    written_files: Tuple[Path],
    date: datetime,
    output_location: Union[Path, S3Path],
) -> Item:
    stac_file = get_output_path(output_location, date, ".stac-item.json")

    first_item = written_files[0]
    base_cog = str(first_item)

    if _is_s3_path(first_item):
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

    if _is_s3_path(output_location):
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
    log: logging.Logger = None,
):
    """Process a date from a data source and output to a location

    Args:
        date (datetime): Date to process
        input_location (str): Either 'jpl' to grab data from JPL, or a local folder to find the data in
        output_location (str): Location to output results to
    """
    if log is None:
        log = get_logger()

    log.info(
        f"Processing date {date:%Y-%m-%d} from {input_location} to {output_location}"
    )

    # Check if we've done this date already
    stac_file = get_output_path(output_location, date, ".stac-item.json")
    if stac_file.exists() and not overwrite:
        log.info(f"Skipping {date:%Y-%m-%d} as it already exists")
    else:
        input_path = get_input_path(input_location, date)
        log.info(f"Loading data from {input_path}")
        data = load_data(date, input_location)

        log.info("Processing data...")
        processed = process_data(data)

        log.info(f"Writing data to {output_location}")
        written_files = write_data(processed, date, output_location, overwrite, log=log)

        log.info("Writing STAC")
        stac_doc = write_stac(data, written_files, date, output_location)

        log.info(f"Finished writing to: {stac_doc.self_href}")


def lambda_handler(event, _):
    # Set up a tidy logger
    log = get_logger()
    log.info(f"Event: {event}")

    date_str = None
    for record in event["Records"]:
        event_source = record.get("eventSource")
        if event_source is not None and event_source == "aws:sqs":
            message = json.loads(record["body"])
            log.info(message)
            # Get the date from the message
            date_str = message["date"]
        else:
            log.error(f"No SQS message found, only {record}")

    if date_str is not None:
        date = datetime.strptime(date_str, "%Y-%m-%d")
        output_location = os.environ.get(
            "OUTPUT_LOCATION", "s3://files.auspatious.com/ghrsst/"
        )
        output_location = S3Path(output_location.replace("s3://", "/"))
        input_location = "JPL"
        overwrite = os.environ.get("OVERWRITE", "False").lower() == "true"

        try:
            process_date(date, input_location, output_location, overwrite, log=log)
        except FileNotFoundError as e:
            log.error(f"Couldn't find file for date {date:%Y-%m-%d} with error {e}")
    else:
        raise GHRSSTException("No date found in event, exiting")


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
    except FileNotFoundError as e:
        print(f"Couldn't find file for date {date:%Y-%m-%d} from {e}")


if __name__ == "__main__":
    main()
