# Blender relief-map pipeline

Premium, path-traced **3D** shaded-relief maps of Indian states — the
mappdout / "California relief" look (`../wpneyp1blj661.jpg`), but built from a
real displaced mesh in Blender/Cycles instead of the flat 2D rayshader
composite (`../render_state.R`). This fixes the "looks 2D / basic / not
granular" plateau: every ridge is real geometry casting a real soft shadow.

## One command

```bash
cd relief-maps
blender/render_state.sh "Uttarakhand"          # -> output/uttarakhand_blender.png
```

The wrapper runs two steps (see below). All `BL_*` knobs pass through:

```bash
BL_EXAG=2.6 BL_RES=3000 BL_SAMPLES=256 blender/render_state.sh "Uttarakhand"
FORCE_EXPORT=1 blender/render_state.sh "Uttarakhand" 12   # re-fetch a finer DEM
```

## How it works

1. **`export_dem.R "<State>" [zoom]`** — reuses the cached DEM
   (`output/<slug>_dem_z<zoom>.tif`, fetched by the rayshader pipeline via
   `elevatr`, clipped to `../public/maps/india-2021.geojson` `st_nm`), fills tiny
   interior NoData holes, and writes:
   - `output/<slug>_height.tif` — **float32**, elevation normalized 0..1,
     north-up. The displacement source (no quantization → no terracing).
   - `output/<slug>_height.png` — 8-bit preview of the same.
   - `output/<slug>_mask.png` — white = inside the state (hole-filled).
   - `output/<slug>_meta.json` — extent, elev range (km), and true geographic
     `aspect` (= `width_km/height_km`, already un-squished).

2. **`relief.py <slug>`** (`blender -b --python`) — builds the Cycles scene:
   - Plane scaled to `meta.aspect`, given real geometry by a **Subdivision
     Surface modifier in adaptive PIXEL-dicing mode** (Blender 5.x: adaptive
     subdivision lives on the modifier, not `object.cycles`) → subdivides to
     render resolution, which is the granularity win.
   - Material: height → 10-stop hypsometric **ColorRamp** (Base Color),
     `mask` → **Alpha** (transparent outside), `height × mask` → **Displacement**
     node (`displacement_method='DISPLACEMENT'`, midlevel 0 so outside stays
     flat). Displacement scale = `elev_range_km · aspect / width_km · EXAG`
     (true vertical proportion × exaggeration).
   - Low **NW sun** (soft, `angle` for penumbra) + soft grey world fill.
   - Grey **#d7d7d7 ground card** just below z=0 catches the emboss drop shadow
     (`BL_GROUND=0` → `film_transparent` cutout instead).
   - **Ortho** camera, top-down (`BL_TILT` deg to tip into 3D).
   - **Standard** view transform (AGX would shift the palette), 16-bit RGBA PNG.

## Env knobs (`relief.py`)

| var | default | meaning |
|-----|---------|---------|
| `BL_EXAG`     | 2.8  | vertical exaggeration multiplier |
| `BL_TILT`     | 0    | camera tilt from top-down (deg); >0 = 3/4 view |
| `BL_SAMPLES`  | 128  | Cycles samples (denoised with OIDN) |
| `BL_RES`      | 1600 | render width px (height = round(w/aspect)) |
| `BL_GROUND`   | 1    | 1 = grey card + shadow, 0 = transparent cutout |
| `BL_DEVICE`   | GPU  | GPU (Metal) or CPU |
| `BL_DICING`   | 1.0  | adaptive dicing, px per micropoly edge (lower = finer) |
| `BL_SUNALT`   | 30   | sun altitude (deg) |
| `BL_SUNAZ`    | 285  | sun azimuth (deg from N, clockwise; 285 = WNW, shadows rake L→R) |
| `BL_SUNSOFT`  | 1.2  | sun angular size (deg); smaller = crisper shadows |
| `BL_SNOWLINE` | 0.60 | normalized elev where snow caps begin (1 = highest peak); ≥1 = off |
| `BL_SAT`      | 1.22 | colour saturation boost (1.0 = off) for a catchier map |
| `BL_RIVERS`   | 1    | 1 = paint thin rivers if `<slug>_rivers.png` exists |
| `BL_LAKES`    | 0    | 1 = paint lakes/reservoirs blue if `<slug>_lakes.png` exists |
| `BL_LAKEHEX`  | #3A79A8 | lake fill colour |
| `BL_SEA`      | 0    | 1 = paint a coastal sea band if `<slug>_sea.png` exists (see Coastal states) |
| `BL_SEAHEX`   | #2E7C9E | sea (ocean) blue |
| `BL_BEACH`    | 0    | 1 = flat golden sand shore if `<slug>_beach.png` exists. Paints the sand **and zeroes displacement there**, so beaches sit flat at sea level instead of being extruded up with the coastal terrain |
| `BL_BEACHHEX` | #E7D3A1 | beach sand colour |
| `BL_COLORGAMMA`| 1.0 | gamma on the height→palette input ONLY (not displacement/snow); <1 lifts low ground into the green stops — for mostly-low states (Goa: half under 63 m of 0–961 m) so the lush lowland isn't bottom-stop sand |
| `BL_SLAB`     | 0    | 1 = extrude a solid base slab (thick carved-model side walls) |
| `BL_SLABTHICK`| 0.05 | slab thickness (plane units) |
| `BL_SLABHEX`  | #b9b3a6 | slab wall colour |
| `BL_SUFFIX`   | _blender | output filename suffix (`_hero` etc. to avoid clobbering) |
| `BL_CLOUDS`   | 0    | clouds OFF by default; 1 = a few metaball white puffs (see below) |
| `BL_CANVAS`   | 4:5  | final canvas W:H (portrait); map centred, grey fills top/bottom |
| `BL_MARGIN`   | 1.22 | horizontal fit = map width × this (bigger = more side grey / smaller map) |
| `BL_AUTOCENTER`| 0   | 1 = centre the **visible map** (land + blue band) in the frame instead of the DEM plane. Needed in sea mode, where the grid is padded west into the ocean so the state sits right-of-frame. Measured through the real (tilted) camera, so labels follow. **Opt-in** — it re-frames the shot, so an already-signed-off hero re-renders identically without it |
| `BL_OCEAN`    | 1    | use `<slug>_ocean.png` (hard water mask) for a flat **shadeless** ocean sheet; no-op unless that file exists |
| `BL_FLATLIGHT`| 0.87 | brightness a flat lit face renders at; the shadeless sheet is emitted at exactly this so it matches the lit grey card. Retune only if the sun/world lighting changes |
| `BL_SHIFTY`   | -0.075 | vertical lens shift; <0 raises the map, opening a grey **bottom band** for the state-name title (+small top margin for the logo). 0 = centred. Honoured by `world_to_camera_view` so labels stay aligned. |
| `BL_CLOUDN`   | 6    | number of puffs (when `BL_CLOUDS=1`) |
| `BL_CLOUDSIZE`| 0.030| puff radius (plane units; map width = aspect) |
| `BL_CLOUDGLOW`| 0.35 | puff emission (keeps undersides white, not grey) |
| `BL_CLOUDHT`  | 1.5  | puff altitude = peak height × this |
| `BL_CLOUDELEV`/`BL_CLOUDELEVHI` | 0.30 / 0.52 | place puffs over this norm-elev band |
| `BL_CLOUDSEED`| 7    | reshuffle puff positions |

