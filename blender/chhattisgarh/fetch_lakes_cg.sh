#!/usr/bin/env bash
# Overpass: Chhattisgarh RESERVOIRS, fetched as TILES.
#
# Two lessons are baked in here:
#  1. Not blanket natural=water -- over a 26 deg^2 rural bbox that pulls every
#     farm pond and paddy tank. Every significant body in this state is a
#     reservoir (Hasdeo Bango, Gangrel, Dudhawa, Tandula ...), so scope the tags.
#  2. Even the scoped query returns "Dispatcher_Client::request_read_and_idx::
#     timeout" on all three mirrors for a whole-state bbox. Tile it, cycle
#     mirrors per tile, pause between -- and VALIDATE BY PARSING: a failed tile
#     still writes a file, so a tile *count* looks complete while the content is
#     a 26 MB HTML error page.
set -u
DIR=/Users/siddharthpetare/projects/themapsdaily-relief-maps/output/chhattisgarh/lake_tiles
mkdir -p "$DIR"
MIRRORS=(https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter https://overpass.kumi.systems/api/interpreter)
# 3 rows x 2 cols over (17.7,80.1)-(24.2,84.5), with a small overlap
ROWS=("17.70 19.95" "19.85 22.10" "22.00 24.20")
COLS=("80.10 82.35" "82.25 84.50")
mi=0; fail=0; n=0
for r in "${ROWS[@]}"; do
  for c in "${COLS[@]}"; do
    read -r S N <<<"$r"; read -r W E <<<"$c"
    n=$((n+1)); OUT="$DIR/tile_${n}.json"
    Q="[out:json][timeout:300];(way[\"water\"=\"reservoir\"]($S,$W,$N,$E);way[\"landuse\"=\"reservoir\"]($S,$W,$N,$E);relation[\"water\"=\"reservoir\"]($S,$W,$N,$E);relation[\"landuse\"=\"reservoir\"]($S,$W,$N,$E););out geom;"
    ok=0
    for try in 1 2 3 4 5 6; do
      URL=${MIRRORS[$((mi % 3))]}; mi=$((mi+1))
      echo "=== tile $n ($S,$W,$N,$E) try $try -> $URL"
      if curl -sS --max-time 400 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$OUT" && \
         python3 -c "import json,sys;d=json.load(open('$OUT'));print('  elements:',len(d['elements']))" 2>/dev/null; then
        ok=1; break
      fi
      echo "  failed; pausing"; sleep 20
    done
    [ "$ok" -eq 1 ] || { echo "TILE $n FAILED ON ALL MIRRORS"; fail=1; }
    sleep 6
  done
done
[ "$fail" -eq 0 ] && echo "ALL TILES OK" || { echo "SOME TILES FAILED -- refusing to build a partial layer"; exit 2; }
