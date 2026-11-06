# Map data

- `countries.wkb.gz`: country borders, made by `tools/make_countries.py` from geo-maps
  "countries-coastline-10m" (https://github.com/simonepri/geo-maps), which is built from OpenStreetMap.
  Data © OpenStreetMap contributors, available under the Open Database License (ODbL 1.0,
  https://opendatacommons.org/licenses/odbl/1-0/). This file is a derived database and is under the
  ODbL as well. Changes: two-letter country codes, Antarctica extended to the South Pole, Crimea as Ukraine.
- `land.wkb.gz`, `lakes.wkb.gz`: Natural Earth 1:10m land and lakes (public domain), made by
  `tools/make_water.py`.
