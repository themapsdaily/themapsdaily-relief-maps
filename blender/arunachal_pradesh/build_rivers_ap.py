#!/usr/bin/env python3
"""Merge the tiled Overpass river JSON into one GeoJSON, de-duplicating by way id
(tiles overlap at the seams). Refuses to build a partial layer: every tile must
parse, because a FAILED Overpass tile still writes a file (an HTML error page)
and would silently leave a hole in the drainage network."""
import json, glob, sys, os
tiles = sorted(glob.glob("output/arunachal_pradesh/rivers_tiles/tile_*.json"))
allow_partial = "--allow-partial" in sys.argv
ways, bad = {}, []
for f in tiles:
    try:
        d = json.load(open(f))
        els = d["elements"]
    except Exception as e:
        bad.append(f); continue
    for e in els:
        if e.get("type") == "way" and e.get("geometry"):
            ways[e["id"]] = e
if bad:
    print("INVALID TILES (would leave holes in the network):")
    for f in bad: print("  ", f)
    if not allow_partial:
        sys.exit("refusing to build a partial rivers layer; re-fetch or pass --allow-partial")
feats = []
for wid, e in ways.items():
    coords = [[p["lon"], p["lat"]] for p in e["geometry"]]
    if len(coords) < 2: continue
    feats.append({"type": "Feature",
                  "properties": {"id": wid, "name": e.get("tags", {}).get("name", "")},
                  "geometry": {"type": "LineString", "coordinates": coords}})
out = "output/arunachal_pradesh/ap_rivers_merged.geojson"
json.dump({"type": "FeatureCollection", "features": feats}, open(out, "w"))
print(f"tiles: {len(tiles)}  unique ways: {len(ways)}  written: {out}")
