"""Build the district master map and the state map dissolved from it.

    maps/.venv/bin/python maps/build_district_maps.py build
    maps/.venv/bin/python maps/build_district_maps.py extract "Maharashtra"

`build` reads the district shapefile zip and writes
  data/boundaries/india-districts-<vintage>.geojson   (770 districts)
  data/boundaries/india-states-<vintage>.geojson      (36 states/UTs, dissolved from the above)
Both come out of one mapshaper run on one set of arcs, so every state border
is the district border, vertex for vertex. QC asserts that; any failure exits 1.

`extract` cuts one state's districts out of the master. Coordinates are copied,
not recomputed, so the extract still matches both files exactly.

Needs `npx mapshaper` (fetched on first run) and a themapsdaily-data checkout
next to this repo (district_validity.csv). Rules and caveats: maps/README.md.
"""

from __future__ import annotations

import collections
import csv
import json
import re
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

import pyogrio
from pyproj import Geod
from shapely import make_valid
from shapely.geometry import Point, Polygon, box, mapping, shape
from shapely.ops import unary_union
from shapely.strtree import STRtree

ROOT = Path(__file__).resolve().parents[1]
MAPS = ROOT / "data" / "boundaries"
SOURCE_ZIP = Path(__file__).with_name("sources") / "indist3_2022-06-27.zip"
SOURCE_LAYER = "indist3"
VINTAGE = "2022"  # AP's April 2022 reorganisation is in; file dated 2022-06-27
# Names/ids and the Kalapani claim line. Vendored copy of the site's map; same
# lines as themapsdaily-web india-2020.
STATE_REF = MAPS / "india-2021.geojson"
PRECISION = "0.00001"  # ~1 m
REGION_IDS = Path(__file__).with_name("region_ids.txt")  # Directus region_id snapshot
# Source of truth for dt_id / dt_nm / st_id by year (sibling repo).
DISTRICT_VALIDITY = ROOT.parent / "themapsdaily-data" / "regions" / "district" / "district_validity.csv"

# Name-derived dt_id -> district_validity dt_id for VINTAGE. Spelling variants
# (Banaskantha / Banas Kantha), official renames already in force by 2022
# (Allahabad -> Prayagraj 2018), and short forms of official names
# (Bhadradri -> Bhadradri Kothagudem).
DT_ID_FIX = {
    # Andhra Pradesh
    "anantapur-district": "ananthapuramu-district",
    "konaseema-district": "dr-b-r-ambedkar-konaseema-district",
    "ysr-district": "y-s-r-kadapa-district",
    # Arunachal Pradesh
    "lepa-rada-district": "leparada-district",
    "upper-dibang-valley-district": "dibang-valley-district",
    # Assam: the official name stayed Karbi Anglong after West Karbi Anglong split off
    "east-karbi-anglong-district": "karbi-anglong-district",
    # Bihar
    "east-champaran-district": "purbi-champaran-district",
    "west-champaran-district": "pashchim-champaran-district",
    # Chhattisgarh
    "baloda-bazar-bhatapara-district": "balodabazar-bhatapara-district",
    "balrampur-cg-district": "balrampur-ramanujganj-district",
    "bijapur-district": "bijapur-cg-district",
    "dantewada-district": "dakshin-bastar-dantewada-district",
    "kabirdham-district": "kabeerdham-district",
    "kanker-district": "uttar-bastar-kanker-district",
    # Gujarat
    "aravalli-district": "arvalli-district",
    "banaskantha-district": "banas-kantha-district",
    "chhota-udaipur-district": "chhotaudepur-district",
    "devbhoomi-dwarka-district": "devbhumi-dwarka-district",
    "mehsana-district": "mahesana-district",
    "panchmahal-district": "panchmahals-district",
    "sabarkantha-district": "sabar-kantha-district",
    # Jharkhand
    "hazaribagh-district": "hazaribag-district",
    "kodarma-district": "koderma-district",
    "saraikela-kharsawan-district": "seraikela-kharsawan-district",
    # Karnataka
    "bagalkot-district": "bagalkote-district",
    "ballary-district": "ballari-district",
    "shimoga-district": "shivamogga-district",
    # Mizoram, Odisha, Puducherry, Punjab, Tripura
    "saiha-district": "siaha-district",
    "jagatsinghapur-district": "jagatsinghpur-district",
    "pondicherry-district": "puducherry-district",
    "firozpur-district": "ferozepur-district",
    "sipahijala-district": "sepahijala-district",
    # Tamil Nadu
    "kanchipuram-district": "kancheepuram-district",
    "kanyakumari-district": "kanniyakumari-district",
    "nilgiris-district": "the-nilgiris-district",
    "sivagangai-district": "sivaganga-district",
    "tirupattur-district": "tirupathur-district",
    # Telangana
    "bhadradri-district": "bhadradri-kothagudem-district",
    "hanamkonda-district": "hanumakonda-district",
    "warangal-district": "warangal-2021-district",  # 2021 reuse of the name (former Warangal Rural); see district_validity
    "jagitial-district": "jagtial-district",
    "jogulamba-district": "jogulamba-gadwal-district",
    "kumuram-bheem-district": "kumuram-bheem-asifabad-district",
    "rangareddy-district": "ranga-reddy-district",
    "yadadri-district": "yadadri-bhuvanagiri-district",
    # Uttar Pradesh: Balrampur is unique once Chhattisgarh's is Balrampur-Ramanujganj
    "allahabad-district": "prayagraj-district",
    "badaun-district": "budaun-district",
    "balrampur-up-district": "balrampur-district",
    "barabanki-district": "bara-banki-district",
    "faizabad-district": "ayodhya-district",
    "sant-ravidas-nagar-district": "bhadohi-district",
    # Claimed territory: the source uses Pakistan's "AJK"; India's term is PoK
    "poonch-ajk-district": "poonch-pok-district",
}
# Source polygons that are not districts, folded into the district they belong
# to. Capital Complex Itanagar is administered separately but is part of Papum
# Pare in the official district list.
MERGE_INTO = {"capital-complex-itanagar-district": "papum-pare-district"}
# Districts created after the source was drawn (Chhattisgarh 2020 and Sep
# 2022), as OSM polygons; split_new_districts cuts them out of the source.
OSM_NEW = Path(__file__).with_name("sources") / "osm_new_districts.geojson"

