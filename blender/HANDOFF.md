# Blender relief-map pipeline — HANDOFF

**Goal:** Premium, 3D, *granular* shaded-relief maps of Indian states like the
mappdout/California reference (`relief-maps/wpneyp1blj661.jpg`). The existing
rayshader **2D** pipeline (`relief-maps/render_state.R`) plateaued — user says it
"looks 2D / basic / not granular." mappdout is made in **Blender**; we're moving to it.

## Why Blender (root-cause fixes)
- "looks 2D" → real displaced **3D mesh** (tilt camera or top-down, real cast shadows)
- "not granular" → fine DEM displaced onto real geometry, every ridge casts a real shadow
- "basic" → **Cycles** path-traced soft light = the tactile "carved model" look
Rayshader 2D is a painted top-down composite — it can't do the above.

## Status — PIPELINE WORKING END-TO-END (2026-07-07)
- **Blender installed:** 5.1.2 at `/opt/homebrew/bin/blender`, Metal GPU (Apple M4).
- **DONE `blender/export_dem.R`** — fetches/clips DEM (reuses cache), writes
  `output/<slug>_height.tif` (**float32**, north-up, elev norm 0..1 — the
  displacement source; the old `bitdepth=16` PNG call errored, this version's
  `png::writePNG` has no such arg), `_height.png` (8-bit preview),
  `_mask.png` (white=inside, hole-filled), `_meta.json`
  (extent, elev range km, **aspect**=true geo w:h).
- **DONE `blender/relief.py`** — Cycles scene + render (see below). Uttarakhand
  z10 renders in ~20 s at 2000 px/128 samples → `output/uttarakhand_blender.png`.
  Correct north-up orientation, granular carved relief, grey card + emboss shadow.
- **DONE `blender/render_state.sh`** — one-command wrapper (export if missing → render).
- **DONE `blender/README.md`** — full usage + env knobs + tuning notes.

### Blender 5.x API notes (differ from the 4.x plan below)
- No `scene.cycles.feature_set` (experimental gone); adaptive subdivision is a
  standard feature now.
- Adaptive subdivision moved onto the **Subdivision modifier**:
  `mod.use_adaptive_subdivision=True`, `mod.adaptive_space='PIXEL'`,
  `mod.adaptive_pixel_size` (= dicing px). `object.cycles.use_adaptive_subdivision`
  no longer exists.
- Displacement method is `material.displacement_method='DISPLACEMENT'` (not `.cycles`).
- View transform set to **Standard** (default AGX shifts the palette).

### Next (interactive / cowork) — see README "Status & next"
Grey card reads ~206 vs 215 target (nudge lighting or composite on exact #d7d7d7);
snow-white peaks; contrast (lower `BL_SUNALT` / higher `BL_EXAG`); z11/z12 re-export
for finer detail; then 4:5 framing + title + city labels in magick.

## Plan for relief.py (bpy, Blender 4.x, run headless: `blender -b --python relief.py -- <slug>`)
1. Factory-reset empty scene; engine=CYCLES; GPU via Metal (`prefs.compute_device_type='METAL'`); `feature_set='EXPERIMENTAL'` (for adaptive subdiv).
2. Plane scaled to `meta.aspect` (width=aspect, height=1). **Adaptive subdivision** (subsurf SIMPLE + `plane.cycles.use_adaptive_subdivision=True`) so displacement detail matches render res — this is the granularity win.
3. Material (`displacement_method='DISPLACEMENT'`): height_tex(Non-Color, Cubic) → ColorRamp(the palette) → Base Color; mask_tex → Principled **Alpha** (transparent outside state); **height×mask → Displacement node** (so outside is flat+transparent). Displacement scale in Blender units = `elev_range_km * (aspect/width_km) * EXAG`.
4. Sun lamp low angle (az ~315° NW, alt ~35°) + soft grey World (strength ~0.35) fill.
5. Optional grey ground plane (`#d7d7d7`=CA grey) just below z=0 → catches a real soft shadow = the "raised relief" emboss. `BL_GROUND=0` → `film_transparent=True` instead.
6. Camera ORTHO, `ortho_scale≈aspect*1.15`; top-down (loc 0,0,10) or tilt via `BL_TILT` deg for 3D.
7. Render res_x=RES, res_y=round(RES/aspect); RGBA PNG → `output/<slug>_blender.png`.
Env knobs to expose: `BL_EXAG`(~1.6), `BL_TILT`(0=top-down), `BL_SAMPLES`(128), `BL_RES`(2000), `BL_GROUND`(1).

## Carry-over facts (from the rayshader work — see `memory/project_relief_maps_pipeline.md`)
- **Palette (green lowlands → sienna mtns → cream peaks):** `#66A778 #8CB488 #B0BC93 #CFC196 #C69C5E #A6733E #BE8F58 #D5C8A2 #E7DDC5 #F3EDDE`. Convert sRGB→linear for Blender.
- **Aspect:** true w:h = `width_km/height_km` (already in meta). Rayshader bug was stretching WIDTH not height → looked fat; meta.aspect is correct.
- **Granularity needs a fine DEM:** current cache is **z10 (~130 m/px — too coarse)**. Start there to get the pipeline working, then re-export **z11/z12** (`Rscript blender/export_dem.R "Uttarakhand" 12`) for real detail. z12 ≈ SRTM-native ~30 m (big fetch).
- **Vertical exaggeration** = user wants dramatic mountains (rayshader used exag 6). Tune `BL_EXAG`.
- **Cities:** `cities/<slug>.csv` (name,lat,long,capital), Dehradun=capital. Labels can be composited in post (magick) using lat/long→pixel on meta extent (like render_state.R step 7), OR added as Blender text. Defer until look is locked.
- **Boundaries:** `public/maps/india-2021.geojson`, field `st_nm` (current post-2020 lines, India's claimed outer boundary).
- User = themapsdaily IG. Wants 4:5 or transparent output. Verify with pixels, don't oversell.

## First steps for you
1. Confirm Blender installed: `ls /Applications/Blender.app/Contents/MacOS/Blender`.
2. `cd relief-maps && Rscript blender/export_dem.R "Uttarakhand" 10` (uses cached z10).
3. Write `relief.py` per plan; render: `/Applications/Blender.app/Contents/MacOS/Blender -b --python blender/relief.py -- uttarakhand`.
4. Iterate lighting/exag/camera on the render; then re-export z12 for granularity; then labels + final 4K/8K.
