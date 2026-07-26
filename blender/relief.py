# ---------------------------------------------------------------------------
# relief.py — Blender (Cycles) shaded-relief renderer for Indian states.
#
#   blender -b --python blender/relief.py -- <slug>
#
# Reads output/<slug>_height.tif (float32 elevation 0..1, displacement source),
# output/<slug>_mask.png (white = inside state) and output/<slug>_meta.json
# (aspect + elevation range) written by blender/export_dem.R, and renders
# output/<slug>_blender.png.
#
# Approach (see blender/HANDOFF.md): a flat plane scaled to the state's true
# geographic aspect, given REAL geometry via adaptive subdivision + material
# displacement from the height map. A hypsometric colour ramp tints by height,
# the mask drives alpha (transparent outside the state), a low NW sun casts
# real cast shadows, and a grey card below catches a soft emboss shadow — the
# mappdout / "California relief" look, but path-traced 3D instead of 2D.
#
# Env knobs (all optional):
#   BL_EXAG    vertical exaggeration multiplier          (default 2.2)
#   BL_TILT    camera tilt from top-down, degrees        (default 0 = top-down)
#   BL_SAMPLES Cycles samples                            (default 128)
#   BL_RES     render width in px (height = round(w/asp)) (default 1600)
#   BL_GROUND  1 = grey card + shadow, 0 = transparent    (default 1)
#   BL_DEVICE  GPU | CPU                                  (default GPU)
#   BL_DICING  adaptive dicing rate (lower = finer)       (default 1.0)
#   BL_SUNALT  sun altitude degrees                       (default 32)
#   BL_SUNAZ   sun azimuth degrees (from N, clockwise)    (default 315 = NW)
# ---------------------------------------------------------------------------
import bpy, sys, os, json, math
from mathutils import Vector

# ---- args / paths ---------------------------------------------------------
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
slug = argv[0] if argv else "uttarakhand"
here = os.path.dirname(os.path.abspath(__file__))
outdir = os.path.abspath(os.path.join(here, "..", "output", slug))   # per-state subfolder
os.makedirs(outdir, exist_ok=True)
height_tif = os.path.join(outdir, f"{slug}_height.tif")
height_png = os.path.join(outdir, f"{slug}_height.png")
mask_png = os.path.join(outdir, f"{slug}_mask.png")
meta_path = os.path.join(outdir, f"{slug}_meta.json")
out_png = os.path.join(outdir, f"{slug}" + os.environ.get("BL_SUFFIX", "_blender") + ".png")

with open(meta_path) as f:
    meta = json.load(f)
aspect = float(meta["aspect"])            # true geographic width : height
width_km = float(meta["width_km"])
elev_range_km = float(meta["elev_range_km"])

def envf(k, d):  return float(os.environ.get(k, d))
def envi(k, d):  return int(float(os.environ.get(k, d)))

EXAG = envf("BL_EXAG", 2.8)
TILT = envf("BL_TILT", 0.0)
SAMPLES = envi("BL_SAMPLES", 128)
RES = envi("BL_RES", 1600)
GROUND = envi("BL_GROUND", 1)
DEVICE = os.environ.get("BL_DEVICE", "GPU").upper()
DICING = envf("BL_DICING", 1.0)
SUNALT = envf("BL_SUNALT", 30.0)
SUNAZ = envf("BL_SUNAZ", 285.0)          # sun to the LEFT (WNW) -> shadows rake left->right
SUNSOFT = envf("BL_SUNSOFT", 1.2)        # sun angular size (deg); smaller = crisper, less scattered
SNOWLINE = envf("BL_SNOWLINE", 0.60)     # normalized elev where snow caps begin (1 = highest peak)
CLOUDS = envi("BL_CLOUDS", 0)            # clouds off by default (BL_CLOUDS=1 to re-enable puffs)
SAT = envf("BL_SAT", 1.22)               # colour saturation boost (1.0 = off) for a catchier map
SLAB = envi("BL_SLAB", 0)                # 1 = extrude a solid base slab (thick carved-model walls)
SLAB_THICK = envf("BL_SLABTHICK", 0.05)  # slab thickness in plane units
SLAB_HEX = os.environ.get("BL_SLABHEX", "#b9b3a6")   # slab wall colour (neutral warm grey)
LAKES = envi("BL_LAKES", 0)              # 1 = paint lakes/reservoirs blue if <slug>_lakes.png exists
LAKE_HEX = os.environ.get("BL_LAKEHEX", "#3A79A8")   # lake blue (a touch deeper than rivers)
lakes_png = os.path.join(outdir, f"{slug}_lakes.png")
SEA = envi("BL_SEA", 0)                  # 1 = paint a coastal sea band if <slug>_sea.png exists
SEA_HEX = os.environ.get("BL_SEAHEX", "#2E7C9E")     # Arabian Sea blue
sea_png = os.path.join(outdir, f"{slug}_sea.png")
OCEAN = envi("BL_OCEAN", 1)              # 1 = opaque SHADELESS water sheet over the whole ocean
ocean_png = os.path.join(outdir, f"{slug}_ocean.png")
FLATLIGHT = envf("BL_FLATLIGHT", 0.87)   # how bright a flat lambertian face renders under the
                                         # default sun; the shadeless sheet is emitted at exactly
                                         # this fraction so it matches the LIT grey card seamlessly
                                         # (#d7d7d7 card measures 202/255 -> 0.87). Retune only if
                                         # BL_SUNALT / world lighting changes.
