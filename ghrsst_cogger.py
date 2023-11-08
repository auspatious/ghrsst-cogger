#!/usr/bin/env python3

import click


@click.option('--date', type=str)
@click.option('--output-location', type=str)
@click.command("ghrsst-cogger")
def main(date, output_location):
    print('Hello World!')

    print(date)
    print(output_location)



if __name__ == '__main__':
    main()