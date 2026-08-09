# ---------------------------------------------------------------------------
# orbit.py — Blender (Cycles) 360° orbit ANIMATION of a state relief, for a
# seamless Instagram-reel loop.
#
#   blender -b --python blender/orbit.py -- <slug>
#
# Builds the EXACT same scene as relief.py (terrain, hypsometric palette, snow,
# rivers, lakes, saturation, grey card, carved slab, WNW sun) by exec-ing
# relief.py's scene-build prefix — everything before its camera block — so the
# video is pixel-consistent with the still hero. Then it drives its own
# PERSPECTIVE camera on a circular orbit around the map centre with a gentle
# "breathing" dolly (zoom in then out), renders a PNG frame sequence, and writes
# <slug>_orbit_labels.json = each city/peak/feature's screen position for every
# frame (projected through the live camera) so make_video.py can composite the
# names on top in post — constant screen-size, same styling as the still labels.
#
# SEAMLESS LOOP: the azimuth sweeps a full 360° and the zoom is a full sine
# cycle over exactly NF frames (rendered 1..NF), so frame NF -> frame 1 is the
# same step as every other -> the loop has no seam and no held frame.
#
# Pass the SAME BL_* env knobs as the hero render (BL_EXAG, BL_SAT, BL_LAKES,
# BL_LAKEHEX, BL_RIVERS, BL_SNOWLINE, BL_COLORGAMMA, BL_SLAB, ...) so the terrain
# matches. Video-specific knobs (VID_*) are below.
# ---------------------------------------------------------------------------
import bpy, os, sys, json, math, csv
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
slug = argv[0] if argv else "assam"
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, ".."))

def envf(k, d): return float(os.environ.get(k, d))
def envi(k, d): return int(float(os.environ.get(k, d)))

# ---- build the scene by exec-ing relief.py up to (not incl.) its camera block
relief_src = open(os.path.join(here, "relief.py")).read()
MARKER = "# ---- camera: ortho"
assert MARKER in relief_src, "relief.py camera marker not found — did it change?"
prefix = relief_src.split(MARKER)[0]
ns = {"__file__": os.path.join(here, "relief.py"), "__name__": "relief_scene"}
print(f"[orbit] building scene from relief.py prefix ({len(prefix)} chars)")
exec(compile(prefix, "relief.py", "exec"), ns)

scene       = ns["scene"]
aspect      = ns["aspect"]
disp_scale  = ns["disp_scale"]
meta        = ns["meta"]
outdir      = ns["outdir"]
htex        = ns["htex"]           # height ShaderNodeTexImage (for label z sampling)

# ---- video parameters ------------------------------------------------------
RESX    = envi("VID_W", 1080)
RESY    = envi("VID_H", 1920)
FPS     = envi("VID_FPS", 30)
DUR     = envf("VID_SEC", 20.0)
NF      = envi("VID_FRAMES", int(round(FPS * DUR)))   # frames in the loop (1..NF)
SAMPLES = envi("VID_SAMPLES", 64)
ELEV    = envf("VID_ELEV", 50.0)     # camera elevation above the horizontal (deg)
DIST    = envf("VID_DIST", 3.10)     # base orbit radius (world units)
ZAMP    = envf("VID_ZOOM", 0.14)     # zoom breathing amplitude (fraction of DIST)
AZ0     = envf("VID_AZ0", 0.0)       # start azimuth (deg; 0 = camera due south)
SPIN    = envf("VID_SPIN", 1.0)      # +1 clockwise (from above), -1 ccw
LENS    = envf("VID_LENS", 52.0)     # perspective focal length (mm, 36mm sensor)
TARGETZ = disp_scale * envf("VID_TARGETZ", 0.30)   # look-at height (sits in the terrain)
ONLYLABELS = envi("VID_ONLYLABELS", 0)   # 1 = skip rendering, just (re)write label json

# ---- render settings (override the still settings the prefix set) ----------
scene.render.resolution_x = RESX
scene.render.resolution_y = RESY
scene.render.resolution_percentage = 100
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.render.film_transparent = False          # keep the grey card + emboss shadow as the bg
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGB'
scene.render.image_settings.color_depth = '8'
scene.view_settings.view_transform = 'Standard'
framedir = os.path.join(outdir, "orbit_frames")
os.makedirs(framedir, exist_ok=True)
scene.render.filepath = os.path.join(framedir, "f_")   # -> f_0001.png ...
scene.frame_start = 1
scene.frame_end = NF