BEACH = envi("BL_BEACH", 0)              # 1 = flat golden sand shore if <slug>_beach.png exists
BEACH_HEX = os.environ.get("BL_BEACHHEX", "#E7D3A1")  # golden sand
beach_png = os.path.join(outdir, f"{slug}_beach.png")
WAVES = envi("BL_WAVES", 0)              # 1 = white wave dashes in the coastal band
WAVE_HEX = os.environ.get("BL_WAVEHEX", "#FFFFFF")
WAVE_STR = envf("BL_WAVESTR", 0.75)      # how strongly the dashes read (0..1)
waves_png = os.path.join(outdir, f"{slug}_waves.png")
COAST = envi("BL_COAST", 0)              # 1 = taper terrain to sea level at the shoreline
coast_png = os.path.join(outdir, f"{slug}_coast.png")
outline_json = os.path.join(outdir, f"{slug}_outline.json")
SLAB_TOP = -0.003                        # slab top just below the terrain base (z=0)
card_z = (SLAB_TOP - SLAB_THICK - 0.005) if SLAB else -0.012   # grey card sits under the slab
CLOUD_N = envi("BL_CLOUDN", 6)           # how many puffs
CLOUD_SIZE = envf("BL_CLOUDSIZE", 0.030)  # puff radius (plane units; map width = aspect)
CLOUD_GLOW = envf("BL_CLOUDGLOW", 0.35)  # emission lift so undersides stay white, not grey
CLOUD_HEIGHT = envf("BL_CLOUDHT", 1.5)   # puff altitude = peak height * this
CLOUD_MINELEV = envf("BL_CLOUDELEV", 0.30)   # place puffs over the mid-mountain belt (darker ->
CLOUD_MAXELEV = envf("BL_CLOUDELEVHI", 0.52) # white blobs pop), i.e. around the peaks, not on snow
CLOUD_SEED = envi("BL_CLOUDSEED", 7)     # reshuffle puff positions
RIVERS = envi("BL_RIVERS", 1)            # 1 = paint rivers if the rasterized mask exists
CANVAS = os.environ.get("BL_CANVAS", "4:5")  # final canvas W:H (portrait); map centred, grey fills rest
MARGIN = envf("BL_MARGIN", 1.22)         # horizontal fit: map width * MARGIN (bigger = more side grey)
AUTOCENTER = envi("BL_AUTOCENTER", 0)    # 1 = centre the VISIBLE map in frame. In sea mode the DEM
                                         # grid is padded west into the ocean (SEA_WEST), so the
                                         # plane's centre is NOT the map's centre and the state lands
                                         # right-of-frame against a fat left margin. Measures the
                                         # land + blue-band bbox through the real (tilted) camera and
                                         # slides the camera to centre it; BL_SHIFTY is then applied
                                         # as a deliberate offset FROM centred. Opt-in, not on by
                                         # default for sea mode: it re-frames the shot, and states
                                         # whose hero is already signed off must re-render identically.
SHIFTY = envf("BL_SHIFTY", -0.075)       # vertical lens shift: <0 raises the map in-frame, opening a
                                         # grey band at the BOTTOM for a state-name title (0 = centred).
                                         # Default frames a ~20% bottom title band + small top logo margin.

# height source: prefer the float32 TIFF (no terracing); fall back to 8-bit PNG
height_img_path = height_tif if os.path.exists(height_tif) else height_png

# hypsometric palette (green lowlands -> sienna mtns -> cream peaks), sRGB hex.
# Per-state override: palettes/<slug>.txt (one #hex per line) tints that state
# to its own character (e.g. Ladakh = tan cold-desert instead of green valleys).
PALETTE = ["#66A778", "#8CB488", "#B0BC93", "#CFC196", "#C69C5E",
           "#A6733E", "#BE8F58", "#D5C8A2", "#E7DDC5", "#F3EDDE"]
import re as _re
_pal_file = os.path.join(here, "..", "palettes", f"{slug}.txt")
if os.path.exists(_pal_file):
    _stops = [ln.strip() for ln in open(_pal_file)
              if _re.fullmatch(r"#[0-9A-Fa-f]{6}", ln.strip())]   # only #RRGGBB lines
    if _stops:
        PALETTE = _stops
        print(f"[relief] palette override: palettes/{slug}.txt ({len(PALETTE)} stops)")
GROUND_HEX = "#d7d7d7"                      # CA grey 215,215,215
SNOW_HEX = "#F4F7F9"                        # cool near-white snow caps
RIVER_HEX = "#4E86A6"                       # muted river blue
rivers_png = os.path.join(outdir, f"{slug}_rivers.png")

def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def hex_lin(h):
    h = h.lstrip("#")
    return (srgb_to_linear(int(h[0:2], 16)),
            srgb_to_linear(int(h[2:4], 16)),
            srgb_to_linear(int(h[4:6], 16)), 1.0)

print(f"[relief] {slug} aspect={aspect:.3f} exag={EXAG} res={RES} "
      f"samples={SAMPLES} ground={GROUND} device={DEVICE} src={os.path.basename(height_img_path)}")

# ---- clean scene ----------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'

# ---- device (Metal GPU, CPU fallback) -------------------------------------
def setup_device():
    if DEVICE == 'CPU':
        scene.cycles.device = 'CPU'; return 'CPU'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    for fn in ("refresh_devices", "get_devices"):
        try: getattr(prefs, fn)()
        except Exception: pass
    n = 0
    for d in prefs.devices:
        d.use = (d.type != 'CPU')            # GPU only, skip CPU device
        n += 1 if d.use else 0
    scene.cycles.device = 'GPU'
    return f'GPU ({n} device(s))'
print("[relief] compute:", setup_device())

