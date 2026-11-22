#!/usr/bin/env bash
# Tiles 20 and 22 (the northern strip) failed on every mirror at 2.26x2.9 deg.
# Split each into quarters -- a smaller bbox is far likelier to clear Overpass's
# dispatcher timeout -- and pause generously so we never hammer one endpoint.
set -u
D=${RELIEF_MAPS_ROOT:-.}/output/maharashtra/rivertiles
mkdir -p "$D"
fetch() { # name S W N E
  local nm=$1 S=$2 W=$3 N=$4 E=$5 f="$D/r_$1.json"
  [ -s "$f" ] && grep -q '"elements"' "$f" && { echo "skip $nm (cached)"; return 0; }
  local Q="[out:json][timeout:600];way[\"waterway\"=\"river\"]($S,$W,$N,$E);out geom;"
  for URL in https://overpass.private.coffee/api/interpreter https://overpass-api.de/api/interpreter https://overpass.kumi.systems/api/interpreter; do
    echo "$nm <- $URL"
    curl -sS --max-time 900 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$f"
    local sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 2000 ] && grep -q '"elements"' "$f"; then echo "  OK $sz"; sleep 25; return 0; fi
    echo "  fail ($sz)"; rm -f "$f"; sleep 45
  done
  echo "  !! $nm FAILED ALL MIRRORS"; return 1
}
fetch 20a 19.94 72.40 21.07 73.85
fetch 20b 19.94 73.85 21.07 75.30
fetch 20c 21.07 72.40 22.20 73.85
fetch 20d 21.07 73.85 22.20 75.30
fetch 22a 19.94 78.20 21.07 79.65
fetch 22b 19.94 79.65 21.07 81.10
fetch 22c 21.07 78.20 22.20 79.65
fetch 22d 21.07 79.65 22.20 81.10
echo "REFETCH DONE"; ls "$D" | tr '\n' ' '