# ---- perspective orbit camera ---------------------------------------------
cam_data = bpy.data.cameras.new("OrbitCam")
cam_data.type = 'PERSP'
cam_data.lens = LENS
cam_data.sensor_width = 36.0
cam_data.shift_y = envf("VID_SHIFTY", -0.06)   # <0 raises the map in-frame (world_to_camera_view honours it)
cam = bpy.data.objects.new("OrbitCam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
cam.rotation_mode = 'QUATERNION'
phi = math.radians(ELEV)
CRxy, CRz = math.cos(phi), math.sin(phi)
target = Vector((0.0, 0.0, TARGETZ))

def place_cam(f):
    """position the camera for loop-frame f in 0..NF-1 and return (az, zf)."""
    t   = f / NF                                  # 0 .. (NF-1)/NF
    az  = math.radians(AZ0) + SPIN * 2 * math.pi * t
    zf  = 1.0 - ZAMP * math.sin(2 * math.pi * t)  # full sine -> seamless value+slope
    r   = DIST * zf
    loc = Vector((r * CRxy * math.sin(az), -r * CRxy * math.cos(az), TARGETZ + r * CRz))
    cam.location = loc
    cam.rotation_quaternion = (target - loc).to_track_quat('-Z', 'Y')
    return az, zf

print(f"[orbit] {NF} frames @ {FPS}fps ({NF/FPS:.1f}s) {RESX}x{RESY} "
      f"elev={ELEV} dist={DIST} zoom±{ZAMP} lens={LENS}mm samples={SAMPLES}")

# ---- per-frame label screen positions (projected through the live camera) --
from bpy_extras.object_utils import world_to_camera_view
import numpy as np
hi = htex.image
Wc, Hc, chc = hi.size[0], hi.size[1], hi.channels
_b = np.empty(Wc * Hc * chc, dtype=np.float32); hi.pixels.foreach_get(_b)
hgt = _b.reshape(Hc, Wc, chc)[:, :, 0]      # rows bottom-up (row 0 = south)
del _b

def load_csv(sub):
    p = os.path.join(root, sub, f"{slug}.csv")
    return list(csv.DictReader(open(p))) if os.path.exists(p) else []
cities   = load_csv("cities")
peaks    = load_csv("peaks")
features = load_csv("features")

def proj(lat, lon):
    u = (lon - meta["xmin"]) / (meta["xmax"] - meta["xmin"])
    v = (lat - meta["ymin"]) / (meta["ymax"] - meta["ymin"])
    c = min(Wc - 1, max(0, round(u * (Wc - 1))))
    r = min(Hc - 1, max(0, round(v * (Hc - 1))))
    z = float(hgt[r, c]) * disp_scale
    co = world_to_camera_view(scene, cam, Vector(((u - 0.5) * aspect, v - 0.5, z)))
    # co.z > 0 => in front of camera; x,y in 0..1 screen (y up)
    return [round(co.x * RESX, 1), round((1 - co.y) * RESY, 1), round(co.z, 4)]

labels = {"res_x": RESX, "res_y": RESY, "fps": FPS, "nframes": NF, "frames": []}
print("[orbit] labels only" if ONLYLABELS else f"[orbit] rendering -> {framedir}/f_####.png")
for f in range(NF):
    place_cam(f)
    bpy.context.view_layer.update()
    fr = {"cities": {}, "peaks": {}, "features": {}}
    for row in cities:
        fr["cities"][row["name"]] = proj(float(row["lat"]), float(row["long"]))
    for row in peaks:
        fr["peaks"][row["name"]] = proj(float(row["lat"]), float(row["long"]))
    for row in features:
        fr["features"][row["name"]] = proj(float(row["lat"]), float(row["long"]))
    labels["frames"].append(fr)
    if not ONLYLABELS:
        scene.frame_set(f + 1)
        scene.render.filepath = os.path.join(framedir, f"f_{f + 1:04d}")
        bpy.ops.render.render(write_still=True)
        if (f + 1) % 25 == 0 or f == NF - 1:
            print(f"[orbit]   frame {f + 1}/{NF}")
lp = os.path.join(outdir, f"{slug}_orbit_labels.json")
json.dump(labels, open(lp, "w"))
print(f"[orbit] wrote {os.path.basename(lp)} ({NF} frames, "
      f"{len(cities)} cities + {len(peaks)} peaks + {len(features)} features)")
print("[orbit] done" + (" (labels only)" if ONLYLABELS else f" — rendered {NF} frames"))