# Source state labels -> our st_nm (the state map's join key).
STATE_NAMES = {
    "Jammu & Kashmir": "Jammu and Kashmir",
    "Orissa": "Odisha",
    "Andaman & Nicobar Islands": "Andaman and Nicobar Islands",
}
# The source leaves India's claimed Kalapani/Lipulekh tract out of Pithoragarh.
# Take it from the state map so the outer line stays the claimed boundary.
KALAPANI_BOX = (80.5, 29.9, 81.3, 30.5)
# A detached inland part smaller than this is a digitising speck, not an exclave.
SPECK_KM2 = 0.1

GEOD = Geod(ellps="WGS84")


def area_km2(geom) -> float:
    return abs(GEOD.geometry_area_perimeter(geom)[0]) / 1e6


def polygonal(geom):
    geom = make_valid(geom)
    if geom.geom_type == "GeometryCollection":
        geom = unary_union([g for g in geom.geoms if g.geom_type in ("Polygon", "MultiPolygon")])
    return geom


def slug(text: str) -> str:
    """ASCII kebab-case; accents are transliterated (Zünheboto -> zunheboto)."""
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", text.lower().replace("&", " and ")).strip("-")


def validity() -> dict[str, dict]:
    """district_validity rows in force in VINTAGE, by dt_id."""
    if not DISTRICT_VALIDITY.exists():
        sys.exit(f"missing {DISTRICT_VALIDITY} (themapsdaily-data checkout)")
    year = int(VINTAGE)
    with DISTRICT_VALIDITY.open() as fh:
        return {r["dt_id"]: r for r in csv.DictReader(fh)
                if r["status"] != "announced" and int(r["first_year"]) <= year <= int(r["last_year"])}


