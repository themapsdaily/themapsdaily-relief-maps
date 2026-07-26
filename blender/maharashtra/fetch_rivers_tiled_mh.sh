#!/usr/bin/env bash
# Maharashtra's 8.7x6.8 deg bbox blows Overpass's dispatcher timeout on a single
# waterway=river query ("server is probably too busy"). Fetch it as 9 tiles
# instead, cycling mirrors per tile, with a pause between tiles so we never
# hammer one endpoint.
set -u
D=/Users/siddharthpetare/projects/themapsdaily-relief-maps/output/maharashtra/rivertiles
mkdir -p "$D"
LATS=(15.4 17.67 19.94 22.2); LONS=(72.4 75.3 78.2 81.1)
fail=0
for i in 0 1 2; do for j in 0 1 2; do
  f="$D/r_${i}_${j}.json"
  [ -s "$f" ] && grep -q '"elements"' "$f" && { echo "skip tile $i$j (cached)"; continue; }
  S=${LATS[$i]}; N=${LATS[$((i+1))]}; W=${LONS[$j]}; E=${LONS[$((j+1))]}
  Q="[out:json][timeout:600];way[\"waterway\"=\"river\"]($S,$W,$N,$E);out geom;"
  ok=0
  for URL in https://overpass.private.coffee/api/interpreter https://overpass-api.de/api/interpreter https://overpass.kumi.systems/api/interpreter; do
    echo "tile $i$j ($S,$W,$N,$E) <- $URL"
    curl -sS --max-time 900 -A "themapsdaily-relief/1.0" -X POST -d "data=$Q" "$URL" -o "$f"
    sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 2000 ] && grep -q '"elements"' "$f"; then echo "  OK $sz bytes"; ok=1; break; fi
    echo "  fail ($sz bytes)"; sleep 20
  done
  [ "$ok" = 1 ] || { echo "TILE $i$j FAILED"; fail=1; }
  sleep 15
done; done
echo "done (fail=$fail)"; ls -la "$D"