## Features

- **Snow caps** — base colour blends to white above `BL_SNOWLINE` (smooth band).
- **Rivers** — `export_dem.R` rasterizes the cached OSM `<slug>_rivers.gpkg` onto
  the exact DEM grid (`<slug>_rivers.png`); `relief.py` paints muted blue
  `#4E86A6` where it registers (pixel-perfect with the terrain).
- **Clouds** — a few **metaball** white puffs (surfaces, not volume → reliably
  bright white, no grey mist). Positions are found by reading the height map
  (numpy) and picking well-separated cells in a mid-mountain elev band, so the
  puffs sit on the darker flanks *around* the peaks where white reads. They
  **cast no shadow** (`visible_shadow=False`). Tune count/size/height/seed via
  the `BL_CLOUD*` knobs; `BL_CLOUDS=0` to drop them.
- **Portrait canvas** — `BL_CANVAS` (default 4:5) renders a vertical frame with
  the map centred and grey above/below (camera `sensor_fit=HORIZONTAL`, so the
  map stays width-fitted and the extra height is pure grey).

## Coastal states (sea band) — Goa

Landlocked states clip the DEM to the boundary and render everything outside as
the grey card. A coastal state (Goa) needs the ocean shown, so `export_dem.R`
has an **opt-in sea mode** (env-gated; default off, so inland states are
untouched):

```bash
# fetch water first (estuaries/reservoirs + rivers); OSM `osmdata` was hanging,
# so fetch_rivers.R goes straight to Overpass (set OVERPASS_URL for a mirror)
Rscript blender/fetch_lakes.R  "Goa"
Rscript blender/fetch_rivers.R "Goa"                       # -> <slug>_rivers.gpkg
# export: high-detail boundary, z12 grid, narrow rivers, flat beaches, sea band
BOUNDARY_GPKG=output/goa/goa_boundary.gpkg \
SEA_WEST=0.18 SEA_NS=0.04 SEA_LEVEL=5 SEA_BAND_KM=2.2 DEM_CLAMP_LO=0.002 \
RIVER_BUFFER_M=35 BEACH_ELEV_M=8 BEACH_DIST_M=700 COAST_TAPER_M=500 \
WAVES=1 WAVE_RINGS_M=260,620,1050 WAVE_THICK_M=55 \
  Rscript blender/export_dem.R "Goa" 12
```

### The Goa hero — EXACT command (this is the delivered image)

