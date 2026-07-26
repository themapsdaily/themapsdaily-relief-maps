#!/usr/bin/env python3
"""Merge the 9 Overpass river tiles into one GeoJSON, de-duplicating ways that
appear in more than one tile (tiles overlap at their shared edges). Tiles that
are still downloading, truncated, or an Overpass HTML error page are skipped
with a warning rather than killing the merge."""
import json, glob, os, sys
seen=set(); feats=[]; bad=[]
files=sorted(glob.glob("output/maharashtra/rivertiles/r_*.json"))
for f in files:
    try:
        d=json.load(open(f))
    except Exception as e:
        bad.append((os.path.basename(f), f"unreadable: {type(e).__name__}")); continue
    if "elements" not in d:
        bad.append((os.path.basename(f), "no elements key")); continue
    n=0
    for e in d["elements"]:
        if e.get("type")!="way" or not e.get("geometry"): continue
        if e["id"] in seen: continue
        seen.add(e["id"])
        g=[[p["lon"],p["lat"]] for p in e["geometry"] if p]
        if len(g)<2: continue
        t=e.get("tags") or {}
        feats.append({"type":"Feature","properties":{"name":t.get("name:en") or t.get("name") or ""},
                      "geometry":{"type":"LineString","coordinates":g}})
        n+=1
    print(f"  {os.path.basename(f)}: +{n} ways")
for b in bad: print(f"  !! {b[0]}: {b[1]}")
print(f"tiles used {len(files)-len(bad)}/9, unique river ways {len(feats)}")
if bad and "--allow-partial" not in sys.argv:
    print("REFUSING to write a partial river layer (pass --allow-partial to override)"); sys.exit(2)
json.dump({"type":"FeatureCollection","features":feats},
          open("output/maharashtra/mh_rivers_merged.geojson","w"))
print("wrote mh_rivers_merged.geojson")