# ---- render / colour settings ---------------------------------------------
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
try: scene.cycles.denoiser = 'OPENIMAGEDENOISE'
except Exception: pass
scene.cycles.dicing_rate = DICING
scene.cycles.preview_dicing_rate = DICING
# canvas: portrait ratio (BL_CANVAS "W:H"); map is centred, grey fills top/bottom
cw, ch = (float(x) for x in CANVAS.split(":"))
scene.render.resolution_x = RES
scene.render.resolution_y = max(1, round(RES * ch / cw))
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
## 8-bit by default: the _hero render is a DELIVERABLE the user posts directly
## (not just an intermediate for make_labels), and 16-bit RGBA put a 4K hero at
## 76-79 MB -- over the 50 MB ceiling. 8-bit shows no visible banding at 4K and
## lands ~12 MB. Set BL_DEPTH=16 if a true master is ever needed.
scene.render.image_settings.color_depth = os.environ.get("BL_DEPTH", "8")
scene.render.image_settings.compression = 100
scene.render.film_transparent = (GROUND == 0)
scene.view_settings.view_transform = 'Standard'   # keep palette colours exact
scene.render.filepath = out_png

# ---- displaced plane ------------------------------------------------------
bpy.ops.mesh.primitive_plane_add(size=2.0)        # spans -1..1 in x and y
plane = bpy.context.active_object
plane.scale = (aspect / 2.0, 1.0 / 2.0, 1.0)      # -> width=aspect, height=1
bpy.ops.object.transform_apply(scale=True)

# Blender 5.x: adaptive subdivision lives on the Subdivision modifier itself
# (screen-space PIXEL dicing = subdivide to render resolution -> granularity).
sub = plane.modifiers.new("Subdivision", 'SUBSURF')
sub.subdivision_type = 'SIMPLE'
sub.levels = 1
sub.render_levels = 1
sub.use_adaptive_subdivision = True
sub.adaptive_space = 'PIXEL'
sub.adaptive_pixel_size = DICING                   # px per micropoly edge (lower = finer)

# ---- material: colour ramp by height, mask alpha, height*mask displacement -
mat = bpy.data.materials.new(f"relief_{slug}")
mat.use_nodes = True
nt = mat.node_tree
nt.nodes.clear()
nodes, links = nt.nodes, nt.links

out = nodes.new("ShaderNodeOutputMaterial")
bsdf = nodes.new("ShaderNodeBsdfPrincipled")
bsdf.inputs["Roughness"].default_value = 1.0
if "Specular IOR Level" in bsdf.inputs:            # kill spec highlights
    bsdf.inputs["Specular IOR Level"].default_value = 0.0

# height texture (Non-Color, cubic)
htex = nodes.new("ShaderNodeTexImage")
htex.image = bpy.data.images.load(height_img_path, check_existing=True)
htex.image.colorspace_settings.name = 'Non-Color'
htex.interpolation = 'Cubic'
htex.extension = 'EXTEND'

# mask texture (Non-Color)
mtex = nodes.new("ShaderNodeTexImage")
mtex.image = bpy.data.images.load(mask_png, check_existing=True)
mtex.image.colorspace_settings.name = 'Non-Color'
mtex.interpolation = 'Closest'
mtex.extension = 'EXTEND'

# colour ramp: 10 palette stops across height 0..1
ramp = nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.interpolation = 'B_SPLINE'         # smooth hypsometric blend
els = ramp.color_ramp.elements
while len(els) > 1:
    els.remove(els[-1])
for i, hexc in enumerate(PALETTE):
    pos = i / (len(PALETTE) - 1)
    e = els[0] if i == 0 else els.new(pos)
    e.position = pos
    e.color = hex_lin(hexc)
# optional colour gamma on the height->ramp input ONLY (not displacement/snow):
# gamma < 1 lifts the low ground into higher palette stops. For a state that is
# mostly low (Goa: half under 63 m of a 0..961 m range) this pulls the lush
# lowland off the bottom sand stops into green, leaving sand only at the shore.
CGAMMA = envf("BL_COLORGAMMA", 1.0)
fac_src = htex.outputs["Color"]
if abs(CGAMMA - 1.0) > 1e-3:
    gpow = nodes.new("ShaderNodeMath"); gpow.operation = 'POWER'
    gpow.inputs[1].default_value = CGAMMA
    links.new(htex.outputs["Color"], gpow.inputs[0])
    fac_src = gpow.outputs["Value"]
    print(f"[relief] colour gamma {CGAMMA}")
links.new(fac_src, ramp.inputs["Fac"])
base_col = ramp.outputs["Color"]                   # hypsometric colour so far

# snow caps: blend to white above the snow line (smooth band around SNOWLINE)
if SNOWLINE < 1.0:
    snow = nodes.new("ShaderNodeMapRange")
    snow.interpolation_type = 'SMOOTHSTEP'
    snow.inputs["From Min"].default_value = max(0.0, SNOWLINE - 0.08)
    snow.inputs["From Max"].default_value = min(1.0, SNOWLINE + 0.10)
    links.new(htex.outputs["Color"], snow.inputs["Value"])
    smix = nodes.new("ShaderNodeMixRGB"); smix.blend_type = 'MIX'
    smix.inputs["Color2"].default_value = hex_lin(SNOW_HEX)
    links.new(base_col, smix.inputs["Color1"])
    links.new(snow.outputs["Result"], smix.inputs["Fac"])
    base_col = smix.outputs["Color"]

