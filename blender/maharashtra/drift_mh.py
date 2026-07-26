#!/usr/bin/env python3
"""Measure label-vs-terrain drift on the WEST (Konkan) coast.
Kerala recipe: for each coastal marker read its projected pixel row out of the
render, find where land actually starts, and compare with the label's x."""
import json, subprocess, sys, csv, os
slug="maharashtra"; var="hero"
W=int(sys.argv[1]) if len(sys.argv)>1 else 1600
d=f"output/{slug}"
lp=json.load(open(f"{d}/{slug}_labelpos_{var}.json"))
img=f"{d}/{slug}_{var}.png"
rx=lp["res_x"]; scale=W/rx
COAST=["Mumbai","Alibag","Ratnagiri","Malvan"]
def row_pixels(y):
    out=subprocess.check_output(["magick",img,"-crop",f"{rx}x1+0+{int(round(y))}","+repage",
                                 "-depth","8","txt:-"],text=True)
    px=[]
    for ln in out.splitlines()[1:]:
        try: rgb=ln.split("(")[1].split(")")[0].split(",")
        except IndexError: continue
        px.append(tuple(int(v) for v in rgb[:3]))
    return px
def land_edge(px):
    run=0
    for i,(r,g,b) in enumerate(px):
        green = g>r+8 and g>b+8
        sand  = r>g>b and r>140
        if green or sand:
            run+=1
            if run>=6: return i-run+1
        else: run=0
    return None
print(f"scanning {img} ({rx}px wide), reporting at width {W}")
print(f"{'marker':12s} {'label_x':>8s} {'land_edge':>9s} {'offset_px':>9s}   verdict")
cities={r["name"]:r for r in csv.DictReader(open(f"cities/{slug}.csv"))}
for nm in COAST:
    if nm not in lp.get("cities",{}): print(f"{nm:12s}  (no labelpos)"); continue
    x,y=lp["cities"][nm]
    px=row_pixels(y); e=land_edge(px)
    if e is None: print(f"{nm:12s} {x:8.1f}   no land found"); continue
    off=x-e
    v = "ON EDGE" if -4<=off<=14 else ("IN SEA" if off<-4 else "inland")
    print(f"{nm:12s} {x*scale:8.1f} {e*scale:9.1f} {off*scale:9.1f}   {v}")
