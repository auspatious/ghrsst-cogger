import click
from cogger import GHRSSTException, get_output_path

from s3path import S3Path
import stacrs

from datetime import datetime, timedelta

def create_parquet(start_date: str, end_date: str, input_location: str, output_location: str) -> int:
    dates = [start_date + timedelta(days=i) for i in range((end_date - start_date).days + 1)]

    location = S3Path(input_location)
    hrefs = []

    for date in dates:
        path = get_output_path(location, date, ".stac-item.json")
        href = str(path).replace(input_location, "https://data.source.coop/ausantarctic/ghrsst-mur-v2")

        hrefs.append(href)

    items = [stacrs.read(href) for href in hrefs]

    # Write items to parquet
    output_location = output_location.replace("s3:/", "s3://")
    out = f"{output_location}/ghrsst-mur-v2.parquet"
    print(f"Writing to {out}")
    stacrs.write(out, items)

    return len(items)

@click.option("--start-date", type=str)
@click.option("--end-date", type=str)
@click.option("--input-location", type=str, default="s3://ausantarctic/ghrsst-mur-v2")
@click.option("--output-location", type=str, default=None)
@click.command("create-parquet")
def main(start_date, end_date, input_location, output_location):
    start_date = datetime.strptime(start_date, "%Y-%m-%d")
    end_date = datetime.strptime(end_date, "%Y-%m-%d")

    input_location = input_location.replace("s3://", "s3:/")

    if output_location is None:
        output_location = input_location
    else:
        output_location = output_location.replace("s3://", "s3:/")

    # Only catch known exceptions, and otherwise let the program crash
    try:
        result = create_parquet(
            start_date=start_date,
            end_date=end_date,
            input_location=input_location,
            output_location=output_location,
        )

        click.echo(f"Created parquet with {result} rows, writing to {output_location}")
    except GHRSSTException as e:
        print(f"Failed to create parquet with error {e}")
        exit(1)


if __name__ == "__main__":
    main()
