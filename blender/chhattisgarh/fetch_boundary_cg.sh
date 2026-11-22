#!/usr/bin/env bash
# Overpass: Chhattisgarh admin boundary (admin_level=4). POST + User-Agent (bare GET 406s),
# cycle mirrors -- 4.15 x 6.31 deg is big enough to 504 the main endpoint.
set -u
OUT=${RELIEF_MAPS_ROOT:-.}/output/chhattisgarh/cg_boundary.json
Q='[out:json][timeout:600];relation["boundary"="administrative"]["admin_level"="4"]["name"="Chhattisgarh"](17.7,80.1,24.2,84.5);out geom;'
for URL in https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== trying $URL"
  curl -sS --max-time 900 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 100000 ] && head -c 200 "$OUT" && echo && echo "OK $URL" && exit 0
  echo "failed/short on $URL"; head -c 300 "$OUT" 2>/dev/null; echo; sleep 5
done
echo "ALL MIRRORS FAILED"; exit 1
