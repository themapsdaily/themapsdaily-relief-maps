#!/usr/bin/env python3
"""Merge tiled Overpass natural=water into one GeoJSON of polygons.
Ways -> closed rings. Relations (multipolygons) -> their `outer` member rings.
De-duplicates by (type,id) because tiles overlap at the seams. Refuses to build
a partial layer unless --allow-partial: a failed Overpass tile still writes a
file, so a tile COUNT looks complete while the content is an HTML error page."""
import json, glob, sys
tiles = sorted(glob.glob("output/arunachal_pradesh/lakes_tiles/tile_*.json"))
allow = "--allow-partial" in sys.argv
seen, feats, bad = set(), [], []
def ring(geom):
    c = [[p["lon"], p["lat"]] for p in geom]
    if len(c) < 4: return None
    if c[0] != c[-1]: c.append(c[0])
    return c
for f in tiles:
    try: els = json.load(open(f))["elements"]
    except Exception: bad.append(f); continue
    for e in els:
        key = (e["type"], e["id"])
        if key in seen: continue
        seen.add(key)
        name = e.get("tags", {}).get("name", "")
        wtype = e.get("tags", {}).get("water", "")
        if e["type"] == "way" and e.get("geometry"):
            r = ring(e["geometry"])
            if r: feats.append({"type":"Feature","properties":{"name":name,"water":wtype},
                                "geometry":{"type":"Polygon","coordinates":[r]}})
        elif e["type"] == "relation":
            outers = [ring(m["geometry"]) for m in e.get("members", [])
                      if m.get("role") == "outer" and m.get("geometry")]
            for r in [o for o in outers if o]:
                feats.append({"type":"Feature","properties":{"name":name,"water":wtype},
                              "geometry":{"type":"Polygon","coordinates":[r]}})
if bad:
    print("INVALID TILES:"); [print("  ", b) for b in bad]
    if not allow: sys.exit("refusing to build a partial lakes layer (use --allow-partial)")
out = "output/arunachal_pradesh/ap_lakes_merged.geojson"
json.dump({"type":"FeatureCollection","features":feats}, open(out,"w"))
print(f"tiles {len(tiles)}  unique elements {len(seen)}  polygons {len(feats)} -> {out}")
