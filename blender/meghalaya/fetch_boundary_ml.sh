#!/usr/bin/env bash
# Overpass: Meghalaya admin boundary (admin_level=4). POST + User-Agent (bare GET 406s);
# cycle mirrors in case the default endpoint is queued.
set -u
OUT=/Users/siddharthpetare/projects/themapsdaily-relief-maps/output/meghalaya/ml_boundary.json
Q='[out:json][timeout:300];relation["boundary"="administrative"]["admin_level"="4"]["name"="Meghalaya"](24.9,89.6,26.3,93.0);out geom;'
for URL in https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== trying $URL"
  curl -sS --max-time 600 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 100000 ] && echo "OK $URL" && exit 0
  echo "failed/short on $URL"; head -c 300 "$OUT" 2>/dev/null; echo
done
echo "ALL MIRRORS FAILED"; exit 1