def normalise(tmp: Path) -> Path:
    """Source shapefile -> GeoJSON with our property schema, geometry repaired."""
    df = pyogrio.read_dataframe(f"/vsizip/{SOURCE_ZIP}/{SOURCE_LAYER}.shp")
    ref = json.loads(STATE_REF.read_text())["features"]
    states = {f["properties"]["st_nm"]: f["properties"] for f in ref}

    geoms = [polygonal(g) for g in df.geometry]
    india = unary_union(geoms)
    uk = polygonal(shape(next(f["geometry"] for f in ref if f["properties"]["st_nm"] == "Uttarakhand")))
    kalapani = uk.difference(india).intersection(box(*KALAPANI_BOX))
    pith = df.index[df["distname"] == "Pithoragarh"][0]
    geoms[pith] = unary_union([geoms[pith], kalapani])

    # distcode is a Census-style code, but districts created after 2011 carry
    # their parent's code or '#N/A'. Keep it only where it is unique.
    code_count = collections.Counter(df["distcode"])
    # The source tags cross-state homonyms "Bilaspur (HP)"; the tag is dropped
    # from the name and, for names that really repeat, moved into dt_id as the
    # state code (bilaspur-hp / bilaspur-cg). Every other dt_id is the bare
    # name slug. "Poonch (AJK)" keeps its tag (J&K has two Poonch rows) and
    # DT_ID_FIX renames it Poonch (PoK).
    names = [re.sub(r" \([A-Z]{2}\)$", "", n.strip()) for n in df["distname"]]
    slug_count = collections.Counter(slug(n) for n in names)
    valid = validity()
    feats, seen = [], set()
    for row, geom, src_nm in zip(df.itertuples(), geoms, names):
        st_nm = STATE_NAMES.get(row.statename, row.statename)
        st = states[st_nm]
        # Every district ends in `-district`, as every city region ends in
        # `-city` (pune-district / pune-city). Unconditional on purpose: a rule
        # keyed on which regions exist would rename a district's primary key the
        # day a matching city row is added.
        base = slug(src_nm) if slug_count[slug(src_nm)] == 1 else f"{slug(src_nm)}-{st['id'].lower()}"
        dt_id = DT_ID_FIX.get(f"{base}-district", f"{base}-district")
        dt_nm = valid[dt_id]["dt_nm"] if dt_id in valid else src_nm
        if dt_id in seen:
            sys.exit(f"duplicate dt_id {dt_id}")
        seen.add(dt_id)
        code = row.distcode if row.distcode not in ("#N/A", "") and code_count[row.distcode] == 1 else None
        feats.append({
            "type": "Feature",
            "properties": {"dt_nm": dt_nm, "dt_id": dt_id, "dt_code": code,
                           "claimed": dt_id in valid and valid[dt_id]["status"] == "claimed",
                           "st_nm": st_nm, "st_id": st["st_id"], "id": st["id"],
                           "src_nm": src_nm},  # for absorb_fragments; dropped in merge_districts
            "geometry": mapping(geom),
        })
    feats += split_new_districts(feats, valid, states)
    out = tmp / "normalised.geojson"
    out.write_text(json.dumps({"type": "FeatureCollection", "features": feats}))
    return out


def split_new_districts(feats: list, valid: dict, states: dict) -> list:
    """Cut districts the source predates out of the source districts.

    The OSM polygon supplies only the new internal lines: it is clipped to its
    state as the source draws it, so the state's outer line is untouched. Area
    is taken from whichever district of that state the polygon covers, not only
    the recorded parents, because the source's internal lines disagree with OSM
    by up to a few hundred km2 (its Janjgir-Champa is 4,526 km2 against Census
    2011's 3,852). Slivers this leaves are detached parts that absorb_fragments
    folds into a neighbour."""
    by_id = {s["st_id"]: (nm, s) for nm, s in states.items()}
    new = []
    for f in json.loads(OSM_NEW.read_text())["features"]:
        dt_id = f["properties"]["dt_id"]
        st_nm, st = by_id[valid[dt_id]["st_id"]]
        same = [d for d in feats if d["properties"]["st_nm"] == st_nm]
        cut = polygonal(shape(f["geometry"]).intersection(unary_union([shape(d["geometry"]) for d in same])))
        for d in same:
            d["geometry"] = mapping(polygonal(shape(d["geometry"]).difference(cut)))
        new.append({
            "type": "Feature",
            "properties": {"dt_nm": valid[dt_id]["dt_nm"], "dt_id": dt_id, "dt_code": None, "claimed": False,
                           "st_nm": st_nm, "st_id": st["st_id"], "id": st["id"], "src_nm": dt_id},
            "geometry": mapping(cut),
        })
        print(f"split {dt_id} {area_km2(cut):.0f} km2 out of {st_nm}")
    return new


