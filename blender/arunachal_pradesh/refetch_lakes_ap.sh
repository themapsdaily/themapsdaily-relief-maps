#!/usr/bin/env bash
# Re-fetch any INVALID lakes tile as quarters. natural=water over a 2deg x 1.45deg
# tile is heavy in Arunachal (very dense river-area polygons) and trips the
# Overpass dispatcher timeout; quartering clears it, same as the rivers recipe.
set -u
OUTD=output/arunachal_pradesh/lakes_tiles
MIRRORS=(https://overpass-api.de/api/interpreter \
         https://overpass.kumi.systems/api/interpreter \
         https://overpass.private.coffee/api/interpreter)
LONS=(91.50 93.50 95.45 97.45); LATS=(26.60 28.05 29.45)
mi=0
for i in 0 1 2; do for j in 0 1; do
  F="$OUTD/tile_${i}_${j}.json"
  python3 -c "import json;json.load(open('$F'))['elements']" 2>/dev/null && continue
  W=${LONS[$i]}; E=${LONS[$((i+1))]}; S=${LATS[$j]}; N=${LATS[$((j+1))]}
  MW=$(python3 -c "print(($W+$E)/2)"); MS=$(python3 -c "print(($S+$N)/2)")
  echo "== quartering tile_${i}_${j}"
  for qi in 0 1; do for qj in 0 1; do
    QW=$([ $qi -eq 0 ] && echo $W || echo $MW); QE=$([ $qi -eq 0 ] && echo $MW || echo $E)
    QS=$([ $qj -eq 0 ] && echo $S || echo $MS); QN=$([ $qj -eq 0 ] && echo $MS || echo $N)
    QF="$OUTD/tile_${i}_${j}_q${qi}${qj}.json"
    if [ -s "$QF" ] && python3 -c "import json;json.load(open('$QF'))['elements']" 2>/dev/null; then
      echo "  skip q${qi}${qj}"; continue; fi
    Q="[out:json][timeout:270];(way[\"natural\"=\"water\"](${QS},${QW},${QN},${QE});relation[\"natural\"=\"water\"](${QS},${QW},${QN},${QE}););out geom;"
    for try in 0 1 2; do
      URL=${MIRRORS[$(( (mi+try) % 3 ))]}
      echo "  q${qi}${qj} [$QS,$QW,$QN,$QE] -> ${URL#https://}"
      curl -sS --max-time 300 -X POST "$URL" -H 'User-Agent: themapsdaily-relief/1.0' \
        --data-urlencode "data=$Q" -o "$QF"
      python3 -c "import json;d=json.load(open('$QF'));print('    ok',len(d['elements']))" 2>/dev/null && break
      echo "    FAILED"; sleep 15
    done
    mi=$((mi+1)); sleep 5
  done; done
  rm -f "$F"
done; done
echo "--- summary ---"
for f in "$OUTD"/*.json; do
  python3 -c "import json;d=json.load(open('$f'));print('$(basename $f)',len(d['elements']))" 2>/dev/null || echo "$(basename $f) INVALID"
done
