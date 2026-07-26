#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# make_labels.py — render a transparent label layer (city + peak names) that
# registers pixel-perfect with the Blender relief render.
#
#   python3 blender/make_labels.py <slug> [--width 3200]
#
# Reads output/<slug>_view.json (written by relief.py: the exact ortho camera
# projection), cities/<slug>.csv (name,lat,long,capital) and
# peaks/<slug>.csv (name,lat,long,elev_m). Projects each lat/long to a pixel
# with the same math the render used, then draws the text with ImageMagick
# using the Inter font, tightened character spacing (negative -kerning), a
# small marker and a soft white halo for legibility.
#
# Outputs:
#   output/<slug>_labels.png  transparent label layer at the target width
#   output/<slug>_final.png   base render (upscaled) with labels composited on
# ---------------------------------------------------------------------------
import json, csv, os, sys, subprocess, argparse

ap = argparse.ArgumentParser()
ap.add_argument("slug")
ap.add_argument("--width", type=int, default=3200, help="label layer width px (4K-class)")
ap.add_argument("--variant", default="blender", help="render variant: blender (top-down) | hero | ...")
args = ap.parse_args()
slug = args.slug
variant = args.variant

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, ".."))
outdir = os.path.join(root, "output", slug)   # per-state subfolder
os.makedirs(outdir, exist_ok=True)
fdir = os.path.join(root, "fonts")
INTER = {400: os.path.join(fdir, "Inter-400.ttf"),
         600: os.path.join(fdir, "Inter-600.ttf"),
         700: os.path.join(fdir, "Inter-700.ttf")}

# per-variant paths (variant "blender" keeps the original unsuffixed outputs)
base_png = os.path.join(outdir, f"{slug}_{variant}.png")
lp_path = os.path.join(outdir, f"{slug}_labelpos_{variant}.json")
tag = "" if variant == "blender" else f"_{variant}"

# label pixel positions come from Blender (tilt-aware); fall back to top-down math
labelpos = json.load(open(lp_path)) if os.path.exists(lp_path) else None
_vp = os.path.join(outdir, f"{slug}_view.json")
view = json.load(open(_vp)) if os.path.exists(_vp) else None
TW = args.width
_ry, _rx = (labelpos["res_y"], labelpos["res_x"]) if labelpos else (view["res_y"], view["res_x"])
TH = round(_ry * TW / _rx)
posscale = TW / _rx

def project(lat, lon):                              # top-down fallback (no labelpos)
    ppu = TW / view["ortho_scale"]
    u = (lon - view["xmin"]) / (view["xmax"] - view["xmin"])
    v = (lat - view["ymin"]) / (view["ymax"] - view["ymin"])
    return TW / 2 + (u - 0.5) * view["aspect"] * ppu, TH / 2 - (v - 0.5) * ppu

def pos(kind, name, lat, lon):
    if labelpos and name in labelpos.get(kind, {}):
        x, y = labelpos[kind][name]; return x * posscale, y * posscale
    if view is None:            # tilted hero has no top-down fallback
        print(f"[labels] WARN: no position for {kind}/{name} (not in labelpos); skipping")
        return None
    return project(lat, lon)

DARK = "#2b2b2b"          # label ink (also peak elevation — black reads on white snow)
CAP = "#6E1616"           # capital accent
LAKE = "#1C6091"          # lake / river / estuary / falls name (deep water blue)
GLAC = "#3C4A50"          # glacier name (cool slate, reads on snow)
SAND = "#7A5210"          # beach name (deep golden sand, reads over the light coast)
FEATCOL = {"lake": LAKE, "river": LAKE, "estuary": LAKE, "falls": LAKE,
           "beach": SAND, "glacier": GLAC}
def S(frac): return max(9, int(round(frac * TW)))   # size as fraction of width

def sh(*a): subprocess.run([str(x) for x in a], check=True)
def ident(p): return tuple(int(v) for v in subprocess.check_output(
    ["magick", "identify", "-format", "%w %h", p]).split())

