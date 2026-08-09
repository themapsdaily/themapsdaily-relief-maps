#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# make_video.py — composite city/peak/feature names onto the orbit frame
# sequence (blender/orbit.py output) and encode a seamless Instagram-reel loop.
#
#   python3 blender/make_video.py <slug> [--fps 30] [--crf 19] [--no-encode]
#
# Reads:
#   output/<slug>/<slug>_orbit_labels.json   per-frame screen positions
#   output/<slug>/orbit_frames/f_####.png    rendered terrain frames
#   cities/<slug>.csv peaks/<slug>.csv features/<slug>.csv   for styling
# Writes:
#   output/<slug>/orbit_comp/f_####.png       frames + labels (intermediate)
#   output/<slug>/<slug>_reel.mp4             the final vertical loop
#
# Labels are CONSTANT screen-size (drawn in post, not 3D) with the same look as
# the still hero: Inter, tight kerning, dark ink + soft white halo, city dot /
# peak triangle. Names float ABOVE the dot (rotation-invariant) so they stay put
# as the map spins. The frame sequence already loops seamlessly (orbit.py sweeps
# a full 360° + a full sine zoom over exactly NF frames), so the encoded mp4
# loops with no seam on Instagram.
# ---------------------------------------------------------------------------
import json, csv, os, sys, subprocess, argparse, shutil

ap = argparse.ArgumentParser()
ap.add_argument("slug")
ap.add_argument("--fps", type=int, default=0, help="override fps (default: from labels json)")
ap.add_argument("--crf", type=int, default=19)
ap.add_argument("--no-encode", action="store_true")
ap.add_argument("--no-composite", action="store_true", help="reuse existing comp frames, just encode")
ap.add_argument("--only-frame", type=int, default=-1, help="composite just this 1-based frame for a quick sample (implies no encode)")
args = ap.parse_args()
slug = args.slug

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, ".."))
outdir = os.path.join(root, "output", slug)
framedir = os.path.join(outdir, "orbit_frames")
compdir = os.path.join(outdir, "orbit_comp")
fdir = os.path.join(root, "fonts")
INTER = {400: os.path.join(fdir, "Inter-400.ttf"),
         600: os.path.join(fdir, "Inter-600.ttf"),
         700: os.path.join(fdir, "Inter-700.ttf")}

lab = json.load(open(os.path.join(outdir, f"{slug}_orbit_labels.json")))
W, H, NF = lab["res_x"], lab["res_y"], lab["nframes"]
FPS = args.fps or lab.get("fps", 30)

# Label EVERYTHING in the CSVs (user wants all places named in the reel, like the
# still). Capital comes from the CSV `capital` column (red dot + bold). Guwahati &
# Dispur sit ~5 km apart, so diverge their names L/R so both read; every other city
# name floats ABOVE its dot (rotation-invariant on the spinning map).
# per-name label direction to de-conflict tight clusters; default "above".
# Guwahati/Dispur share a spot -> split vertically (Dispur above, Guwahati below);
# the upper-Assam cluster (Dibrugarh/Tinsukia/Jorhat) staggers above/below.
DIR = {"Dispur": "above", "Guwahati": "below",
       "Dibrugarh": "above", "Tinsukia": "below", "Jorhat": "below", "Diphu": "below"}

DARK = "#2b2b2b"; CAP = "#6E1616"; LAKE = "#1C6091"
FEATCOL = {"river": LAKE}                        # others -> DARK
def S(frac): return max(11, int(round(frac * W)))

# ---- styling sizes (fractions of width) -----------------------------------
CITY_SZ   = S(0.0255); CAP_SZ = S(0.0340)
PEAK_SZ   = S(0.0235); ELEV_SZ = S(0.0155)
FEAT_SZ   = S(0.0235)
DOT_R     = S(0.0058); CAP_R = S(0.0085); TRI_R = S(0.0072)
GAP       = S(0.0055)                            # marker -> text gap

# ---- read CSV metadata -----------------------------------------------------
def load(sub):
    p = os.path.join(root, sub, f"{slug}.csv")
    return {r["name"]: r for r in csv.DictReader(open(p))} if os.path.exists(p) else {}
cmeta, pmeta, fmeta = load("cities"), load("peaks"), load("features")

# ---- pre-render each label's text chip ONCE (dark ink + soft white halo) ----
TMP = os.path.join(outdir, "_vtmp"); os.makedirs(TMP, exist_ok=True)
_n = [0]
def sh(*a): subprocess.run([str(x) for x in a], check=True)
def ident(p): return tuple(int(v) for v in subprocess.check_output(
    ["magick", "identify", "-format", "%w %h", p]).split())
def make_chip(text, weight, size, color):
    _n[0] += 1
    p = os.path.join(TMP, f"c{_n[0]}.png")
    kern = -0.03 * size; blur = max(2, int(size * 0.12)); pad = blur + max(3, int(size * 0.09))
    sh("magick", "-background", "none", "-font", INTER[weight], "-pointsize", size,
       "-kerning", f"{kern:.2f}", "-fill", color, f"label:{text}",
       "-bordercolor", "none", "-border", pad,
       "(", "+clone", "-channel", "A", "-blur", f"0x{blur}",
       "-level", "0,60%", "+channel", "-fill", "white", "-colorize", "100", ")",
       "+swap", "-compose", "over", "-composite", p)
    w, h = ident(p); return {"path": p, "pad": pad, "w": w, "h": h}

