#!/usr/bin/env bash
# Overpass: Assam WATER BODIES as TILES. Unlike the reservoir-only plateau states,
# Assam's identity IS its water: the braided Brahmaputra channel + the beels
# (Deepor, Son, Chandubi, Urpad...). So pull the full water footprint --
# natural=water AND waterway=riverbank (the mapped river surface) -- as ways and
# relations, then area-filter in the build step. Tiled + mirror-cycling because a
# whole-state natural=water query times out. VALIDATE BY PARSING: a failed tile
# still writes a file (HTML error page). Run from relief-maps/.
set -u
DIR=output/assam/water_tiles
mkdir -p "$DIR"
MIRRORS=(https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter https://overpass.kumi.systems/api/interpreter)
# 2 rows x 3 cols over (24.05,89.60)-(28.05,96.10), with a small overlap
ROWS=("24.05 26.10" "26.00 28.05")
COLS=("89.60 91.80" "91.70 93.90" "93.80 96.10")
mi=0; fail=0; n=0
for r in "${ROWS[@]}"; do
  for c in "${COLS[@]}"; do
    read -r S N <<<"$r"; read -r W E <<<"$c"
    n=$((n+1)); OUT="$DIR/tile_${n}.json"
    Q="[out:json][timeout:300];(way[\"natural\"=\"water\"]($S,$W,$N,$E);relation[\"natural\"=\"water\"]($S,$W,$N,$E);way[\"waterway\"=\"riverbank\"]($S,$W,$N,$E);relation[\"waterway\"=\"riverbank\"]($S,$W,$N,$E);way[\"water\"=\"river\"]($S,$W,$N,$E);relation[\"water\"=\"river\"]($S,$W,$N,$E););out geom;"
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