TMP = os.path.join(outdir, "_labeltmp"); os.makedirs(TMP, exist_ok=True)
_n = [0]
def chip(text, weight, size, color):
    """Render one text run (Inter, tight kerning) + soft white halo.
    Returns (path, pad, w, h): pad = transparent halo border, so callers can
    anchor by the VISIBLE text edge (chip inset by pad on every side)."""
    _n[0] += 1
    p = os.path.join(TMP, f"c{_n[0]}.png")
    kern = -0.03 * size                              # reduced character spacing
    blur = max(2, int(size * 0.12))
    pad = blur + max(3, int(size * 0.08))            # just enough room for the halo
    sh("magick", "-background", "none", "-font", INTER[weight], "-pointsize", size,
       "-kerning", f"{kern:.2f}", "-fill", color, f"label:{text}",
       "-bordercolor", "none", "-border", pad,
       "(", "+clone", "-channel", "A", "-blur", f"0x{blur}",
       "-level", "0,55%", "+channel", "-fill", "white", "-colorize", "100", ")",
       "+swap", "-compose", "over", "-composite", p)
    w, h = ident(p)
    return p, pad, w, h

# ---- collect labels -------------------------------------------------------
cities, peaks = [], []
cpath = os.path.join(root, "cities", f"{slug}.csv")
if os.path.exists(cpath):
    for r in csv.DictReader(open(cpath)):
        cities.append((r["name"], float(r["lat"]), float(r["long"]), r.get("capital", "0") == "1",
                       (r.get("side") or "right").strip().lower()))
ppath = os.path.join(root, "peaks", f"{slug}.csv")
if os.path.exists(ppath):
    for r in csv.DictReader(open(ppath)):
        peaks.append((r["name"], float(r["lat"]), float(r["long"]), r.get("elev_m", ""),
                      (r.get("place") or "").strip().lower()))   # place=above|below overrides alternation
features = []
fpath = os.path.join(root, "features", f"{slug}.csv")   # lakes / glaciers (area labels)
if os.path.exists(fpath):
    for r in csv.DictReader(open(fpath)):
        features.append((r["name"], float(r["lat"]), float(r["long"]), r.get("type", "lake"),
                         (r.get("place") or "").strip().lower()))   # beach: above|below (default below)

# ---- master transparent canvas -------------------------------------------
master = os.path.join(outdir, f"{slug}{tag}_labels.png")
sh("magick", "-size", f"{TW}x{TH}", "xc:none", master)

def comp(path, x, y):
    sh("magick", master, path, "-geometry", f"+{int(round(x))}+{int(round(y))}",
       "-composite", master)

def center_vbottom(c, cx, vbottom):
    """chip centred on cx, its VISIBLE bottom at vbottom"""
    path, pad, w, h = c; comp(path, cx - w / 2, vbottom - h + pad)

def center_vtop(c, cx, vtop):
    """chip centred on cx, its VISIBLE top at vtop"""
    path, pad, w, h = c; comp(path, cx - w / 2, vtop - pad)

def right_vcenter(c, left_x, mid_y):
    """chip with its VISIBLE left edge at left_x, vertically centred on mid_y"""
    path, pad, w, h = c; comp(path, left_x - pad, mid_y - h / 2)

def left_vcenter(c, right_x, mid_y):
    """chip with its VISIBLE right edge at right_x, vertically centred on mid_y
    (text extends leftward — use when a marker to the east would collide)."""
    path, pad, w, h = c; comp(path, right_x - w + pad, mid_y - h / 2)

def dot(cx, cy, r, color):
    sh("magick", master, "-stroke", "white", "-strokewidth", max(1, int(r*0.35)),
       "-fill", color, "-draw", f"circle {cx:.1f},{cy:.1f} {cx:.1f},{cy-r:.1f}", master)

def triangle(cx, cy, r, color):
    pts = f"{cx:.1f},{cy-r:.1f} {cx-r:.1f},{cy+r*0.85:.1f} {cx+r:.1f},{cy+r*0.85:.1f}"
    sh("magick", master, "-stroke", "white", "-strokewidth", max(1, int(r*0.3)),
       "-fill", color, "-draw", f"polygon {pts}", master)