# beach: flat golden sand along the shore. Painted BEFORE rivers/lakes so a
# river mouth crossing the sand still reads blue. The same mask also zeroes
# displacement below, so the beach sits flat at sea level rather than extruded.
btex = None
if BEACH and os.path.exists(beach_png):
    btex = nodes.new("ShaderNodeTexImage")
    btex.image = bpy.data.images.load(beach_png, check_existing=True)
    btex.image.colorspace_settings.name = 'Non-Color'
    btex.interpolation = 'Linear'; btex.extension = 'EXTEND'
    bmix = nodes.new("ShaderNodeMixRGB"); bmix.blend_type = 'MIX'
    bmix.inputs["Color2"].default_value = hex_lin(BEACH_HEX)
    links.new(base_col, bmix.inputs["Color1"])
    links.new(btex.outputs["Color"], bmix.inputs["Fac"])
    base_col = bmix.outputs["Color"]
    print(f"[relief] beach on ({BEACH_HEX}, flattened)")

# rivers: paint thin blue where the rasterized river mask is set (inside state)
if RIVERS and os.path.exists(rivers_png):
    rtex = nodes.new("ShaderNodeTexImage")
    rtex.image = bpy.data.images.load(rivers_png, check_existing=True)
    rtex.image.colorspace_settings.name = 'Non-Color'
    rtex.interpolation = 'Linear'; rtex.extension = 'EXTEND'
    rfac = nodes.new("ShaderNodeMath"); rfac.operation = 'MULTIPLY'
    links.new(rtex.outputs["Color"], rfac.inputs[0])
    links.new(mtex.outputs["Color"], rfac.inputs[1])   # clip to inside the state
    rmix = nodes.new("ShaderNodeMixRGB"); rmix.blend_type = 'MIX'
    rmix.inputs["Color2"].default_value = hex_lin(RIVER_HEX)
    links.new(base_col, rmix.inputs["Color1"])
    links.new(rfac.outputs["Value"], rmix.inputs["Fac"])
    base_col = rmix.outputs["Color"]

# lakes / reservoirs: paint filled blue where the lake mask is set (inside state)
if LAKES and os.path.exists(lakes_png):
    ltex = nodes.new("ShaderNodeTexImage")
    ltex.image = bpy.data.images.load(lakes_png, check_existing=True)
    ltex.image.colorspace_settings.name = 'Non-Color'
    ltex.interpolation = 'Linear'; ltex.extension = 'EXTEND'
    lfac = nodes.new("ShaderNodeMath"); lfac.operation = 'MULTIPLY'
    links.new(ltex.outputs["Color"], lfac.inputs[0])
    links.new(mtex.outputs["Color"], lfac.inputs[1])   # clip to inside the state
    lmix = nodes.new("ShaderNodeMixRGB"); lmix.blend_type = 'MIX'
    lmix.inputs["Color2"].default_value = hex_lin(LAKE_HEX)
    links.new(base_col, lmix.inputs["Color1"])
    links.new(lfac.outputs["Value"], lmix.inputs["Fac"])
    base_col = lmix.outputs["Color"]

# saturation boost for a catchier map (leaves whites/greys neutral)
if abs(SAT - 1.0) > 1e-3:
    hsv = nodes.new("ShaderNodeHueSaturation")
    hsv.inputs["Saturation"].default_value = SAT
    links.new(base_col, hsv.inputs["Color"])
    base_col = hsv.outputs["Color"]
# coastal sea band: paint blue where <slug>_sea.png is set (outside the state,
# hugging the shore) and make those pixels opaque so the blue reads; the factor
# fades to 0 offshore, so alpha -> 0 there and the blue dissolves into the grey
# card == "blue sea + grey frame". Alpha = max(state mask, sea factor).
alpha_src = mtex.outputs["Color"]

# ocean sheet: the HARD water mask (whole sea, not just the narrow blue band).
# Painted to the card grey FIRST, so where no band reaches the sheet is
# indistinguishable from the card behind it; the band's blue then goes on top.
otex = None
if SEA and OCEAN and os.path.exists(ocean_png):
    otex = nodes.new("ShaderNodeTexImage")
    otex.image = bpy.data.images.load(ocean_png, check_existing=True)
    otex.image.colorspace_settings.name = 'Non-Color'
    otex.interpolation = 'Linear'; otex.extension = 'EXTEND'
    omix = nodes.new("ShaderNodeMixRGB"); omix.blend_type = 'MIX'
    omix.inputs["Color2"].default_value = hex_lin(GROUND_HEX)
    links.new(base_col, omix.inputs["Color1"])
    links.new(otex.outputs["Color"], omix.inputs["Fac"])
    base_col = omix.outputs["Color"]

if SEA and os.path.exists(sea_png):
    stex = nodes.new("ShaderNodeTexImage")
    stex.image = bpy.data.images.load(sea_png, check_existing=True)
    stex.image.colorspace_settings.name = 'Non-Color'
    stex.interpolation = 'Linear'; stex.extension = 'EXTEND'
    smix = nodes.new("ShaderNodeMixRGB"); smix.blend_type = 'MIX'
    smix.inputs["Color2"].default_value = hex_lin(SEA_HEX)
    links.new(base_col, smix.inputs["Color1"])
    links.new(stex.outputs["Color"], smix.inputs["Fac"])
    base_col = smix.outputs["Color"]
    amax = nodes.new("ShaderNodeMath"); amax.operation = 'MAXIMUM'
    links.new(mtex.outputs["Color"], amax.inputs[0])
    links.new(stex.outputs["Color"], amax.inputs[1])
    alpha_src = amax.outputs["Value"]
    print(f"[relief] sea band on ({SEA_HEX})")

    # white wave dashes, painted ON TOP of the band (inside the sea only)
    if WAVES and os.path.exists(waves_png):
        wtex = nodes.new("ShaderNodeTexImage")
        wtex.image = bpy.data.images.load(waves_png, check_existing=True)
        wtex.image.colorspace_settings.name = 'Non-Color'
        wtex.interpolation = 'Linear'; wtex.extension = 'EXTEND'
        wstr = nodes.new("ShaderNodeMath"); wstr.operation = 'MULTIPLY'
        wstr.inputs[1].default_value = WAVE_STR
        links.new(wtex.outputs["Color"], wstr.inputs[0])
        wmix = nodes.new("ShaderNodeMixRGB"); wmix.blend_type = 'MIX'
        wmix.inputs["Color2"].default_value = hex_lin(WAVE_HEX)
        links.new(base_col, wmix.inputs["Color1"])
        links.new(wstr.outputs["Value"], wmix.inputs["Fac"])
        base_col = wmix.outputs["Color"]
        # waves are part of the water surface -> keep those pixels opaque too
        wamax = nodes.new("ShaderNodeMath"); wamax.operation = 'MAXIMUM'
        links.new(alpha_src, wamax.inputs[0])
        links.new(wtex.outputs["Color"], wamax.inputs[1])
        alpha_src = wamax.outputs["Value"]
        print("[relief] waves on")

