#!/usr/bin/env bash
# Overpass: Chhattisgarh waterway=river. 26 deg^2 bbox -- osmdata hangs, so curl
# + mirror cycling (the pipeline's standard big-bbox fallback).
set -u
OUT=/Users/siddharthpetare/projects/themapsdaily-relief-maps/output/chhattisgarh/cg_rivers.json
Q='[out:json][timeout:600];way["waterway"="river"](17.7,80.1,24.2,84.5);out geom;'
for URL in https://overpass.private.coffee/api/interpreter https://overpass-api.de/api/interpreter https://overpass.kumi.systems/api/interpreter; do
  echo "=== trying $URL"
  curl -sS --max-time 900 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
    sz=$(stat -f%z "$OUT") && echo "bytes: $sz" && [ "$sz" -gt 200000 ] && \
    python3 -c "import json,sys; d=json.load(open('$OUT')); print('ways:',len(d['elements']))" && \
    echo "OK $URL" && exit 0
  echo "failed/short on $URL"; head -c 300 "$OUT" 2>/dev/null; echo; sleep 8
done
echo "ALL MIRRORS FAILED"; exit 1