Gm = 0.0022 * TW      # dot -> name gap (cities)
Gv = 0.0016 * TW      # marker -> block gap (peaks)
INNER = 0.0007 * TW   # name <-> elevation gap

# features: lakes/rivers/falls = centred area label on the point (no marker);
# beaches = small sand dot on the shore + name below (so they anchor to the coast).
for name, lat, lon, ftype, place in features:
    p = pos("features", name, lat, lon)
    if p is None: continue
    cx, cy = p
    col = FEATCOL.get(ftype, GLAC)
    if ftype == "beach":
        r = S(0.0034)
        dot(cx, cy, r, col)
        c = chip(name, 600, S(0.0118), col)
        if place == "above":                         # dodge a town label sitting just below
            center_vbottom(c, cx, cy - r - Gv)
        else:
            center_vtop(c, cx, cy + r + Gv)          # name just below the shore dot
    else:
        path, pad, w, h = chip(name, 600, S(0.0122), col)
        comp(path, cx - w / 2, cy - h / 2)

# cities: dot + name to the RIGHT, vertically centred on the dot
for name, lat, lon, cap, side in cities:
    p = pos("cities", name, lat, lon)
    if p is None: continue
    cx, cy = p
    r = S(0.006 if cap else 0.0042)
    dot(cx, cy, r, CAP if cap else DARK)
    c = chip(name, 700 if cap else 600, S(0.017 if cap else 0.0132), DARK)
    if side == "left":
        left_vcenter(c, cx - r - Gm, cy)          # name to the LEFT of the dot
    else:
        right_vcenter(c, cx + r + Gm, cy)

# peaks: triangle + tight NAME / elevation block, alternating above/below
# (sorted by lon) so neighbouring summits don't collide.
for i, (name, lat, lon, elev, place) in enumerate(sorted(peaks, key=lambda p: p[2])):
    p = pos("peaks", name, lat, lon)
    if p is None: continue
    cx, cy = p
    r = S(0.0052)
    triangle(cx, cy, r, DARK)
    nc = chip(name.upper(), 600, S(0.0118), DARK)
    ec = chip(f"{elev} m", 400, S(0.0085), DARK) if elev else None
    nvis = nc[3] - 2 * nc[1]
    above = (place == "above") if place in ("above", "below") else (i % 2 == 0)
    if above:                                         # block ABOVE the marker
        if ec:
            evis = ec[3] - 2 * ec[1]
            eb = cy - r - Gv
            center_vbottom(ec, cx, eb)               # elevation just above triangle
            center_vbottom(nc, cx, eb - evis - INNER)  # name above elevation
        else:
            center_vbottom(nc, cx, cy - r - Gv)
    else:                                            # block BELOW the marker
        nt = cy + r + Gv
        center_vtop(nc, cx, nt)                      # name just below triangle
        if ec:
            center_vtop(ec, cx, nt + nvis + INNER)   # elevation below name

# ---- composited preview over the (upscaled) base render -------------------
final = os.path.join(outdir, f"{slug}{tag}_final.png")
if os.path.exists(base_png):
    # 8-bit + stripped + max compression: the base render is 16-bit RGBA (huge);
    # the composited deliverable has no need for 16-bit -> ~15 MB not ~80 MB, no
    # visible loss. Alpha kept so BL_GROUND=0 transparent-cutout renders survive.
    sh("magick", base_png, "-resize", f"{TW}x{TH}!", master, "-composite",
       "-depth", "8", "-strip", "-define", "png:compression-level=9", final)

# cleanup temp chips
for f in os.listdir(TMP):
    os.remove(os.path.join(TMP, f))
os.rmdir(TMP)
print(f"[labels] {slug}: {len(cities)} cities + {len(peaks)} peaks + {len(features)} features -> {master} ({TW}x{TH})")
print(f"[labels] preview -> {final}")
