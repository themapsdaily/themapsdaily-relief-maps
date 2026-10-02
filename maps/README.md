# District master map

Built here, not in `themapsdaily-web`, so it is isolated from the site
redesign. The state-level basemaps the site serves (`india-<year>.geojson`) and
the year rule stay documented in `themapsdaily-web/docs/INDIA_MAPS.md`; references
below to "the state series" or "§1" mean that doc.


Goal: one base layer. District and state borders match vertex for vertex, and
any state map or single-state district map is cut from the master, never drawn
separately.

| File | What |
|---|---|
| `data/boundaries/india-districts-2022.geojson` | 770 districts (all of 2022's + 5 claimed-territory areas), 2.1 MB. The master |
| `data/boundaries/india-states-2022.geojson` | 36 states/UTs dissolved from it, 0.5 MB |
| `maps/build_district_maps.py` | `build` (rebuild both + QC, exit 1 on failure), `extract "<st_nm>"` (one state's districts → `data/boundaries/districts/`) |
| `maps/sources/indist3_2022-06-27.zip` | Source: `indist3` shapefile, QGIS export dated 2022-06-27, WGS84 |
| `maps/sources/osm_new_districts.geojson` | OSM polygons for districts the shapefile predates (ODbL) |
| `maps/region_ids.txt` | Directus `region_id` snapshot; no `dt_id` may equal one |

Run from the repo root:

```bash
python3 -m venv maps/.venv && maps/.venv/bin/pip install -r maps/requirements.txt   # once
maps/.venv/bin/python maps/build_district_maps.py build
maps/.venv/bin/python maps/build_district_maps.py extract "Maharashtra"
```

Also needs `npx mapshaper` (fetched on first run) and a `themapsdaily-data`
checkout next to this repo: the build reads its `district_validity.csv`. The
state reference (names, ids, Kalapani claim line) is the vendored
`data/boundaries/india-2021.geojson`, same lines as the site's `india-2020`.

**Keys:**

| Field | Role |
|---|---|
| `dt_id` | **Primary key.** `<district slug>-district`, always, as every Directus city is `<name>-city` (`pune-district` / `pune-city`, `mumbai-city-district` = the island half of `mumbai-city`). ASCII kebab-case, accents transliterated (`zunheboto-district`). No state in it, except names two states share, which take the state code before the suffix, as in `district_validity`: `bilaspur-hp-district`/`-cg-`, `hamirpur-hp`/`-up`, `aurangabad-br`/`-mh`, `pratapgarh-rj`/`-up`, `bijapur-cg`/`-ka`; and `poonch-pok-district` vs `poonch-district` (both J&K). The suffix is unconditional so a new region row can never rename a district's key. QC also checks no `dt_id` equals a `region_id` in `maps/region_ids.txt` |
| `st_id` | **Foreign key → Directus `region.region_id`** (all 36 verified 2026-10-01). Same value as the state file's `st_id` |
| `st_nm`, `id` | Carried from the state file for convenience (`id` = `region_code`); join on `st_id` |
| `dt_nm` | Display name from the source, suffixes like "(HP)" dropped |
| `claimed` | `true` for the 5 claimed-territory features (no data; draw as no-data) |
| `dt_code` | Source Census-style code; null for 167 rows where it was `#N/A` or duplicated (post-2011 districts inherited the parent's code). Not a key |

QC fails the build if a `dt_id` repeats or isn't ASCII kebab-case, or if any
district's state fields don't match a state-file feature.

`dt_id` is derived from the name, so a **renamed district gets a new key**, the
same way `orissa` → `odisha` is a new `region_id`. This 2022 vintage already has
names that changed in 2023 (Aurangabad → Chhatrapati Sambhajinagar, Osmanabad →
Dharashiv).

**Keys follow `themapsdaily-data/sources/_shared/districts/district_validity.csv`**
(2011–2026, Census 2011 + dated events, checked against IGOD), the source of
truth for `dt_id`, names and years. The build reads it from the sibling checkout
and fails without it:
- `DT_ID_FIX` maps the shapefile's name-derived id to the validity `dt_id` for
  2022: spelling variants (Banaskantha → `banas-kantha-district`), renames in
  force by 2022 (Allahabad → `prayagraj-district`, Faizabad → `ayodhya-district`),
  short names (Bhadradri → `bhadradri-kothagudem-district`). 51 entries.
- `dt_nm` is the validity file's official name.
- `MERGE_INTO`: Capital Complex Itanagar is not a district; it is folded into
  `papum-pare-district`.
- QC fails if a `dt_id` is not valid in 2022, or its `st_id` or `claimed`
  flag disagrees with the validity row.
- **Claimed territory** stays as separate features with `claimed: true`:
  Muzaffarabad, Mirpur, Poonch (PoK) (J&K), Gilgit-Baltistan, Aksai Chin (Ladakh;
  J&K before 2019). They are `status=claimed` rows in `district_validity`, so
  every map key is a real key, but no data is published for them: choropleths
  should draw them as no-data and never fold them into Leh or Poonch. India's
  official map splits Gilgit-Baltistan into four districts and puts Aksai Chin in
  Leh; the source has neither split, so they stay one feature each.
- **Districts the source predates** are cut in from OSM
  (`maps/sources/osm_new_districts.geojson`, fetched 2026-10-02, ODbL):
  Gaurela-Pendra-Marwahi (Feb 2020) and Chhattisgarh's five of Sep 2022
  (Khairagarh-Chhuikhadan-Gandai, Manendragarh-Chirmiri-Bharatpur,
  Mohla-Manpur-Ambagarh Chouki, Sakti, Sarangarh-Bilaigarh). Each OSM polygon is
  clipped to the state as the source draws it, so only the new internal lines
  come from OSM; it takes area from whichever districts it covers (the source's
  Janjgir-Champa/Baloda Bazar line is off by ~400 km² against OSM). Slivers go
  through `absorb_fragments`. 770 districts; QC prints any 2022 district still
  missing (now none).

**What the build fixes in the source:**
- 7 invalid geometries; 1,153 km² of overlaps and 2,035 gaps (4,099 slivers),
  closed by `mapshaper -clean` on shared arcs. A zero-area spike on the
  Warangal / Jayashankar Bhupalpally line is removed afterwards.
- State labels normalised to our `st_nm`: Orissa → Odisha, "Jammu & Kashmir",
  "Andaman & Nicobar Islands"; DNHDD's two source state codes (25, 26) become one
  state.
- Cross-state suffixes dropped ("Bilaspur (HP)" → "Bilaspur"). "Poonch (AJK)"
  kept as a separate row (J&K has two Poonch rows) and renamed Poonch (PoK).
- **Kalapani/Lipulekh** (~107 km²) is missing from the source's Pithoragarh. It is
  added from `india-2020` so the outer line stays India's claimed boundary.
- **Fragments:** 9 detached inland bits are folded into the neighbour they share
  most border with. 5 were created by the geometry repair, including 1.6 km² of
  Kamrup inside Ri-Bhoi left by a figure-eight ring (moves that area from Assam to
  Meghalaya). 4 are source specks under 0.1 km². The 29 real exclaves
  (Pavagada/Tumakuru, Phagwara/Kapurthala, Chittorgarh, Puducherry's enclaves,
  Gujarat villages inside DNH, Mahe's Naluthara, …) are kept.
- **Winding:** written exterior-clockwise like the other `india-*.geojson` files.
  mapshaper writes RFC 7946 order (counter-clockwise), which d3-geo
  (react-simple-maps) reads as "the globe minus the district".

**Claimed boundary in the source:** PoK as J&K districts (Muzaffarabad, Mirpur,
Poonch (AJK)); Gilgit-Baltistan and Aksai Chin as pseudo-districts of Ladakh;
Shaksgam in Gilgit-Baltistan; Tawang, Sir Creek inside.

**QC (in `build`):** every geometry valid; zero overlap; zero gaps; every state
border segment is a district border segment; no detached inland speck under
0.1 km²; d3 winding; `dt_id` unique; state names equal `india-2020`'s;
claimed-boundary spot points land in the right state. Checked independently on
2026-10-01 with d3-geo `geoArea` (0 inverted features) and a render.

**Not yet reconciled with the state series (§1):**
- It is a different source. Against `india-2020` the state outlines differ by
  0.4–2% of area for the big states, up to 7% for J&K (the J&K/Ladakh line), and
  the outer line by 18,800 km² in total (Sundarbans and Kutch coastlines, the
  northern Gilgit-Baltistan line, Mumbai harbour).
- Vintage mid-2022 (AP's April 2022 26 districts are in). District changes since
  then are not: check before using it for current district data.
- Lakshadweep (184 km²), Puducherry and DNHDD are coarse, like the state map.

**Next steps toward one lineage:**
1. Decide whether `india-states-2022` replaces `india-2020`/`india-2021` as the
   current state map (`map_geojson` 2020+, fallback, quiz, Believe, relief-maps).
2. Rebuild the historical state series (§1) as unions of master districts by
   year. Every change since 1956 follows district lines except 1966 Punjab → HP,
   which moved parts of Shimla/Solan (sub-district). That piece needs a
   sub-district cut, or the old line kept for that one boundary.
3. Each new district vintage: new source → new `india-districts-<year>` →
   re-derive states → QC.
