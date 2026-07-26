#!/usr/bin/env bash
# Overpass: Meghalaya water bodies. osmdata hangs/504s here (same as rivers), so curl + mirrors.
set -u
OUT=/Users/siddharthpetare/projects/themapsdaily-relief-maps/output/meghalaya/ml_lakes.json
Q='[out:json][timeout:270];(way["natural"="water"](25.00,89.78,26.15,92.85);relation["natural"="water"](25.00,89.78,26.15,92.85););out geom;'
for URL in https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== trying $URL"
  curl -sS --max-time 600 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 20000 ] && \
    python3 -c "import json; d=json.load(open('$OUT')); print('elements:',len(d['elements']))" && \
    echo "OK $URL" && exit 0
  echo "failed/short on $URL"; head -c 200 "$OUT" 2>/dev/null; echo; sleep 5
done
echo "ALL MIRRORS FAILED"; exit 1
