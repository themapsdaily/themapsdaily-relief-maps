#!/usr/bin/env bash
# Overpass: Maharashtra admin boundary (admin_level=4). POST + User-Agent (bare GET 406s),
# cycle mirrors because a big-bbox state 504s on the main endpoint.
set -u
OUT=${RELIEF_MAPS_ROOT:-.}/output/maharashtra/mh_boundary.json
Q='[out:json][timeout:600];relation["boundary"="administrative"]["admin_level"="4"]["name"="Maharashtra"](15.4,72.4,22.2,81.1);out geom;'
for URL in https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== trying $URL"
  curl -sS --max-time 900 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 100000 ] && head -c 200 "$OUT" && echo && echo "OK $URL" && exit 0
  echo "failed/short on $URL"; head -c 300 "$OUT" 2>/dev/null; echo
done
echo "ALL MIRRORS FAILED"; exit 1