def parts(geom) -> list:
    return list(getattr(geom, "geoms", [geom]))


def inland_fragments(geoms: list) -> list[tuple[int, object, list[int]]]:
    """(district index, detached part, touching district indexes) for every
    non-main part that borders another district. Islands touch nothing."""
    tree = STRtree(geoms)
    out = []
    for i, g in enumerate(geoms):
        ps = parts(g)
        if len(ps) < 2:
            continue
        main = max(ps, key=lambda p: p.area)
        for p in ps:
            if p is main:
                continue
            nb = [j for j in tree.query(p) if j != i and geoms[j].boundary.intersection(p.boundary).length > 0]
            if nb:
                out.append((i, p, nb))
    return out


def absorb_fragments(path: Path, tmp: Path) -> Path:
    """Fold bogus detached bits into the neighbour they share most border with.

    Bogus = smaller than SPECK_KM2 (source digitising specks), or absent from
    the raw source as a separate part (created by make_valid/-clean, e.g. 1.6 km2
    of Kamrup inside Ri-Bhoi from a figure-eight ring). Real exclaves -- Pavagada,
    Phagwara, Puducherry's enclaves, Gujarat villages inside DNH -- were separate
    parts in the source and are kept.
    """
    data = json.loads(path.read_text())
    geoms = [shape(f["geometry"]) for f in data["features"]]
    src = pyogrio.read_dataframe(f"/vsizip/{SOURCE_ZIP}/{SOURCE_LAYER}.shp")
    raw_parts: dict[str, list] = collections.defaultdict(list)
    for name, g in zip(src["distname"], src.geometry):
        ps = parts(g)
        if len(ps) > 1:
            raw_parts[re.sub(r" \([A-Z]{2}\)$", "", name.strip())] += [make_valid(q) for q in ps]
    moved = []
    for i, p, nb in inland_fragments(geoms):
        name = data["features"][i]["properties"]["src_nm"]
        in_source = any(q.intersection(p).area > 0.5 * p.area for q in raw_parts.get(name, []))
        if in_source and area_km2(p) >= SPECK_KM2:
            continue
        j = max(nb, key=lambda k: geoms[k].boundary.intersection(p.boundary).length)
        geoms[i] = polygonal(geoms[i].difference(p))
        geoms[j] = polygonal(unary_union([geoms[j], p]))
        moved.append(f"{area_km2(p):.3f} km2 {data['features'][i]['properties']['dt_id']} -> "
                     f"{data['features'][j]['properties']['dt_id']}")
    for f, g in zip(data["features"], geoms):
        f["geometry"] = mapping(g)
    print("absorbed fragments:", *moved, sep="\n  ")
    out = tmp / "absorbed.geojson"
    out.write_text(json.dumps(data))
    return out


def merge_districts(path: Path, tmp: Path) -> Path:
    """Fold MERGE_INTO polygons into their district and drop src_nm. Runs on
    cleaned output, so the two share arcs and the union leaves no seam."""
    data = json.loads(path.read_text())
    feats = {f["properties"]["dt_id"]: f for f in data["features"]}
    for src, dst in MERGE_INTO.items():
        g = polygonal(unary_union([shape(feats[dst]["geometry"]), shape(feats.pop(src)["geometry"])]))
        feats[dst]["geometry"] = mapping(g)
        print(f"merged {src} -> {dst}")
    for f in feats.values():
        f["properties"].pop("src_nm")
    data["features"] = list(feats.values())
    out = tmp / "merged.geojson"
    out.write_text(json.dumps(data))
    return out


def despike(ring: list) -> list:
    """Drop zero-area A-B-A spikes; mapshaper's rounding can leave one behind."""
    pts = ring[:-1]
    i = 0
    while i < len(pts) and len(pts) > 3:
        n = len(pts)
        if pts[i] == pts[(i + 2) % n]:
            drop = {(i + 1) % n, (i + 2) % n}
            pts = [p for k, p in enumerate(pts) if k not in drop]
            i = max(i - 2, 0)
        else:
            i += 1
    return pts + [pts[0]]


def clockwise(ring: list) -> bool:
    return sum((b[0] - a[0]) * (b[1] + a[1]) for a, b in zip(ring, ring[1:])) > 0