# ---- shadeless water -------------------------------------------------------
# Water is a FLAT sheet at z=0, so the coastal hills rake real cast shadows
# across it: grey smudges floating on the sea west of the shore (worst in bays
# and estuary mouths, which are wider than the blue band). Water has no relief
# to model, so nothing is lost by taking it out of the lighting entirely:
#   * base colour -> black on the ocean, so it has no diffuse response at all
#     and therefore cannot receive a shadow;
#   * the same colour is EMITTED instead, at FLATLIGHT (the exact fraction a
#     flat lit face renders at), so the result is pixel-identical to the old
#     UNshadowed water and to the lit grey card it abuts -- no seam;
#   * the sheet is opaque to camera rays (it hides the card's shadow beneath it)
#     but transparent to SHADOW rays, so its own edge casts no dark fringe.
# Land, beaches and inland lakes keep their normal lighting and shadows.
if otex is not None:
    ocean_fac = otex.outputs["Color"]
    unlit = nodes.new("ShaderNodeMixRGB"); unlit.blend_type = 'MIX'
    unlit.inputs["Color2"].default_value = (0.0, 0.0, 0.0, 1.0)
    links.new(base_col, unlit.inputs["Color1"])
    links.new(ocean_fac, unlit.inputs["Fac"])
    links.new(unlit.outputs["Color"], bsdf.inputs["Base Color"])

    lp = nodes.new("ShaderNodeLightPath")
    estr = nodes.new("ShaderNodeMath"); estr.operation = 'MULTIPLY'
    estr.inputs[1].default_value = FLATLIGHT
    links.new(ocean_fac, estr.inputs[0])
    # CAMERA RAYS ONLY: the sheet is a big emitter, and left in the light loop it
    # spills bounce light onto the grey card beyond the plane's edge (measured
    # 202 -> 224). Gating on Is Camera Ray keeps it looking identical while
    # contributing nothing to the lighting, so the rest of the frame is unchanged.
    ecam = nodes.new("ShaderNodeMath"); ecam.operation = 'MULTIPLY'
    links.new(estr.outputs["Value"], ecam.inputs[0])
    links.new(lp.outputs["Is Camera Ray"], ecam.inputs[1])
    ecol = "Emission Color" if "Emission Color" in bsdf.inputs else "Emission"
    links.new(base_col, bsdf.inputs[ecol])
    links.new(ecam.outputs["Value"], bsdf.inputs["Emission Strength"])

    # Opaque to the CAMERA only. As a real occluder the sheet would cast its own
    # shadow and block skylight from the card just past its edge (measured 202 ->
    # 186, a visible seam along the plane boundary). Gating alpha on Is Camera Ray
    # makes it a pure matte: it hides the shadowed card beneath it from view while
    # light passes straight through, so everything outside it is untouched.
    ocast = nodes.new("ShaderNodeMath"); ocast.operation = 'MULTIPLY'
    links.new(ocean_fac, ocast.inputs[0])
    links.new(lp.outputs["Is Camera Ray"], ocast.inputs[1])
    oamax = nodes.new("ShaderNodeMath"); oamax.operation = 'MAXIMUM'
    links.new(mtex.outputs["Color"], oamax.inputs[0])
    links.new(ocast.outputs["Value"], oamax.inputs[1])
    alpha_src = oamax.outputs["Value"]
    print(f"[relief] ocean sheet on (shadeless, emit {FLATLIGHT})")
else:
    links.new(base_col, bsdf.inputs["Base Color"])
links.new(alpha_src, bsdf.inputs["Alpha"])
links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

# displacement = height * mask * scale  (outside state stays flat)
hmul = nodes.new("ShaderNodeMath"); hmul.operation = 'MULTIPLY'
links.new(htex.outputs["Color"], hmul.inputs[0])
links.new(mtex.outputs["Color"], hmul.inputs[1])
disp_h = hmul.outputs["Value"]
# beaches are at sea level: multiply displacement by (1 - beach) so the sand
# strip stays FLAT instead of being extruded up with the coastal terrain.
if btex is not None:
    binv = nodes.new("ShaderNodeMath"); binv.operation = 'SUBTRACT'
    binv.inputs[0].default_value = 1.0
    links.new(btex.outputs["Color"], binv.inputs[1])
    bflat = nodes.new("ShaderNodeMath"); bflat.operation = 'MULTIPLY'
    links.new(hmul.outputs["Value"], bflat.inputs[0])
    links.new(binv.outputs["Value"], bflat.inputs[1])
    disp_h = bflat.outputs["Value"]
