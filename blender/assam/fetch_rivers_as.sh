#!/usr/bin/env bash
# Overpass: Assam waterway=river (centerlines: Brahmaputra + tributaries).
# Single-shot curl + mirror cycling. Run from relief-maps/.
set -u
OUT=output/assam/as_rivers.json
Q='[out:json][timeout:600];way["waterway"="river"](24.05,89.60,28.05,96.10);out geom;'
for URL in https://overpass.private.coffee/api/interpreter https://overpass-api.de/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== trying $URL"
  curl -sS --max-time 900 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 200000 ] && \
    python3 -c "import json,sys; d=json.load(open('$OUT')); print('ways:',len(d['elements']))" && \
    echo "OK $URL" && exit 0
  echo "failed/short on $URL"; head -c 300 "$OUT" 2>/dev/null; echo; sleep 8
done
echo "ALL MIRRORS FAILED"; exit 1
