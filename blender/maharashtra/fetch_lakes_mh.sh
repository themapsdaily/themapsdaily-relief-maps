#!/usr/bin/env bash
set -u
OUT=${RELIEF_MAPS_ROOT:-.}/output/maharashtra/mh_lakes.json
# Maharashtra's signature water = big RESERVOIRS (Koyna/Shivsagar, Jayakwadi, Ujani,
# Isapur, Totladoh, Gosikhurd). A blanket natural=water over an 8.25x6.42 deg bbox
# would pull every farm pond, so restrict to reservoirs + water RELATIONS (big
# multipolygon bodies) and filter by area in R.
Q='[out:json][timeout:900];(way["natural"="water"]["water"="reservoir"](15.4,72.4,22.2,81.1);relation["natural"="water"]["water"="reservoir"](15.4,72.4,22.2,81.1);way["landuse"="reservoir"](15.4,72.4,22.2,81.1);relation["landuse"="reservoir"](15.4,72.4,22.2,81.1);relation["natural"="water"](15.4,72.4,22.2,81.1););out geom;'
for URL in https://overpass.private.coffee/api/interpreter https://overpass-api.de/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== lakes via $URL"
  curl -sS --max-time 1200 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 200000 ] && echo "OK $URL" && exit 0
  echo "failed/short"; head -c 300 "$OUT" 2>/dev/null; echo
done
echo "ALL MIRRORS FAILED"; exit 1