# coast taper: ramp displacement to 0 at the waterline so the mesh never drops
# as a vertical grey curtain at the coastal mask edge (inland borders are far
# from the ocean, so their taper is 1 and the carved slab edge is untouched).
if COAST and os.path.exists(coast_png):
    ctex = nodes.new("ShaderNodeTexImage")
    ctex.image = bpy.data.images.load(coast_png, check_existing=True)
    ctex.image.colorspace_settings.name = 'Non-Color'
    ctex.interpolation = 'Linear'; ctex.extension = 'EXTEND'
    ctm = nodes.new("ShaderNodeMath"); ctm.operation = 'MULTIPLY'
    links.new(disp_h, ctm.inputs[0])
    links.new(ctex.outputs["Color"], ctm.inputs[1])
    disp_h = ctm.outputs["Value"]
    print("[relief] coast taper on")
disp = nodes.new("ShaderNodeDisplacement")
disp.inputs["Midlevel"].default_value = 0.0        # value 0 -> no lift
# 1 Blender unit == width_km/aspect km, so true relief height (units):
disp_scale = (elev_range_km * aspect / width_km) * EXAG
disp.inputs["Scale"].default_value = disp_scale
links.new(disp_h, disp.inputs["Height"])
links.new(disp.outputs["Displacement"], out.inputs["Displacement"])

# material displacement method (moved out of .cycles in 4.1+; try both)
if hasattr(mat, "displacement_method"):
    mat.displacement_method = 'DISPLACEMENT'
else:
    mat.cycles.displacement_method = 'DISPLACEMENT'
plane.data.materials.append(mat)
print(f"[relief] displacement scale = {disp_scale:.4f} units (exag {EXAG})")

# ---- grey ground card (catches the emboss shadow) -------------------------
if GROUND == 1:
    bpy.ops.mesh.primitive_plane_add(size=40.0, location=(0, 0, card_z))
    ground = bpy.context.active_object
    gmat = bpy.data.materials.new("ground"); gmat.use_nodes = True
    gb = gmat.node_tree.nodes.get("Principled BSDF")
    gb.inputs["Base Color"].default_value = hex_lin(GROUND_HEX)
    gb.inputs["Roughness"].default_value = 1.0
    if "Specular IOR Level" in gb.inputs:
        gb.inputs["Specular IOR Level"].default_value = 0.0
    ground.data.materials.append(gmat)

# ---- solid base slab: extrude the state silhouette into a thick carved tile-
# Gives the relief real thickness (vertical side walls) so it reads as a solid
# model sitting on the card, instead of a paper-thin cutout.
if SLAB and os.path.exists(outline_json):
    import bmesh
    rings = json.load(open(outline_json))
    def to_xy(lon, lat):
        u = (lon - meta["xmin"]) / (meta["xmax"] - meta["xmin"])
        v = (lat - meta["ymin"]) / (meta["ymax"] - meta["ymin"])
        return ((u - 0.5) * aspect, (v - 0.5))
    smat = bpy.data.materials.new("slab"); smat.use_nodes = True
    sb = smat.node_tree.nodes.get("Principled BSDF")
    sb.inputs["Base Color"].default_value = hex_lin(SLAB_HEX)
    sb.inputs["Roughness"].default_value = 1.0
    if "Specular IOR Level" in sb.inputs:
        sb.inputs["Specular IOR Level"].default_value = 0.0
    me = bpy.data.meshes.new("slab"); slabobj = bpy.data.objects.new("slab", me)
    scene.collection.objects.link(slabobj); slabobj.data.materials.append(smat)
    bm = bmesh.new(); nrings = 0
    for ring in rings:
        pts = [to_xy(p[0], p[1]) for p in ring]
        if len(pts) >= 2 and pts[0] == pts[-1]:
            pts = pts[:-1]                            # drop closing duplicate vertex
        if len(pts) < 3:
            continue
        vtop = [bm.verts.new((x, y, SLAB_TOP)) for (x, y) in pts]
        try:
            f = bm.faces.new(vtop)
        except ValueError:
            continue
        ex = bmesh.ops.extrude_face_region(bm, geom=[f])
        vnew = [e for e in ex["geom"] if isinstance(e, bmesh.types.BMVert)]
        bmesh.ops.translate(bm, verts=vnew, vec=(0, 0, -SLAB_THICK))   # -> walls + bottom
        nrings += 1
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free()
    print(f"[relief] slab: {nrings} ring(s), thickness {SLAB_THICK}")

