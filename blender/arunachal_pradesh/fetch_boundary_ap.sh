#!/usr/bin/env bash
# Fetch the high-detail OSM admin boundary for Arunachal Pradesh.
# india-2021.geojson carries only 452 vertices for a state with an extremely
# intricate Himalayan foothill + McMahon Line border -> visibly "squary".
# POST (bare GET 406s) with a User-Agent, cycling mirrors.
set -u
OUT=output/arunachal_pradesh/ap_boundary_raw.json
Q='[out:json][timeout:270];relation["boundary"="administrative"]["admin_level"="4"]["name"="Arunachal Pradesh"](26.0,91.0,30.0,98.0);out geom;'
for URL in https://overpass-api.de/api/interpreter \
           https://overpass.private.coffee/api/interpreter \
           https://overpass.kumi.systems/api/interpreter; do
  echo "== $URL"
  curl -sS --max-time 300 -X POST "$URL" \
    -H 'User-Agent: themapsdaily-relief/1.0 (contact themapsdaily@gmail.com)' \
    --data-urlencode "data=$Q" -o "$OUT"
  if head -c 200 "$OUT" | grep -q '"elements"'; then
    echo "OK $(wc -c < "$OUT") bytes"; exit 0
  fi
  echo "FAILED: $(head -c 200 "$OUT")"; sleep 20
done
echo "ALL MIRRORS FAILED"; exit 1
