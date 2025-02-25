# GHRSST Sea Surface Temperature Analysis

The GHRSST Level 4 MUR (Multi-scale Ultra-high Resolution) Global Foundation Sea Surface Temperature Analysis (v4.1) provides
a high-resolution, daily global assessment of ocean surface temperature. This dataset fuses observations from multiple
satellite-borne sensors (including infrared and microwave radiometers) and in situ measurements, offering a robust and
consistent picture of sea surface temperature conditions. The algorithm employs advanced interpolation and blending
techniques to fill gaps caused by cloud cover and sensor discrepancies, resulting in a seamless, 1-kilometer-resolution
global field. The “foundation” temperature represents the sea surface temperature free of diurnal warming effects,
making it particularly valuable for climate studies, numerical weather prediction, and a variety of marine applications.
The dataset is distributed by NASA’s Jet Propulsion Laboratory in collaboration with the Group for High Resolution Sea Surface
Temperature (GHRSST), and is widely used by researchers, operational agencies, and policy-makers for informed decision-making
in fields such as marine resource management, weather forecasting, and climate monitoring.

For more information, please refer to the [documentation](https://podaac.jpl.nasa.gov/dataset/MUR-JPL-L4-GLOB-v4.1).

## About this repository

The [code used to repackage this data is accessible here](https://github.com/auspatious/ghrsst-cogger).

Care has been taken to not change the source data, but just to repackage it into cloud optimised geotiffs with
STAC metadata. Each daily dataset is accessible in a `<year>/<month>/<day>` path, and file names are consistent with the
source data, e.g., `"{$Y%m%d}090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.stac-item.json`.

## Accessing data

To load a single day, you can do something like the following using Python:

```python
from pystac import Item
from odc.stac import load

path = "https://data.source.coop/ausantarctic/ghrsst-mur-v2/2025/02/09/20250209090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.stac-item.json"
item = Item.from_file(path)

data = load([item], chunks={}, anchor="center")
data
```

And then to plot it, do:

```python
sst_loaded = data["analysed_sst"].squeeze().compute()
sst_masked = sst_loaded.where(sst_loaded != -32768)

# Extract the scale and offset from the metadata
meta = item.assets["analysed_sst"].extra_fields["raster:bands"][0]
scale = meta["scale"]
offset = meta["offset"]
k_to_c = -273.15

sst_scaled = sst_masked * scale + offset + k_to_c
sst_scaled.plot.imshow(size=8, robust=True, cmap="inferno")
```

### Reading from STAC Parquet file

Alternately, you can use the STAC Parquet file as an index to all the STAC docs.

```python
import stacrs
import pystac
from odc.stac import load

url = "https://data.source.coop/ausantarctic/ghrsst-mur-v2/ghrsst-mur-v2.parquet"

center = 13, -61
year = 2025
buffer = 5

bbox = (
    center[1] - buffer,
    center[0] - buffer,
    center[1] + buffer,
    center[0] + buffer,
)

items = stacrs.read(url)  # Or use .search to filter
items = [pystac.Item.from_dict(i) for i in items["features"]]

data = load(items, bbox=bbox, chunks={})
data
```

## License

See: [https://podaac.jpl.nasa.gov/CitingPODAAC](https://podaac.jpl.nasa.gov/CitingPODAAC)

> Data hosted by the PO.DAAC is openly shared, without restriction, in accordance with NASA's Earth Science program Data and Information Policy.