def finish(path: Path, name: str) -> None:
    """Despike, wind like the other india-*.geojson files (exterior clockwise,
    holes counter-clockwise: d3-geo's convention -- the RFC 7946 order that
    mapshaper writes renders each district as the globe minus the district),
    and add their name/CRS header. Rings are reversed, never recomputed, so
    coordinates stay shared between the two outputs."""
    data = json.loads(path.read_text())
    for f in data["features"]:
        g = f["geometry"]
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        for p in polys:
            p[:] = [despike(r) for r in p]
            p[:] = [r if clockwise(r) == (k == 0) else r[::-1] for k, r in enumerate(p)]
    data = {"type": "FeatureCollection", "name": name,
            "crs": {"type": "name", "properties": {"name": "urn:ogc:def:crs:OGC:1.3:CRS84"}},
            "features": data["features"]}
    path.write_text(json.dumps(data, separators=(",", ":")))


def segments(geom: dict) -> set:
    polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
    return {frozenset((tuple(a), tuple(b))) for p in polys for r in p for a, b in zip(r, r[1:])}


def qc(dist_path: Path, state_path: Path) -> list[str]:
    """Empty list = ship it."""
    D = json.loads(dist_path.read_text())["features"]
    T = json.loads(state_path.read_text())["features"]
    dg = [shape(f["geometry"]) for f in D]
    tg = [shape(f["geometry"]) for f in T]
    problems = []
    bad = [f["properties"]["dt_id"] for f, g in zip(D, dg) if not g.is_valid or g.is_empty]
    bad += [f["properties"]["st_nm"] for f, g in zip(T, tg) if not g.is_valid or g.is_empty]
    if bad:
        problems.append(f"invalid/empty: {bad}")
    union = unary_union(dg)
    overlap = sum(area_km2(g) for g in dg) - area_km2(union)
    if overlap > 0.01:
        problems.append(f"district overlap {overlap:.3f} km2")
    holes = [area_km2(Polygon(r)) for p in getattr(union, "geoms", [union]) for r in p.interiors]
    if holes:
        problems.append(f"{len(holes)} gaps between districts ({sum(holes):.2f} km2)")
    loose = set().union(*(segments(f["geometry"]) for f in T)) - set().union(*(segments(f["geometry"]) for f in D))
    if loose:
        problems.append(f"{len(loose)} state border segments are not district border segments")
    specks = [f"{D[i]['properties']['dt_id']} {area_km2(p):.4f}" for i, p, _ in inland_fragments(dg)
              if area_km2(p) < SPECK_KM2]
    if specks:
        problems.append(f"detached inland specks < {SPECK_KM2} km2: {specks}")
    for f in D + T:
        g = f["geometry"]
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        if any(clockwise(r) != (k == 0) for p in polys for k, r in enumerate(p)):
            problems.append(f"winding not d3 (exterior cw): {f['properties'].get('dt_id') or f['properties']['st_nm']}")
            break
    if len({f["properties"]["dt_id"] for f in D}) != len(D):
        problems.append("duplicate dt_id")
    # Districts join to states on (st_nm, st_id, id); st_id is Directus region_id.
    key = lambda f: (f["properties"]["st_nm"], f["properties"]["st_id"], f["properties"]["id"])
    ref = {key(f) for f in json.loads(STATE_REF.read_text())["features"]}
    if {key(f) for f in T} != ref:
        problems.append("state keys differ from the state map")
    if orphans := {key(f) for f in D} - {key(f) for f in T}:
        problems.append(f"district state keys missing from the state file: {orphans}")
    if bad_pk := [f["properties"]["dt_id"] for f in D if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", f["properties"]["dt_id"])]:
        problems.append(f"dt_id not ASCII kebab-case: {bad_pk[:5]}")
    region_ids = {l.strip() for l in REGION_IDS.read_text().splitlines() if l.strip() and not l.startswith("#")}
    if clash := [f["properties"]["dt_id"] for f in D
                 if not f["properties"]["dt_id"].endswith("-district") or f["properties"]["dt_id"] in region_ids]:
        problems.append(f"dt_id missing -district or equal to a region_id: {clash}")
    # Keys join to district_validity for VINTAGE; `claimed` mirrors its status.
    valid = validity()
    if unknown := [f["properties"]["dt_id"] for f in D
                   if f["properties"]["dt_id"] not in valid]:
        problems.append(f"dt_id not in district_validity {VINTAGE}: {unknown}")
    if wrong_st := [f["properties"]["dt_id"] for f in D if f["properties"]["dt_id"] in valid
                    and valid[f["properties"]["dt_id"]]["st_id"] != f["properties"]["st_id"]]:
        problems.append(f"st_id differs from district_validity: {wrong_st}")
    if bad_flag := [f["properties"]["dt_id"] for f in D if f["properties"]["dt_id"] in valid
                    and f["properties"]["claimed"] != (valid[f["properties"]["dt_id"]]["status"] == "claimed")]:
        problems.append(f"claimed flag differs from district_validity status: {bad_flag}")
    missing = sorted(set(valid) - {f["properties"]["dt_id"] for f in D})
    print(f"in district_validity {VINTAGE} but not in the source ({len(missing)}):", *missing, sep="\n  ")
    # claimed-boundary spot checks: (lon, lat) -> st_nm
    for (lon, lat), st in {(73.47, 34.37): "Jammu and Kashmir", (74.31, 35.92): "Ladakh",
                           (79.5, 35.2): "Ladakh", (76.3, 36.1): "Ladakh",
                           (91.86, 27.59): "Arunachal Pradesh", (80.99, 30.21): "Uttarakhand",
                           (68.35, 23.70): "Gujarat"}.items():
        hit = [f["properties"]["st_nm"] for f, g in zip(T, tg) if g.contains(Point(lon, lat))]
        if hit != [st]:
            problems.append(f"({lon},{lat}) expected {st}, got {hit}")
    return problems


def build() -> int:
    dist_out = MAPS / f"india-districts-{VINTAGE}.geojson"
    state_out = MAPS / f"india-states-{VINTAGE}.geojson"
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        src = normalise(tmp)
        d_tmp, s_tmp = tmp / dist_out.name, tmp / state_out.name
        # Pass 1: -clean closes the source's 4,099 gaps/slivers on shared arcs.
        cleaned = tmp / "cleaned.geojson"
        subprocess.run(["npx", "-y", "mapshaper", "-i", str(src), "-clean", "gap-fill-area=500km2",
                        "-o", str(cleaned), "format=geojson"], check=True)
        absorbed = absorb_fragments(cleaned, tmp)
        absorbed = merge_districts(absorbed, tmp)
        # Pass 2: rebuild arcs after the moves; the dissolve reuses those arcs,
        # which is what makes the state and district borders identical.
        subprocess.run([
            "npx", "-y", "mapshaper", "-i", str(absorbed), "name=districts",
            "-clean", "gap-fill-area=500km2",
            "-o", str(d_tmp), "format=geojson", f"precision={PRECISION}",
            "-dissolve", "st_nm", "copy-fields=st_id,id", "+", "name=states",
            "-target", "states", "-o", str(s_tmp), "format=geojson", f"precision={PRECISION}",
        ], check=True)
        finish(d_tmp, dist_out.stem)
        finish(s_tmp, state_out.stem)
        problems = qc(d_tmp, s_tmp)
        if problems:
            print("QC FAILED:", *problems, sep="\n  ")
            return 1
        dist_out.write_bytes(d_tmp.read_bytes())
        state_out.write_bytes(s_tmp.read_bytes())
    print(f"QC ok -> {dist_out.name}, {state_out.name}")
    return 0


def extract(st_nm: str) -> int:
    master = json.loads((MAPS / f"india-districts-{VINTAGE}.geojson").read_text())
    feats = [f for f in master["features"] if f["properties"]["st_nm"] == st_nm]
    if not feats:
        print(f"no districts for st_nm={st_nm!r}")
        return 1
    st_id = feats[0]["properties"]["st_id"]
    out = MAPS / "districts" / f"{st_id}-districts-{VINTAGE}.geojson"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({**master, "name": out.stem, "features": feats}, separators=(",", ":")))
    print(f"{len(feats)} districts -> {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "build":
        sys.exit(build())
    if len(sys.argv) >= 3 and sys.argv[1] == "extract":
        sys.exit(extract(sys.argv[2]))
    print(__doc__)
    sys.exit(2)
