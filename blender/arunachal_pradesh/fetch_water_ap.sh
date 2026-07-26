#!/usr/bin/env bash
# Tiled Overpass fetch for Arunachal Pradesh (bbox 5.84 x 2.72 deg).
# A single whole-state query times out on every mirror at this size, so fetch in
# tiles and cycle mirrors per tile. NOTE: a FAILED tile still writes a file, so
# never trust a tile count -- build_*.R validates by parsing (see Maharashtra).
#   usage: fetch_water_ap.sh rivers|lakes
set -u
KIND="${1:-rivers}"
OUTD=output/arunachal_pradesh/${KIND}_tiles
mkdir -p "$OUTD"
# The bbox filter must sit on EACH statement -- appending it to a union group
# ("( way[...]; relation[...]; )(bbox);") is a parse error, and Overpass returns
# a 587-byte HTML error page that looks just like a successful small response.
mkq() {  # $1=S $2=W $3=N $4=E
  case "$KIND" in
    rivers) printf '[out:json][timeout:270];way["waterway"="river"](%s,%s,%s,%s);out geom;' "$1" "$2" "$3" "$4" ;;
    lakes)  printf '[out:json][timeout:270];(way["natural"="water"](%s,%s,%s,%s);relation["natural"="water"](%s,%s,%s,%s););out geom;' \
                   "$1" "$2" "$3" "$4" "$1" "$2" "$3" "$4" ;;
    *) echo "unknown kind" >&2; exit 1 ;;
  esac
}
# 3 lon x 2 lat tiles, with a small overlap so nothing falls through a seam
LONS=(91.50 93.50 95.45 97.45)
LATS=(26.60 28.05 29.45)
MIRRORS=(https://overpass-api.de/api/interpreter \
         https://overpass.kumi.systems/api/interpreter \
         https://overpass.private.coffee/api/interpreter)
mi=0
for i in 0 1 2; do
  for j in 0 1; do
    W=${LONS[$i]}; E=${LONS[$((i+1))]}; S=${LATS[$j]}; N=${LATS[$((j+1))]}
    F="$OUTD/tile_${i}_${j}.json"
    if [ -s "$F" ] && python3 -c "import json,sys; json.load(open('$F'))['elements']" 2>/dev/null; then
      echo "skip tile_${i}_${j} (already good)"; continue
    fi
    Q="$(mkq "$S" "$W" "$N" "$E")"
    for try in 0 1 2; do
      URL=${MIRRORS[$(( (mi+try) % 3 ))]}
      echo "== tile_${i}_${j} [$S,$W,$N,$E] -> $URL"
      curl -sS --max-time 300 -X POST "$URL" \
        -H 'User-Agent: themapsdaily-relief/1.0 (contact themapsdaily@gmail.com)' \
        --data-urlencode "data=$Q" -o "$F"
      if python3 -c "import json,sys; d=json.load(open('$F')); print('  ok',len(d['elements']),'elements')" 2>/dev/null; then
        break
      fi
      echo "  FAILED ($(head -c 120 "$F" | tr -d '\n'))"; sleep 15
    done
    mi=$((mi+1)); sleep 5
  done
done
echo "--- summary ---"
for f in "$OUTD"/*.json; do
  python3 -c "import json;d=json.load(open('$f'));print('$f',len(d['elements']))" 2>/dev/null \
    || echo "$f INVALID"
done