# build the chip table (keyed by kind/name) — every label in the CSVs
chips = {}
for name, m in cmeta.items():
    cap = (m.get("capital", "0") == "1")
    chips[("city", name)] = make_chip(name, 700 if cap else 600,
                                      CAP_SZ if cap else CITY_SZ, DARK)
for name in pmeta:
    chips[("peak", name)] = make_chip(name.upper(), 600, PEAK_SZ, DARK)
    ev = pmeta[name].get("elev_m", "")
    if ev: chips[("peakelev", name)] = make_chip(f"{ev} m", 400, ELEV_SZ, DARK)
for name in fmeta:
    col = FEATCOL.get(fmeta[name].get("type", ""), DARK)
    chips[("feat", name)] = make_chip(name, 600, FEAT_SZ, col)

def clampx(cx, halfw): return min(max(cx, halfw + 4), W - halfw - 4)
def clampy(cy, halfh): return min(max(cy, halfh + 4), H - halfh - 4)

# ---- composite each frame --------------------------------------------------
if not args.no_composite:
    only = args.only_frame
    if only < 0 and os.path.isdir(compdir): shutil.rmtree(compdir)
    os.makedirs(compdir, exist_ok=True)
    for f in ([only - 1] if only > 0 else range(NF)):
        fr = lab["frames"][f]
        base = os.path.join(framedir, f"f_{f+1:04d}.png")
        out = os.path.join(compdir, f"f_{f+1:04d}.png")
        cmd = ["magick", base]
        composites = []          # (chip, x_topleft, y_topleft)
        # markers first (drawn on the terrain), then chips on top
        # --- cities ---
        for name, meta in cmeta.items():
            if name not in fr["cities"]: continue
            x, y, z = fr["cities"][name]
            if z <= 0: continue
            cap = (meta.get("capital", "0") == "1")
            r = CAP_R if cap else DOT_R
            col = CAP if cap else DARK
            cmd += ["-strokewidth", str(max(1, int(r*0.32))), "-stroke", "white",
                    "-fill", col, "-draw", f"circle {x:.1f},{y:.1f} {x:.1f},{y-r:.1f}"]
            c = chips[("city", name)]
            X = x - c["w"]/2
            if DIR.get(name, "above") == "below":         # name BELOW the dot
                Y = y + r + GAP - c["pad"]
            else:                                         # name ABOVE the dot (default)
                Y = y - r - GAP - (c["h"] - c["pad"])
            X = min(max(X, 4), W - c["w"] - 4); Y = min(max(Y, 4), H - c["h"] - 4)
            composites.append((c, X, Y))
        # --- peaks ---
        for name in pmeta:
            if name not in fr["peaks"]: continue
            x, y, z = fr["peaks"][name]
            if z <= 0: continue
            r = TRI_R
            pts = f"{x:.1f},{y-r:.1f} {x-r:.1f},{y+r*0.85:.1f} {x+r:.1f},{y+r*0.85:.1f}"
            cmd += ["-strokewidth", str(max(1, int(r*0.3))), "-stroke", "white",
                    "-fill", DARK, "-draw", f"polygon {pts}"]
            c = chips[("peak", name)]
            cx = clampx(x, c["w"]/2)
            ytop = y + r + GAP - c["pad"]
            composites.append((c, cx - c["w"]/2, ytop))
            if ("peakelev", name) in chips:
                e = chips[("peakelev", name)]
                ecx = clampx(x, e["w"]/2)
                eytop = ytop + (c["h"] - c["pad"]) + GAP*0.4 - e["pad"]
                composites.append((e, ecx - e["w"]/2, eytop))
        # --- features (centered text on the point, no marker) ---
        for name in fmeta:
            if name not in fr["features"]: continue
            x, y, z = fr["features"][name]
            if z <= 0: continue
            c = chips[("feat", name)]
            cx = clampx(x, c["w"]/2); cy = clampy(y, c["h"]/2)
            composites.append((c, cx - c["w"]/2, cy - c["h"]/2))
        for c, X, Y in composites:
            cmd += ["(", c["path"], ")", "-geometry", f"+{int(round(X))}+{int(round(Y))}",
                    "-compose", "over", "-composite"]
        cmd += [out]
        sh(*cmd)
        if only > 0 or (f+1) % 50 == 0 or f == NF-1:
            print(f"[video] composited frame {f+1}" + ("" if only > 0 else f"/{NF}"))

# cleanup chips
for fn in os.listdir(TMP): os.remove(os.path.join(TMP, fn))
os.rmdir(TMP)

# ---- encode ----------------------------------------------------------------
mp4 = os.path.join(outdir, f"{slug}_reel.mp4")
if not args.no_encode and args.only_frame < 0:
    ff = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    cmd = [ff, "-y", "-framerate", str(FPS),
           "-start_number", "1", "-i", os.path.join(compdir, "f_%04d.png"),
           "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", str(args.crf),
           "-preset", "medium", "-profile:v", "high", "-r", str(FPS),
           "-shortest", "-movflags", "+faststart", mp4]
    subprocess.run(cmd, check=True)
    sz = os.path.getsize(mp4) / 1e6
    print(f"[video] wrote {mp4} ({sz:.1f} MB, {NF} frames @ {FPS}fps = {NF/FPS:.1f}s)")
else:
    print("[video] --no-encode: comp frames only ->", compdir)