Keep this in sync with any re-render. The knobs were once lost and had to be
reverse-engineered out of the rendered pixels (`BL_MARGIN` from label geometry,
`BL_SEAHEX` from the water's RGB); don't let that happen again.

```bash
BL_SUFFIX=_hero BL_SLAB=0 BL_TILT=18 BL_SEA=1 BL_SEAHEX="#A7D5EA" BL_WAVES=1 BL_COAST=1 \
BL_BEACH=1 BL_LAKES=1 BL_RIVERS=1 BL_COLORGAMMA=0.75 BL_SNOWLINE=1.1 BL_SAT=1.05 \
BL_EXAG=4.5 BL_MARGIN=1.08 BL_AUTOCENTER=1 BL_SHIFTY=0 BL_RES=3200 BL_SAMPLES=200 \
  blender/render_state.sh "Goa"
python3 blender/make_labels.py "goa" --variant hero --width 3200
```

> **`relief.py` writes the label positions, so labels and terrain must come from
> the SAME run.** `<slug>_labelpos_hero.json` is projected through the live
> camera; an older tilt-unaware build wrote *top-down* positions for a `BL_TILT=18`
> render, which put every Goa label 15–60 px off its terrain (worst at the frame
> edges — it is what pushed the Palolem dot into the sea). If a label looks
> subtly misplaced, re-render rather than nudging the CSV: check by fitting the
> stored positions against the projection, `tilt=0` residuals ≈ 0 px on a tilted
> shot means the sidecar is stale.

Extra export knobs used above:

| var | default | meaning |
|-----|---------|---------|
| `BOUNDARY_GPKG` | — | high-detail single-state polygon instead of the national geojson. `india-2021.geojson` is heavily simplified (**Goa = 88 vertices / 388 km perimeter = a point every 4.4 km**, which renders visibly "squary"). The OSM admin boundary (Goa relation `11251493`) gives **7671 vertices** — real headlands, coves and estuary mouths. Fetch it with a POST to Overpass (`relation["boundary"="administrative"]["admin_level"="4"]["name"="Goa"](bbox);out geom;`), stitch member ways with `st_polygonize`, keep the largest part (drops stray fragments) |
| `RIVER_BUFFER_M` | 200 | river half-width in metres; 200 reads FAT on a small dense-network state — Goa uses **60** |
| `BEACH_ELEV_M` / `BEACH_DIST_M` | 8 / 700 | beach zone = in-state land at/below this elevation and within this distance of the ocean |

**Zoom:** a small state can afford **z12** (Goa = 5127×5961) for genuinely refined ridge-and-valley detail; it also resolves the summits better (max elev 961 m at z10 → **1022 m** at z12). Pair it with a higher `BL_EXAG` (Goa: **4.5**) since a low-relief state looks flat at the default 2.8.

> **Gotcha — `terra::distance()` is geodesic on lon/lat and never finishes on a z12
> grid.** All distance fields here go through the `fast_dist()` helper, which
> computes on a downsampled grid and resamples back (smooth fields, so it's
> lossless in practice): z12 export went from *hung* to **under 100 s**.

- **`SEA_WEST` > 0 turns on sea mode.** The DEM is fetched over the state bbox
  extended `SEA_WEST`° west (+`SEA_NS`° N/S) *unclipped*; the terrain is still
  masked to the state polygon, but the extra western strip carries the ocean.
- **`<slug>_sea.png`** = a 0..1 coast-proximity field: ocean cells (outside the
  state, ≤ `SEA_LEVEL` m, connected to the west frame edge so inland void specks
  don't leak in), smoothstepped to 0 by `SEA_FADE_KM` offshore and box-blurred so
  it reads as clean water. `relief.py` (`BL_SEA=1`) mixes `BL_SEAHEX` in by that
  factor and sets `alpha = max(state mask, sea factor)`, so the blue is opaque at
  the shore and dissolves into the grey card offshore = **blue sea + grey frame**.
- **`DEM_CLAMP_LO`** is usually needed (elevatr terrain tiles drop a few deep-void
  pixels inside the state that otherwise stretch the 0..1 range and wash the
  palette — Goa had a −565 m void; `0.002` floors it to ≈−1 m).
- **Estuaries / backwaters / lagoons** come free from the lakes layer
  (`natural=water` captures the tidal Mandovi/Zuari estuaries + reservoirs), and
  **rivers** from the rivers layer — no special coastal handling.
- **Hero must KEEP `BL_SEA=1`.** With the sea off, the slab's grey side wall is
  exposed along the shore, so the golden beach reads as sitting on a grey plinth.
  With it on, the flat sea sheet at z=0 covers the seaward wall and the sand meets
  water at sea level; grey walls then show only on the inland N/E/S borders (the
  intended carved edge) and on genuine rocky headlands. (The old reason for
  `BL_SEA=0` — black shadow notches at concave estuary mouths — is fixed by the
  high-detail `BOUNDARY_GPKG`.)
- **Check city coords against the water polygons** on a riverine coast:
  `st_distance(pt, st_union(lakes))`. Panaji at 15.4989 was only 299 m from water
  and visually landed inside the Mandovi channel; 15.4909 is 670 m clear. Also
  filter `<slug>_lakes.gpkg` to ≥0.5 km² to drop pond / salt-pan clutter.
- **beach** feature type in `features/<slug>.csv` → a sand dot + warm-sand label
  in `make_labels.py`; `river`/`falls`/`estuary` → water blue. The optional
  `place` column takes `above` to flip a beach name above its dot (Palolem's
  default below-the-dot name collided with Canacona just south-east of it).
- **Water must not catch shadows** (`<slug>_ocean.png` + `BL_OCEAN=1`). The blue
  band only reaches `SEA_BAND_KM` offshore; anything wider — bays, estuary
  mouths, the open sea — fell through to the transparent grey card, which
  **caught the coastal hills' cast shadow**, so grey smudges floated on the water
  off Panaji / Vasco / Canacona. `export_dem.R` now also writes the *hard* ocean
  mask, and `relief.py` lays a flat sheet over the whole water body: card grey
  where no band reaches (invisible against the card), sea blue inside the band.
  It is **shadeless** — black albedo so it has no diffuse response at all, with
  the same colour re-emitted at `BL_FLATLIGHT`, which reproduces the old
  *unshadowed* water and the lit card exactly (both measure 202/255, no seam).
  Two gotchas, both fixed by `Is Camera Ray`:
  - as a real emitter the sheet **spilled bounce light** onto the card past the
    plane edge (202 → 224), so emission is camera-ray only;
  - as a real occluder it **blocked skylight** from the card past its edge
    (202 → 186, a visible seam), so its *alpha* is camera-ray only too. The sheet
    is a pure matte: it hides the shadowed card beneath it and changes nothing
    else in the lighting. Land, beaches and inland lakes keep normal shading.

## Big states — Maharashtra

Maharashtra (307,713 km², aspect 1.232) is the first state large enough that the
**bbox itself** is the problem, and the first *plateau* state with a coast.

### The Maharashtra hero — EXACT command (this is the delivered image)

```bash
# one-time data. None of the stock fetch_*.R helpers survive a bbox this size,
# so the fetch/build scripts live in blender/maharashtra/ (see "Overpass on a
# big bbox" below). Run them from relief-maps/.
blender/maharashtra/fetch_boundary_mh.sh          # Overpass relation 1950884
Rscript blender/maharashtra/build_boundary_mh.R   # -> maharashtra_boundary.gpkg (52,534 verts)
blender/maharashtra/fetch_lakes_mh.sh
Rscript blender/maharashtra/build_lakes_mh.R      # -> maharashtra_lakes.gpkg  (213 bodies >= 3 km2)
blender/maharashtra/fetch_rivers_tiled_mh.sh      # 9 tiles
blender/maharashtra/refetch_rivers_mh.sh          # retries any failed tile as quarters
python3 blender/maharashtra/build_rivers_mh.py    # merge + dedupe by way id
Rscript blender/maharashtra/build_rivers_mh.R     # -> maharashtra_rivers.gpkg (named systems >= 25 km)
Rscript blender/maharashtra/despike_mh.R          # MUST run before export (see below)

BOUNDARY_GPKG=output/maharashtra/maharashtra_boundary.gpkg \
SEA_WEST=0.25 SEA_NS=0.05 SEA_LEVEL=5 SEA_BAND_KM=6.0 \
COAST_TAPER_M=1200 DEM_CLAMP_LO=0.002 BEACH_ELEV_M=10 BEACH_DIST_M=1500 \
WAVES=1 WAVE_RINGS_M=800,1800,3000 WAVE_THICK_M=130 RIVER_BUFFER_M=300 \
  Rscript blender/export_dem.R "Maharashtra" 9

BL_SUFFIX=_hero BL_SLAB=0 BL_TILT=18 BL_SEA=1 BL_SEAHEX="#A7D5EA" BL_WAVES=1 \
BL_COAST=1 BL_BEACH=1 BL_LAKES=1 BL_RIVERS=1 BL_SNOWLINE=1.1 BL_SAT=1.05 \
BL_EXAG=6.5 BL_MARGIN=1.08 BL_AUTOCENTER=1 BL_SHIFTY=-0.06 BL_RES=3200 BL_SAMPLES=200 \
  blender/render_state.sh "Maharashtra" 9
python3 blender/make_labels.py "maharashtra" --variant hero --width 3200
```

- **Zoom z9, not z10.** Scale from a known state rather than guessing: Jharkhand
  z10 = 1504 px/deg, so Maharashtra's 8.5° × 6.5° would be ~123 M cells at z10.
  z9 gives 6331×4866 (30.8 M, ≈ Kerala) and still 2× oversamples a 3200 px
  render. The cost is truncated summits — Kalsubai reads 1490 m against its true
  1646 m, and **Salher (1539 m) ends up the DEM's high point.** The labels carry
  the true elevations, so this is invisible in the output.
- **`BL_EXAG=6.5`, the highest in the series.** Relief ratio is only
  1.539 km / 897 km = 0.0017, ~6× flatter than Goa and 5× flatter than Kerala.
  Match the *displacement scale*, not the exag number: `elev_range·aspect/width`
  puts 6.5 here at 0.0137 units ≈ Kerala's 3.0.
- **Wide state ⇒ width-fit, so `BL_MARGIN` goes DOWN not up.** Kerala (tall,
  aspect 0.60) needed 1.72; Maharashtra needs **1.08** to fill 92% of the frame
  width. The 4:5 canvas then leaves ~43% of the height grey, split by
  `BL_SHIFTY=-0.06` into a ~16% top margin and a ~25% bottom title band.
- **`BL_SLAB=0`** and `BL_SEA=1`, as on every coastal state.
- Coastal-label drift (the Kerala problem) measured **−8…+17 px at 3200** —
  within the marker radius. It scales with N–S extent *relative to the frame*,
  so a wide state barely shows it and needs no lon correction.

### DEM despiking — do this before trusting the elevation range

`elevatr` handed back a **2158 m** maximum for a state whose high point is
Kalsubai at 1646 m: void *clusters* (a 2158 m spike sitting beside −427 m cells).
Left alone they stretch the 0..1 normalization and throw away a quarter of the
palette. Generalise the Kerala single-cell fix into a **local-outlier filter**:

```r
med <- terra::focal(dem, w = 5, fun = "median", na.rm = TRUE)
fixed <- terra::ifel(abs(dem - med) > 200, med, dem)   # 518 of 14.6M cells
```

Pick the threshold by **measuring, not guessing**: real terrain — including the
Western Ghats escarpment, the steepest ground in the state — stays under 160 m
deviation from its 5×5 median at the 99.99th percentile, while the void tail runs
to 1585 m. That gap is where the threshold goes. Overwrite the cached
`_dem_z9_sea.tif` and re-run `export_dem.R`; the range drops to 1–1539 m.

### Overpass on a big bbox — tile it

At 8.7° × 6.8° every stock helper fails (`Dispatcher_Client::request_read_and_idx::
timeout`), and mirror-cycling alone is not enough — the boundary and reservoirs
came back from `overpass.private.coffee`, but `waterway=river` failed on **all
three** mirrors:

- **Rivers: fetch as 9 tiles** (~2.9° × 2.3°), cycling mirrors per tile with a
  pause between. Two northern tiles still failed on every mirror; re-fetching
  just those as **quarters** cleared them 8/8. Merge and de-duplicate by way `id`
  (tiles share edges) → 6134 unique ways.
  **A failed tile still writes a file**, so a tile *count* looks complete while
  the data is an HTML error page — validate by parsing, and refuse to build a
  partial layer.
- **Rivers must be length-filtered here** (the filter the pipeline had dropped):
  keep named systems totalling ≥ 25 km plus unnamed ways ≥ 6 km → 3023 ways /
  36,176 km becomes 1475 / 29,684 km. Unfiltered, the plateau renders as a blue
  web. Top systems land as expected: Godavari 731 km, Purna 676, Penganga 651,
  Wardha 453, Bhima 368, Wainganga 329, Krishna 321, Tapi 270.
- **Reservoirs, not "all water".** A blanket `natural=water` over this bbox pulls
  every farm pond. Query `water=reservoir` + `landuse=reservoir` + water
  *relations*, then area-filter ≥ 3 km² (213 bodies: Jayakwadi 275 km², Ujani
  234, Koyna 102).
- **`sf::st_node()` chokes** on a 986-element sfc in this build — `st_union()`
  alone polygonizes fine, since OSM member ways share exact endpoint coords.
  OSM water rings self-intersect, so **`sf::sf_use_s2(FALSE)`**; `st_area()` then
  wants `lwgeom`, so take areas in an equal-area projection
  (`+proj=laea +lat_0=19 +lon_0=76.7`) instead.

## Very wide states — Meghalaya

Meghalaya (22,429 km²) is small in area but **aspect 2.479** — 299 km wide by
121 km tall, twice as wide-to-tall as Maharashtra (1.232) and the extreme end of
the series. It is also the first state whose *shape*, not its size, drives the
framing decisions.

### The Meghalaya hero — EXACT command (this is the delivered image)

```bash
# one-time data. osmdata hangs or 429s on this bbox even though it is small, so
# rivers and lakes go through curl + mirror cycling like the big states.
blender/meghalaya/fetch_boundary_ml.sh        # Overpass relation 2027521
Rscript blender/meghalaya/build_boundary_ml.R # -> meghalaya_boundary.gpkg (6461 verts)
blender/meghalaya/fetch_rivers_ml.sh
Rscript blender/meghalaya/build_rivers_ml.R   # -> meghalaya_rivers.gpkg (226 ways / 3285 km)
blender/meghalaya/fetch_lakes_ml.sh
Rscript blender/meghalaya/build_lakes_ml.R    # -> meghalaya_lakes.gpkg  (28 bodies >= 0.4 km2)

BOUNDARY_GPKG=output/meghalaya/meghalaya_boundary.gpkg \
RIVER_BUFFER_M=110 DEM_CLAMP_LO=0.0001 \
  Rscript blender/export_dem.R "Meghalaya" 11

BL_SUFFIX=_hero BL_SLAB=1 BL_TILT=16 BL_LAKES=1 BL_RIVERS=1 \
BL_SNOWLINE=1.1 BL_SAT=1.06 BL_EXAG=2.4 BL_MARGIN=1.06 BL_SHIFTY=-0.085 \
BL_RES=3200 BL_SAMPLES=200 \
  blender/render_state.sh "Meghalaya" 11
python3 blender/make_labels.py "meghalaya" --variant hero --width 3200
```

- **A very wide state is a ribbon in a 4:5 frame — accept it and budget the grey.**
  The camera is width-fit, so once `BL_MARGIN` is near 1.0 the map cannot get any
  bigger: it fills ~96% of frame width but only **32% of frame height**, leaving
  **68% grey** (Maharashtra was 43%). Confirmed as the intended look — it reads
  editorial, and the oversized bottom band is the state-title area. `BL_SHIFTY`
  does the work: **-0.085** splits the grey ~28% top / ~40% bottom. Measure the
  split rather than guessing, by trimming the render to its content bbox:
  `magick <f> -fuzz 6% -trim -format "%wx%h%O" info:`.
- **Do not push `BL_MARGIN` to 1.0.** At 1.03 the content bbox measured 99% of
  frame width and the drop shadow was clipping the right edge; 1.06 restores the
  breathing room at no visible cost in map size.
- **`BL_EXAG=2.4`.** Anchor on the *displacement scale* as always — 2.4 here is
  0.0387 units, matching Manipur's 0.0396. Note the trap: relief relative to the
  N-S extent (1.95 km / 121 km) is actually **steeper** than Manipur's, because
  the short dimension is what the plane's unit height maps to. A wide state does
  not automatically need Maharashtra-style exaggeration; compute, don't assume.
- **z11** (8830×3213, 17.6 M cells) — a small-area state can afford the finer
  grid, and it matters here because the whole point of the map is the Cherrapunji
  escarpment. The DEM max of 1964 m lands within 1 m of Shillong Peak's true
  1965 m, so summits are not truncated the way z9 truncated Maharashtra's.
- **Voids: clamp, don't despike.** elevatr returned a −425 m floor, but only
  **61 cells** were below 0 — the Maharashtra 5×5-median despike is overkill at
  that count. `DEM_CLAMP_LO=0.0001` floors it to 12 m (the 0.01th percentile, and
  a realistic value for the Bangladesh-border plain), recovering ~18% of the
  palette. Worth measuring the local-outlier profile anyway: real terrain here —
  *including* the escarpment, the steepest ground in the state — stays within
  **41 m** of its 5×5 median at the 99.999th percentile against a void tail of
  1370 m, so the two populations are cleanly separable either way.
- **Hypsometry is unusually EVEN** (12.5% under 100 m, then ~5% per 100 m band
  through the middle, 4.9% above 1600 m) — no plateau spike, so evenly spaced
  palette stops all earn their pixels and **`BL_COLORGAMMA` stays 1.0**. This is
  the opposite of Maharashtra, where 80% of the state sat in one band.
- **`RIVER_BUFFER_M=110`** — scale by render px/km as always: 299 km at 3200 px is
  ~10.7 px/km, between Goa's 32 (buffer 60) and Maharashtra's 3.3 (buffer 300).
  Length-filter the rivers (named systems ≥12 km, unnamed ways ≥4 km): Meghalaya
  is the wettest place on earth and has the densest OSM network per km² in the
  series, 436 in-state ways / 3839 km unfiltered.

## Wide + high states — Arunachal Pradesh

Arunachal (83,743 km²) is the widest *large* state in the series (**aspect 1.891**,
573 km × 303 km) and the one with the biggest elevation range (**107–6,996 m**,
Kangto 7,060 m). It is Meghalaya's framing problem combined with J&K's relief.

### The Arunachal hero — EXACT command (this is the delivered image)

```bash
# one-time data. Big bbox (5.83deg x 2.72deg) -> tiled Overpass, as Maharashtra.
blender/arunachal_pradesh/fetch_boundary_ap.sh       # relation 2027346
Rscript blender/arunachal_pradesh/build_boundary_ap.R # -> _boundary.gpkg (10,966 verts, 83,119 km2)
blender/arunachal_pradesh/fetch_water_ap.sh rivers    # 3x2 tiles
blender/arunachal_pradesh/refetch_rivers_ap.sh        # quarters any failed tile
python3 blender/arunachal_pradesh/build_rivers_ap.py  # merge + dedupe by way id
Rscript blender/arunachal_pradesh/build_rivers_ap.R   # -> _rivers.gpkg (367 ways / 7,567 km)

BOUNDARY_GPKG=output/arunachal_pradesh/arunachal_pradesh_boundary.gpkg \
DEM_CLAMP_LO=0.0001 RIVER_BUFFER_M=200 \
  Rscript blender/export_dem.R "Arunachal Pradesh" 10

BL_SUFFIX=_hero BL_SLAB=1 BL_TILT=18 BL_RIVERS=1 \
BL_SNOWLINE=0.60 BL_SAT=1.12 BL_EXAG=2.8 BL_MARGIN=1.06 BL_SHIFTY=-0.10 \
BL_RES=3840 BL_SAMPLES=256 \
  blender/render_state.sh "Arunachal Pradesh" 10
python3 blender/make_labels.py "arunachal_pradesh" --variant hero --width 3840
```

- **z10** = 8725×4074 (35.5 M cells). Summits barely truncate: Kangto reads
  6,996 m against its true 7,060 m (−0.9%), so unlike Maharashtra's z9 the DEM
  can be trusted to *locate* peaks (see below).
- **Clamp, don't despike — and here that is not optional but mandatory.** The
  elevatr floor is −846 m, yet only **30 cells** are negative. Critically, the
  Maharashtra 5×5-median despike would **destroy real terrain here**: Arunachal's
  genuine slopes (the Siang gorge, the steepest ground in India) deviate
  **245 m at p99.99 and up to 708 m** from their local median, so no threshold
  separates terrain from voids the way it does on a plateau state.
  `DEM_CLAMP_LO=0.0001` floors it to 107 m and recovers ~11% of the palette.
- **`BL_MARGIN=1.06` + `BL_SHIFTY=-0.10`** → 97% frame width, 40% height,
  22% top / 37% bottom grey. Same ribbon-in-a-4:5-frame budget as Meghalaya.
  **The cast shadow reaching the right frame edge is house style, not a bug** —
  Meghalaya, Himachal, J&K and Manipur all measure a 0 px shadow gap with
  ~93–97 darkness at the edge, identical to this. Do not spend margin "fixing"
  it; only Maharashtra (coastal, `BL_SLAB=0`+`AUTOCENTER`) has clearance.
- **`BL_EXAG=2.8`** (the default) = 0.0636 displacement units, matching J&K's
  0.060 — the elevation ranges are nearly identical (6.9 vs 6.8 km). A wide state
  does not automatically need Maharashtra-style exaggeration.
- **`BL_SNOWLINE=0.60`** (≈4,240 m). 0.66 is the textbook Eastern-Himalayan
  snowline but leaves only ~1.4% of the state white, which reads weak across a
  573 km ribbon; 0.60 gives the northern crest a continuous cap.
- **The palette must ROTATE HUE, or the state renders as one green slab.** ~80%
  of Arunachal lies below 3,300 m and it is India's most densely forested state,
  so a first draft that held hue ~100 across five green stops painted **100% of
  the terrain green with a hue p10–p90 of only 86–111** (Himachal spans 32–117).
  Rotating 95→105→98→82→62→45→33 and turning olive at s4 (~3,200 m) fixed it.
  Verify by sampling, not eye: rendered greens now measure **hue 99 / sat 0.43 /
  lum 0.31** against Himachal's approved 95 / 0.42 / 0.37 (`BL_SAT=1.12`).
- **Peaks: the DEM is the authority, remembered coordinates are not.** Three of
  four first-pass coords were wrong — Gorichen's "known" position read 3,711 m
  and Dapha Bum's 1,601 m, both sitting in valleys. Recipe that worked: mask the
  DEM to the polygon, find well-separated local maxima per *region*, then match
  names to summits and confirm against PeakVisor/Wikipedia. Every kept peak lands
  within 0.2 km of its cited coordinate. It also settles disputes: **Gorichen is
  6,492 m, not the widely repeated 6,858 m** — a 6,858 m peak would read ~6,770
  in this DEM, and its massif tops out at 6,415.
- **Arunachal's high peaks all cluster within ~16 km** on the Tawang/Kameng
  border, so at most two fit. Kangto (7,060) + Gorichen (6,492, sacred/tourist)
  are kept; **Nyegi Kangsang (7,047) is dropped** — 12 km from Kangto, on the
  same massif, and near-identical in height, so it is visually redundant and
  collides. Dapha Bum (4,578, Namdapha) carries the east.
- **No lakes are labelled, and that is geography not omission.** Arunachal has no
  large natural standing water: Sela, Sangetsar/Madhuri and Mehao are all
  ≲0.4 km², which at 6.3 px/km is a 3–4 px dot — below the J&K Mansar Lake
  threshold (0.6 km², dropped for rendering as no visible blue). The only thing
  a `natural=water` layer would add is the braided Siang/Brahmaputra channel.

## Tall, flat plateau states — Chhattisgarh

Chhattisgarh (135,578 km², aspect **0.613**) is Kerala-shaped (tall and narrow)
but Jharkhand-natured (a landlocked, forested plateau). It is the **flattest
state in the series**: 1.214 km of relief over a 704 km north-south extent, a
ratio of 0.0017.

### The Chhattisgarh hero — EXACT command (this is the delivered image)

```bash
# one-time data. Run from relief-maps/.
blender/chhattisgarh/fetch_boundary_cg.sh        # Overpass, admin_level=4
Rscript blender/chhattisgarh/build_boundary_cg.R # -> chhattisgarh_boundary.gpkg (20,443 verts)
blender/chhattisgarh/fetch_rivers_cg.sh          # single shot, 3999 ways
Rscript blender/chhattisgarh/build_rivers_cg.R   # -> chhattisgarh_rivers.gpkg (724 ways / 15,275 km)
blender/chhattisgarh/fetch_lakes_cg.sh           # 6 TILES (see below)
Rscript blender/chhattisgarh/build_lakes_cg.R    # -> chhattisgarh_lakes.gpkg (33 bodies >= 2.5 km2)

BOUNDARY_GPKG=output/chhattisgarh/chhattisgarh_boundary.gpkg \
DEM_CLAMP_LO=0.0001 RIVER_BUFFER_M=220 \
  Rscript blender/export_dem.R "Chhattisgarh" 10

BL_SUFFIX=_hero BL_SLAB=1 BL_TILT=18 BL_LAKES=1 BL_RIVERS=1 BL_SNOWLINE=1.1 BL_SAT=1.06 \
BL_COLORGAMMA=0.8 BL_EXAG=9.1 BL_MARGIN=1.64 BL_SHIFTY=-0.072 BL_RES=3200 BL_SAMPLES=200 \
  blender/render_state.sh "Chhattisgarh" 10
python3 blender/make_labels.py "chhattisgarh" --variant hero --width 3200
```

### ⚠️ The palette file must contain BARE hex lines

`relief.py` accepts a stop only when the **whole stripped line** is `#RRGGBB`
(`re.fullmatch`). A file written as `#A1B06D  # 51 m  paddy` parses to **zero
stops**, and the state silently falls back to the built-in default palette —
there is no error, only the absence of the `[relief] palette override:` line in
the log. This cost a full render here: the map came back orange with cream
"snow" peaks (the default's `#C69C5E`/`#E7DDC5` stops) on a state that has no
snow and tops out at 1265 m. **Check for that log line, and confirm a rendered
pixel's hue, before believing a palette.** Annotations go on their own lines.

### `BL_COLORGAMMA` is the lever for a plateau hypsometry

77% of Chhattisgarh lies between 200 and 700 m (modal band 300-400 m) and only
2% is above 800 m. Ramp stops are hard-coded to **uniform** positions
(`pos = i/(len-1)`), so at gamma 1.0 the top four colours would share the top
**2.6%** of the surface. Solve for the gamma against the measured histogram
rather than guessing:

| gamma | s1 | s3 | s5 | s6 | s9 |
|---|---|---|---|---|---|
| 1.0 | 3.2% | 59% | 93% | 97.4% | 100% |
| **0.8** | **1.2%** | **41%** | **85%** | **95.5%** | **100%** |

**0.8** spreads s1..s5 over 1.2%..85% of the surface — five stops doing real
work on the plateau body. (Same failure mode as Maharashtra, different fix:
there the stops were re-coloured, here the *input* is remapped.)

### Exaggeration: anchor on rendered relief PIXELS

`displacement scale = elev_range·aspect/width = elev_range/height_km`, and what
actually reads is `scale × map_height_px`. Measured across delivered states that
lands at **~47-50 px of relief at BL_RES=3200** (Kerala 48.6, Meghalaya 47.1;
Maharashtra is lower at 33). Since the camera is width-fit,
`relief_px = 9.0 × EXAG / BL_MARGIN` here, so `BL_EXAG=9.1` at `BL_MARGIN=1.64`
gives ~50 px. That is **the highest exaggeration in the series** — correct, not
alarming, because this is the flattest state. Recompute EXAG whenever MARGIN
changes; they are coupled.

### Framing a tall state that must fill the frame

A tall state is height-limited, so `BL_MARGIN` behaves opposite to Maharashtra's
wide case. `BL_MARGIN=1.64` + `BL_SHIFTY=-0.072` fills **79% of frame height**
and leaves **255 px top** (logo corner) and **580 px bottom** (state-title band)
at 3200×4000. Measure, don't guess:
`magick <f> -fuzz 6% -trim -format "%wx%h%O" info:` — the trimmed bbox includes
the drop shadow, so the clean band is slightly larger than it reports.

### Voids: clamp, don't despike

elevatr returned a −664 m floor, but only **8 cells of 27.5M** sit below 0 m —
the Maharashtra 5×5-median despike is overkill at that count (Meghalaya case).
`DEM_CLAMP_LO=0.0001` floors it to **51 m**, a realistic Mahanadi-valley value,
recovering ~37% of the palette (range 1.929 → 1.214 km). Worth profiling
anyway: real terrain stays within **67 m** of its 5×5 median at the 99.999th
percentile against a void tail of 992 m, so the two populations separate cleanly.

**z10 does not truncate here** (unlike Maharashtra at z9): the DEM maximum lands
on **Bailadila at 1265 m** against a published ~1276 m, and the northern cluster
reads 1233 m against Gaurlata's published 1225 m.

### Overpass: rivers single-shot, reservoirs tiled

At 4.15° × 6.31° (26 deg²) the boundary and `waterway=river` both came back
whole from one request, but reservoirs returned
`Dispatcher_Client::request_read_and_idx::timeout` **on all three mirrors**, even
scoped to reservoir tags — so tile it (3 rows × 2 cols, mirror-cycling per tile,
one tile needed a retry). Two traps, both real here:
- A blanket `relation["natural"="water"]` clause is what makes the query
  unservable. Scope to `water=reservoir` + `landuse=reservoir`; every significant
  body in this state is a reservoir (Hasdeo Bango 117 km², Ravishankar/Gangrel
  74, Sikasaar 21, Maramsilli 19, Dudhawa 14).
- **A failed request still writes a file.** The first attempt produced a 26 MB
  *HTML error page* that sailed through a `>50000 bytes` check. Validate by
  **parsing**, and de-duplicate merged tiles by OSM `id` (tiles overlap).
- Rivers length-filtered to named systems ≥20 km + unnamed ways ≥5 km
  (1273 → 724 ways). Top systems land as expected: Mahanadi 387 km, Indravati
  350, Shivnath 342, Hasdeo 299, Mand 233, Arpa 161, Sabari 144.

### Labels

9 cities (most populous + Bastar/Surguja tourism gateways), 2 peaks, 3 water
features. **Durg was dropped**: it sits 7 km from Bhilai, which at ~4.5 render
px/km put the two names 2 px apart vertically with near-total horizontal
overlap. Predict this before rendering by projecting the label extents — but note
`features` only appear in `_labelpos_*.json` if `features/<slug>.csv` existed at
**render** time, so a features-vs-peaks collision cannot be predicted from an
older sidecar (Mainpat collided with "Hasdeo Bango Reservoir" and was dropped,
which also thinned an over-labelled NE corner). Removing a label needs only
`make_labels.py`; adding one needs a re-render.

## City / peak labels (separate 4K layer)

```bash
python3 blender/make_labels.py "uttarakhand" --width 3200
```

`relief.py` writes `output/<slug>_view.json` (the exact ortho projection) on every
render. `make_labels.py` reads it plus `cities/<slug>.csv` (name,lat,long,capital)
and `peaks/<slug>.csv` (name,lat,long,elev_m), projects each lat/long to the same
pixels the render used, and draws labels with **ImageMagick + Inter** and tightened
character spacing (negative `-kerning`), a small marker (dot = city, ▲ = peak) and a
soft white halo. Peaks alternate above/below (sorted by lon) to avoid collisions;
the capital gets a larger bold label + accent dot `#6E1616`.

Outputs (transparent, at `--width`, same 4:5 aspect as the render):
- `output/<slug>_labels.png` — the label layer to overlay on a 4K render
- `output/<slug>_final.png` — labels composited over the (upscaled) render, for preview

## Hero / physical-model variant

A dramatic 3/4 render that reads as a solid carved tile. Combine three knobs
(use `BL_SUFFIX` so it doesn't overwrite the clean top-down):

```bash
# one-time: cache the state's water bodies (OSM) for the lakes layer
Rscript blender/fetch_lakes.R "Uttarakhand"
Rscript blender/export_dem.R "Uttarakhand" 10        # -> _lakes.png + _outline.json

BL_SUFFIX=_hero BL_SLAB=1 BL_LAKES=1 BL_TILT=18 BL_RES=3200 BL_SAMPLES=200 \
  blender/render_state.sh "Uttarakhand"              # -> output/uttarakhand_hero.png
python3 blender/make_labels.py "uttarakhand" --variant hero   # -> uttarakhand_hero_final.png
```

- **Slab** — `export_dem.R` writes `<slug>_outline.json` (simplified state
  boundary); `relief.py` extrudes it into a prism (top at z≈0, walls down to
  `-BL_SLABTHICK`) under the terrain, and drops the grey card below it. Real
  thickness = the mappdout "carved model" edge.
- **Lakes** — `fetch_lakes.R` caches OSM `natural=water` (≥0.2 km²) to
  `<slug>_lakes.gpkg`; `export_dem.R` rasterizes it to `<slug>_lakes.png`;
  `relief.py` fills it blue (`BL_LAKEHEX`).
- **Tilt** — `BL_TILT` degrees orbits the camera south + looks at the origin
  (north stays up). `relief.py` writes `<slug>_labelpos<suffix>.json` — each
  city/peak projected through the *actual* camera via `world_to_camera_view`
  (sampling terrain height for elevation) — so `make_labels.py --variant hero`
  places labels correctly even on the tilted 3D surface.

## Palette

Green lowlands → sienna mountains → cream peaks, then white snow above the snow
line (sRGB, converted to linear in `relief.py`):
`#66A778 #8CB488 #B0BC93 #CFC196 #C69C5E #A6733E #BE8F58 #D5C8A2 #E7DDC5 #F3EDDE`
· snow `#F4F7F9` · river `#4E86A6`.

## Performance (Apple M4, Metal)

- 2000 px (4:5, 2000×2500) / 160 samples ≈ **30 s** (metaball clouds are cheap
  surfaces). 1400 px previews are a few seconds.
- Kernels are cached between runs (first run compiles ~1 min).

## Status & next (2026-07-08)

**Working end-to-end** with height / snow / rivers / clouds. Uttarakhand z10
renders north-up with granular carved relief, WNW sun (shadows rake L→R).

Tuning / TODO (best done interactively):
- **Grey card reads ~203–206, not exactly 215** — nudge ground/sun energy up, or
  composite a `BL_GROUND=0` cutout onto an exact `#d7d7d7` canvas.
- **Clouds** default is a soft mist band; dial `BL_CLOUDDEN` down for lighter /
  fewer, up for heavier. Placement is procedural (noise) — reseed by nudging the
  noise if a specific arrangement is wanted.
- **Granularity:** re-export **z11/z12** (`FORCE_EXPORT=1 … 12`) for SRTM-native
  ~30 m detail (big fetch) once the look is locked.
- **Framing/labels:** final IG output is a 4:5 canvas with title + city labels,
  composited in `magick` (lat/long→pixel on `meta` extent, like
  `render_state.R` step 7) — deferred until the look is locked.
