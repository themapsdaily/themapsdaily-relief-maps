#!/usr/bin/env bash
# Re-fetch any INVALID river tile as quarters (the Maharashtra recipe).
# tile_2_1 (the NE Dibang/Anjaw corner) returned an HTML error page on every
# mirror at full tile size; quartering it clears the dispatcher timeout.
set -u
OUTD=output/arunachal_pradesh/rivers_tiles
MIRRORS=(https://overpass-api.de/api/interpreter \
         https://overpass.kumi.systems/api/interpreter \
         https://overpass.private.coffee/api/interpreter)
# tile_2_1 = lon 95.45-97.45, lat 28.05-29.45 -> 2x2 quarters
QL=(95.45 96.45 97.45); QA=(28.05 28.75 29.45)
mi=0
for i in 0 1; do for j in 0 1; do
  W=${QL[$i]}; E=${QL[$((i+1))]}; S=${QA[$j]}; N=${QA[$((j+1))]}
  F="$OUTD/tile_2_1_q${i}${j}.json"
  if [ -s "$F" ] && python3 -c "import json;json.load(open('$F'))['elements']" 2>/dev/null; then
    echo "skip q${i}${j} (good)"; continue; fi
  Q="[out:json][timeout:270];way[\"waterway\"=\"river\"](${S},${W},${N},${E});out geom;"
  for try in 0 1 2; do
    URL=${MIRRORS[$(( (mi+try) % 3 ))]}
    echo "== q${i}${j} [$S,$W,$N,$E] -> $URL"
    curl -sS --max-time 300 -X POST "$URL" \
      -H 'User-Agent: themapsdaily-relief/1.0 (contact themapsdaily@gmail.com)' \
      --data-urlencode "data=$Q" -o "$F"
    if python3 -c "import json;d=json.load(open('$F'));print('  ok',len(d['elements']),'elements')" 2>/dev/null; then break; fi
    echo "  FAILED"; sleep 15
  done
  mi=$((mi+1)); sleep 5
done; done
rm -f "$OUTD/tile_2_1.json"    # the invalid full tile, now superseded by quarters
echo "--- summary ---"
for f in "$OUTD"/*.json; do
  python3 -c "import json;d=json.load(open('$f'));print('$f',len(d['elements']))" 2>/dev/null || echo "$f INVALID"
done
