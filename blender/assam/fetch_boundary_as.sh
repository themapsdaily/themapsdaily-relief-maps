#!/usr/bin/env bash
# Overpass: Assam admin boundary (admin_level=4). POST + User-Agent (bare GET 406s),
# cycle mirrors. Run from relief-maps/. bbox padded around 89.70,24.13,96.02,27.98.
set -u
OUT=output/assam/as_boundary.json
Q='[out:json][timeout:600];relation["boundary"="administrative"]["admin_level"="4"]["name"="Assam"](24.05,89.60,28.05,96.10);out geom;'
for URL in https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== trying $URL"
  curl -sS --max-time 900 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 100000 ] && head -c 200 "$OUT" && echo && echo "OK $URL" && exit 0
  echo "failed/short on $URL"; head -c 300 "$OUT" 2>/dev/null; echo; sleep 5
done
echo "ALL MIRRORS FAILED"; exit 1