# ---- a few bright white cloud puffs hovering around the snowy peaks --------
# Distinct volume spheres (not a mist band): placed over the highest terrain,
# floating above the peaks so each casts a soft shadow down-right. Dense white
# core + noise-carved fluffy edges + a touch of glow -> reads as cumulus, not haze.
if CLOUDS == 1 and os.path.exists(height_img_path):
    import numpy as np, random
    peakz = disp_scale
    cloud_z = peakz * CLOUD_HEIGHT                   # float above the peaks
    # find high-terrain cells from the height image (Blender rows are bottom-up)
    himg = htex.image
    W, H = himg.size; chn = himg.channels
    buf = np.empty(W * H * chn, dtype=np.float32)
    himg.pixels.foreach_get(buf)
    hgt = buf.reshape(H, W, chn)[:, :, 0]
    ys, xs = np.where((hgt > CLOUD_MINELEV) & (hgt < CLOUD_MAXELEV))  # mid-flank cells
    placed = []
    if len(xs):
        random.seed(CLOUD_SEED)
        order = list(range(len(xs))); random.shuffle(order)
        min_sep = 0.10                               # keep puffs separated (plane units)
        for i in order:
            px = (xs[i] / (W - 1) - 0.5) * aspect
            py = (ys[i] / (H - 1) - 0.5)
            if all((px - qx) ** 2 + (py - qy) ** 2 > min_sep ** 2 for qx, qy in placed):
                placed.append((px, py))
            if len(placed) >= CLOUD_N:
                break
    # white cloud material (SURFACE, not volume -> reliably bright white cotton)
    cmat = bpy.data.materials.new("cloud"); cmat.use_nodes = True
    cb = cmat.node_tree.nodes.get("Principled BSDF")
    cb.inputs["Base Color"].default_value = (1, 1, 1, 1)
    cb.inputs["Roughness"].default_value = 1.0
    if "Specular IOR Level" in cb.inputs:
        cb.inputs["Specular IOR Level"].default_value = 0.0
    if "Emission Color" in cb.inputs:                  # lift undersides so they stay white
        cb.inputs["Emission Color"].default_value = (1, 1, 1, 1)
        cb.inputs["Emission Strength"].default_value = CLOUD_GLOW
    # metaballs: clustered elements merge into a few lumpy white cotton puffs
    mball = bpy.data.metaballs.new("clouds")
    mball.resolution = max(CLOUD_SIZE * 0.4, 0.004)
    mball.render_resolution = max(CLOUD_SIZE * 0.22, 0.0025)
    mball.threshold = 0.6
    mobj = bpy.data.objects.new("clouds", mball)
    scene.collection.objects.link(mobj)
    mobj.data.materials.append(cmat)
    if hasattr(mobj, "visible_shadow"):                # clouds cast NO shadow
        mobj.visible_shadow = False
    elif hasattr(mobj, "cycles_visibility"):
        mobj.cycles_visibility.shadow = False
    for k, (px, py) in enumerate(placed):
        random.seed(CLOUD_SEED * 131 + k)
        for _ in range(random.randint(4, 6)):         # cluster -> one puffy lump
            el = mball.elements.new()
            el.co = (px + random.uniform(-1, 1) * CLOUD_SIZE * 0.9,
                     py + random.uniform(-1, 1) * CLOUD_SIZE * 0.6,
                     cloud_z + random.uniform(-1, 1) * CLOUD_SIZE * 0.35)
            el.radius = CLOUD_SIZE * random.uniform(0.7, 1.1)
    print(f"[relief] clouds: {len(placed)} white puffs at z~{cloud_z:.3f}, no shadow")

# ---- world: soft grey fill ------------------------------------------------
world = bpy.data.worlds.new("World"); scene.world = world
world.use_nodes = True
wbg = world.node_tree.nodes["Background"]
wbg.inputs["Color"].default_value = hex_lin(GROUND_HEX)
wbg.inputs["Strength"].default_value = 0.35

# ---- sun (low, NW, soft) --------------------------------------------------
sun_data = bpy.data.lights.new("Sun", 'SUN')
sun_data.energy = 4.0
sun_data.angle = math.radians(SUNSOFT)             # crisper = clearer single direction
sun = bpy.data.objects.new("Sun", sun_data)
scene.collection.objects.link(sun)
az = math.radians(SUNAZ); alt = math.radians(SUNALT)
# +X east, +Y north, +Z up; azimuth from north, clockwise (toward east)
sun_dir = Vector((math.sin(az) * math.cos(alt),
                  math.cos(az) * math.cos(alt),
                  math.sin(alt)))                  # points toward the sun
travel = -sun_dir                                  # direction light travels
sun.rotation_euler = Vector((0, 0, -1)).rotation_difference(travel).to_euler()

# ---- camera: ortho, top-down (or tilted) ----------------------------------
cam_data = bpy.data.cameras.new("Cam"); cam_data.type = 'ORTHO'
cam_data.sensor_fit = 'HORIZONTAL'                 # lock scale to width -> portrait adds grey top/bottom
cam_data.ortho_scale = aspect * MARGIN             # fit map width + side margin
cam_data.shift_y = SHIFTY                           # raise map in-frame (world_to_camera_view honours it,
                                                   # so labels stay aligned in both variants)
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
if abs(TILT) < 0.01:
    cam.location = (0, 0, 10)
    cam.rotation_euler = (0, 0, 0)                 # look straight down -Z
else:
    t = math.radians(TILT); r = 10.0
    cam.location = (0, -r * math.sin(t), r * math.cos(t))  # orbit south & up
    cam.rotation_euler = (Vector((0, 0, 0)) - Vector(cam.location)).to_track_quat('-Z', 'Y').to_euler()

# ---- auto-centre the visible map in the frame ------------------------------
# The plane is the DEM grid, and in sea mode that grid is padded west into the
# ocean (SEA_WEST), so centring the PLANE leaves the state sitting right-of-
# frame against a fat left margin. Measure what is actually visible -- land plus
# the blue band, NOT the invisible card-grey ocean sheet -- through the real
# camera (so tilt and terrain height are accounted for), then slide the camera
# to put that bbox in the middle. Runs BEFORE the label sidecar below, so the
# labels are projected through the corrected camera.
if AUTOCENTER:
    try:
        import numpy as _np
        from bpy_extras.object_utils import world_to_camera_view
        cam_data.shift_y = 0.0                       # measure uncentred; SHIFTY re-applied after
        bpy.context.view_layer.update()

        # these grids are ~30 Mpx; read one at a time and drop the full-res
        # buffer as soon as it is subsampled, so peak memory stays sane
        def _grid(png_path):
            im = bpy.data.images.load(png_path, check_existing=True)
            w, h, c = im.size[0], im.size[1], im.channels
            b = _np.empty(w * h * c, dtype=_np.float32); im.pixels.foreach_get(b)
            st = max(1, min(w, h) // 400)             # coarse sample; a bbox is robust to it
            g = b.reshape(h, w, c)[::st, ::st, 0].copy()   # row 0 = south
            del b
            return g
        vis = _grid(mask_png)
        if SEA and os.path.exists(sea_png):
            vis = _np.maximum(vis, (_grid(sea_png) > 0.05).astype(_np.float32))
        hg = _grid(height_img_path)
        rs, cs = _np.where(vis > 0.5)
        if len(rs):
            hh, ww = vis.shape
            xs = ((cs / (ww - 1)) - 0.5) * aspect
            ys = (rs / (hh - 1)) - 0.5
            zs = hg[rs, cs] * disp_scale
            tr = math.radians(TILT)
            vcam = ys * math.cos(tr) + zs * math.sin(tr)   # what "up the frame" means under tilt
            ext = [(xs.argmin(), 0), (xs.argmax(), 0), (vcam.argmin(), 1), (vcam.argmax(), 1)]
            us, vs = [], []
            for i, _axis in ext:
                co = world_to_camera_view(scene, cam, Vector((float(xs[i]), float(ys[i]), float(zs[i]))))
                us.append(co.x); vs.append(co.y)
            du = 0.5 - (min(us) + max(us)) / 2.0      # normalized screen offset needed
            dv = 0.5 - (min(vs) + max(vs)) / 2.0
            ow = cam_data.ortho_scale                 # frame width in world units
            oh = ow * scene.render.resolution_y / scene.render.resolution_x
            R = cam.matrix_world.to_3x3()
            cam.location = Vector(cam.location) + R @ Vector((-du * ow, -dv * oh, 0.0))
            bpy.context.view_layer.update()
            print(f"[relief] auto-centre: du={du:+.4f} dv={dv:+.4f} "
                  f"-> cam {tuple(round(v, 4) for v in cam.location)}")
        cam_data.shift_y = SHIFTY                     # deliberate offset FROM centred
        bpy.context.view_layer.update()
    except Exception as _e:
        print("[relief] auto-centre skipped:", _e)

# ---- projection sidecar (top-down only; the label layer assumes no tilt) ---
if abs(TILT) < 0.01:
    with open(os.path.join(outdir, f"{slug}_view.json"), "w") as vf:
        json.dump({"res_x": scene.render.resolution_x, "res_y": scene.render.resolution_y,
                   "ortho_scale": cam_data.ortho_scale, "aspect": aspect,
                   "xmin": meta["xmin"], "xmax": meta["xmax"],
                   "ymin": meta["ymin"], "ymax": meta["ymax"]}, vf, indent=2)

# ---- label screen positions for THIS camera (tilt-aware; for make_labels.py)
# Blender projects each city/peak (placed on the terrain surface) through the
# exact camera, so labels line up even on the tilted hero shot.
try:
    from bpy_extras.object_utils import world_to_camera_view
    import numpy as _np, csv as _csv
    root = os.path.abspath(os.path.join(here, ".."))
    hi = htex.image; Wc, Hc, chc = hi.size[0], hi.size[1], hi.channels
    _b = _np.empty(Wc * Hc * chc, dtype=_np.float32); hi.pixels.foreach_get(_b)
    hgtimg = _b.reshape(Hc, Wc, chc)[:, :, 0]        # rows bottom-up (row0 = south)
    def _proj(lat, lon):
        u = (lon - meta["xmin"]) / (meta["xmax"] - meta["xmin"])
        v = (lat - meta["ymin"]) / (meta["ymax"] - meta["ymin"])
        c = min(Wc - 1, max(0, round(u * (Wc - 1))))
        r = min(Hc - 1, max(0, round(v * (Hc - 1))))
        z = float(hgtimg[r, c]) * disp_scale         # sit on the rendered surface
        co = world_to_camera_view(scene, cam, Vector(((u - 0.5) * aspect, v - 0.5, z)))
        return [co.x * scene.render.resolution_x, (1 - co.y) * scene.render.resolution_y]
    pos = {"res_x": scene.render.resolution_x, "res_y": scene.render.resolution_y,
           "cities": {}, "peaks": {}, "features": {}}
    cp = os.path.join(root, "cities", f"{slug}.csv")
    if os.path.exists(cp):
        for row in _csv.DictReader(open(cp)):
            pos["cities"][row["name"]] = _proj(float(row["lat"]), float(row["long"]))
    pp = os.path.join(root, "peaks", f"{slug}.csv")
    if os.path.exists(pp):
        for row in _csv.DictReader(open(pp)):
            pos["peaks"][row["name"]] = _proj(float(row["lat"]), float(row["long"]))
    fp = os.path.join(root, "features", f"{slug}.csv")   # lakes / glaciers (area labels)
    if os.path.exists(fp):
        for row in _csv.DictReader(open(fp)):
            pos["features"][row["name"]] = _proj(float(row["lat"]), float(row["long"]))
    lp = os.path.join(outdir, f"{slug}_labelpos" + os.environ.get("BL_SUFFIX", "_blender") + ".json")
    with open(lp, "w") as lf:
        json.dump(pos, lf, indent=2)
    print("[relief] label positions ->", os.path.basename(lp))
except Exception as _e:
    print("[relief] labelpos skipped:", _e)

# ---- render ---------------------------------------------------------------
print(f"[relief] rendering {scene.render.resolution_x}x{scene.render.resolution_y} -> {out_png}")
bpy.ops.render.render(write_still=True)
print("[relief] done:", out_png)
