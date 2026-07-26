#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Export a state's clipped DEM as a Blender-ready heightmap + mask + metadata.
#   Rscript blender/export_dem.R "<State>" [zoom]
# Writes to output/:
#   <slug>_height.png  16-bit grayscale, elevation normalized 0..1 (north up)
#   <slug>_mask.png     8-bit, white = inside state, black = outside
#   <slug>_meta.json    extent, elevation range, true geographic aspect, etc.
# Run from the relief-maps/ dir. Reuses the cached DEM GeoTIFF if present.
# ---------------------------------------------------------------------------
suppressPackageStartupMessages({
  library(sf); library(raster); library(elevatr); library(png); library(jsonlite)
})

args  <- commandArgs(trailingOnly = TRUE)
state <- if (length(args) >= 1) args[[1]]            else "Uttarakhand"
zoom  <- if (length(args) >= 2) as.integer(args[[2]]) else 10L
boundary <- Sys.getenv("RELIEF_BOUNDARY", "data/boundaries/india-2021.geojson")
slug   <- gsub("\\s+", "_", tolower(state))
outdir <- file.path("output", slug)                 # per-state subfolder
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
message(sprintf("export %s z%d", state, zoom))

## COASTAL SEA MODE (opt-in, env-gated; default off so landlocked states are
## untouched). A coastal state (Goa) needs the Arabian Sea rendered as a blue
## band hugging the shore that fades to the grey card. To do that the render
## grid must extend WEST of the coastline (the state bbox stops AT the coast),
## so in sea mode we fetch the DEM over an expanded bbox (unclipped), keep the
## displaced terrain masked to the state polygon, and emit an extra <slug>_sea.png
## = a 0..1 coast-proximity field over the ocean (1 at the shore -> 0 offshore).
##   SEA_WEST     deg to extend the bbox westward into the sea (0 = off)
##   SEA_NS       deg to also extend north+south (wrap the sea past the tips)
##   SEA_LEVEL    elevation (m) at/below which an outside-state cell counts as sea
##   SEA_FADE_KM  offshore distance over which the blue fades to grey
sea_west <- as.numeric(Sys.getenv("SEA_WEST", "0"))
sea_ns   <- as.numeric(Sys.getenv("SEA_NS", "0"))
sea_lvl  <- as.numeric(Sys.getenv("SEA_LEVEL", "5"))
sea_fade <- as.numeric(Sys.getenv("SEA_FADE_KM", "18"))
sea_mode <- sea_west > 0
demfile <- file.path(outdir, sprintf("%s_dem_z%d%s.tif", slug, zoom,
                                     if (sea_mode) "_sea" else ""))

## boundary + DEM (reuse cache) ---------------------------------------------
## BOUNDARY_GPKG = optional high-detail state polygon (already a single state),
## used instead of the national geojson. india-2021.geojson is heavily
## simplified (Goa = 88 vertices over a 388 km perimeter = a point every 4.4 km,
## which renders as a visibly "squary" coastline). A small state can afford the
## real OSM admin boundary (Goa relation 11251493 = 7671 vertices).
bnd_gpkg <- Sys.getenv("BOUNDARY_GPKG", "")
if (nzchar(bnd_gpkg) && file.exists(bnd_gpkg)) {
  sel <- sf::st_read(bnd_gpkg, quiet = TRUE)
  message(sprintf("boundary override: %s (%d vertices)", bnd_gpkg,
                  nrow(sf::st_coordinates(sel))))
} else {
  sel <- sf::st_read(boundary, quiet = TRUE); sel <- sel[sel$st_nm == state, ]
}
if (nrow(sel) == 0) stop("state not found: ", state)
sel <- sf::st_make_valid(sf::st_transform(sel, 4326))
if (file.exists(demfile)) {
  message("cached DEM: ", demfile); dem <- raster::raster(demfile)
} else if (sea_mode) {
  bb  <- sf::st_bbox(sel)
  ex  <- sf::st_bbox(c(xmin = bb[["xmin"]] - sea_west, ymin = bb[["ymin"]] - sea_ns,
                       xmax = bb[["xmax"]],             ymax = bb[["ymax"]] + sea_ns),
                     crs = 4326)
  expoly <- sf::st_sf(id = 1, geometry = sf::st_as_sfc(ex))   # sf (not bare sfc) for elevatr
  message(sprintf("sea mode: bbox +%.2f W /+%.2f NS -> [%.3f,%.3f]x[%.3f,%.3f]",
                  sea_west, sea_ns, ex[["xmin"]], ex[["xmax"]], ex[["ymin"]], ex[["ymax"]]))
  dem <- elevatr::get_elev_raster(locations = expoly, z = zoom, clip = "bbox")
  raster::writeRaster(dem, demfile, overwrite = TRUE)
} else {
  dem <- elevatr::get_elev_raster(locations = sel, z = zoom, clip = "locations")
  raster::writeRaster(dem, demfile, overwrite = TRUE)
}

## raster matrix is already north-up (row 1 = north, col 1 = west) ----------
m  <- raster::as.matrix(dem)
## in sea mode the DEM is unclipped, so "inside the state" is the rasterized
## polygon (not merely non-NA). This drives both the mask and the elev range.
if (sea_mode) {
  suppressPackageStartupMessages(library(terra))
  rst <- terra::rasterize(terra::vect(sel), terra::rast(dem), field = 1, background = NA)
  instate <- !is.na(terra::as.matrix(rst, wide = TRUE))
  valid <- instate                                   # normalize + mask to the state only
  m[is.na(m)] <- 0                                    # ocean NoData -> 0 m (sea level)
} else {
  valid <- !is.na(m)
}
## robust clamp of DEM void/spike outliers before normalizing. Terrain tiles
## occasionally carry a few void pixels (deep negative) or spikes that would
## otherwise stretch the 0..1 range and wash out the palette (e.g. a -1825 m
## void floor on a plateau state pushes real lowlands into mid-palette ochre).
## Opt-in via env percentiles; default 0 = off, so already-tuned states are
## unchanged. Clamp the tails ASYMMETRICALLY -- a genuine needle peak (Parasnath
## 1365 m over a <1200 m plateau) must not be flattened, so usually LO only.
##   DEM_CLAMP_LO  clamp the low  tail up   to this quantile      (e.g. 0.0005)
##   DEM_CLAMP_HI  clamp the high tail down to 1-this quantile    (e.g. 0.0005)
clo <- as.numeric(Sys.getenv("DEM_CLAMP_LO", "0"))
chi <- as.numeric(Sys.getenv("DEM_CLAMP_HI", "0"))
if (clo > 0) { qlo <- as.numeric(quantile(m[valid], clo));     m[valid & m < qlo] <- qlo
               message(sprintf("DEM_CLAMP_LO %.4f -> floor %.0f m", clo, qlo)) }
if (chi > 0) { qhi <- as.numeric(quantile(m[valid], 1 - chi)); m[valid & m > qhi] <- qhi
               message(sprintf("DEM_CLAMP_HI %.4f -> ceil  %.0f m", chi, qhi)) }
mn <- min(m[valid]); mx <- max(m[valid])
h  <- (m - mn) / (mx - mn); h[!valid] <- 0        # normalized elevation, holes -> 0
h[h < 0] <- 0; h[h > 1] <- 1                      # clamp out-of-state neighbours to the state range

## fill tiny interior NoData so displacement has no pits (neighbour mean) ----
## Skipped in sea mode: there `valid` is the whole state polygon and growing it
## would bleed terrain into the ocean/neighbour states.
if (!sea_mode && any(!valid)) {
  for (p in 1:6) {
    if (all(valid)) break
    nr <- nrow(h); nc <- ncol(h); acc <- matrix(0, nr, nc); cnt <- matrix(0L, nr, nc)
    for (di in -1:1) for (dj in -1:1) {
      if (di == 0 && dj == 0) next
      si <- pmin(pmax((1:nr) + di, 1), nr); sj <- pmin(pmax((1:nc) + dj, 1), nc)
      sub <- h[si, sj]; sv <- valid[si, sj]
      acc <- acc + ifelse(sv, sub, 0); cnt <- cnt + sv
    }
    fillable <- !valid & cnt >= 6
    h[fillable] <- (acc / pmax(cnt, 1L))[fillable]
    valid[fillable] <- TRUE
  }
}

## write heightmap + mask ----------------------------------------------------
## Displacement source: float32 GeoTIFF (no quantization -> no terracing in
## Blender displacement). Blender reads it natively via OpenImageIO. Also emit
## an 8-bit PNG preview for quick visual sanity.
hr <- raster::setValues(dem, as.vector(t(h)))       # north-up matrix -> raster grid
raster::writeRaster(hr, file.path(outdir, paste0(slug, "_height.tif")),
                    datatype = "FLT4S", overwrite = TRUE)
png::writePNG(h, file.path(outdir, paste0(slug, "_height.png")))   # 8-bit preview
## mask uses the hole-filled `valid` grid so filled interior pits stay opaque
png::writePNG(valid * 1, file.path(outdir, paste0(slug, "_mask.png")))

## sea band (coastal mode): ocean = outside-state cells at/below sea level; the
## factor is 1 at the shoreline and smoothsteps to 0 by SEA_FADE_KM offshore, so
## relief.py can paint blue near the coast that dissolves into the grey card.
## terra::distance() on a lon/lat raster is GEODESIC and scales terribly -- on a
## z12 grid (5127x5961) it never finishes. Distance fields here are smooth and
## only feed a soft fade / a threshold, so compute them on a downsampled grid and
## resample back: identical result, seconds instead of hours.
fast_dist <- function(r, target_max = 1200) {
  f <- max(1, ceiling(max(dim(r)[1:2]) / target_max))
  if (f > 1) {
    ra <- terra::aggregate(r, fact = f, fun = "max", na.rm = TRUE)
    terra::resample(terra::distance(ra), r, method = "bilinear")
  } else terra::distance(r)
}

if (sea_mode) {
  ocean <- (!instate) & (m <= sea_lvl)
  ocean[is.na(ocean)] <- FALSE
  ## keep only ocean connected to the western frame edge -> drops inland void
  ## specks wrongly flagged as sea (SE corner) and isolated offshore noise,
  ## while keeping the real Arabian Sea + its estuary mouths.
  ocr <- terra::rast(dem); terra::values(ocr) <- as.vector(t(ocean * 1)); ocr[ocr == 0] <- NA
  pg  <- terra::as.matrix(terra::patches(ocr, directions = 8, zeroAsNA = TRUE), wide = TRUE)
  westids <- unique(pg[, 1]); westids <- westids[!is.na(westids)]
  ocean <- !is.na(pg) & matrix(pg %in% westids, nrow = nrow(pg))
  ## coast-proximity profile. SEA_BAND_KM > 0 = a NARROW light-blue BORDER band
  ## hugging the shoreline (not a big offshore gradient): solid plateau out to
  ## 55% of the width -- which also hides the slab's side wall -- then a
  ## smoothstep to nothing. Falls back to the old wide SEA_FADE_KM gradient.
  band_km <- as.numeric(Sys.getenv("SEA_BAND_KM", "0"))
  dmat  <- terra::as.matrix(fast_dist(rst), wide = TRUE)          # m to nearest land cell
  if (band_km > 0) {
    tt   <- dmat / (band_km * 1000); tt[tt > 1] <- 1; tt[tt < 0] <- 0
    fade <- ifelse(tt <= 0.55, 1, 1 - (tt - 0.55) / 0.45)
    fade[fade < 0] <- 0; fade[fade > 1] <- 1        # clamp IN PLACE (pmin/pmax drop dims)
    fade <- fade * fade * (3 - 2 * fade)
  } else {
    fade  <- pmax(0, pmin(1, 1 - dmat / (sea_fade * 1000)))
    fade  <- fade * fade * (3 - 2 * fade)                        # smoothstep falloff
  }
  seaf  <- ifelse(ocean, fade, 0); seaf[is.na(seaf)] <- 0
  ## smooth the band so it reads as clean water, not a speckled coastline
  sfr   <- terra::rast(dem); terra::values(sfr) <- as.vector(t(seaf))
  sfr   <- terra::focal(sfr, w = 7, fun = mean, na.rm = TRUE)
  seaf  <- terra::as.matrix(sfr, wide = TRUE); seaf[is.na(seaf)] <- 0
  seaf[instate] <- 0                                             # keep land pure (no blue bleed)
  seaf[seaf < 0.012] <- 0; seaf[seaf < 0] <- 0; seaf[seaf > 1] <- 1   # clamp in place (keep matrix)
  png::writePNG(seaf, file.path(outdir, paste0(slug, "_sea.png")))
  message(sprintf("wrote %s_sea.png (%d ocean px, %s)", slug, sum(ocean, na.rm = TRUE),
                  if (band_km > 0) sprintf("band %.1f km", band_km) else sprintf("fade %.0f km", sea_fade)))

  ## HARD ocean mask (0/1), the full water body -- not the narrow blue band.
  ## The band only reaches SEA_BAND_KM offshore, so anything wider (bays, estuary
  ## mouths, the open sea) fell back to the transparent grey card, which CATCHES
  ## the terrain's cast shadow -> grey smudges floating on the water west of the
  ## coast. relief.py (BL_OCEAN=1) uses this to lay an opaque, shadeless sheet
  ## over the whole ocean instead: same grey as the card where there is no band,
  ## so it is invisible, but nothing can cast a shadow onto it.
  oceanm <- ocean * 1; oceanm[is.na(oceanm)] <- 0
  png::writePNG(oceanm, file.path(outdir, paste0(slug, "_ocean.png")))
  message(sprintf("wrote %s_ocean.png (%d px, hard water mask)", slug, sum(ocean, na.rm = TRUE)))

  ## BEACH: the sandy shore strip. Goa's beaches are literally at sea level, so
  ## they must NOT be extruded with the terrain -- relief.py paints them golden
  ## sand AND zeroes displacement there, so they read as flat sand meeting the
  ## water instead of a raised lip. beach = in-state land, at/below BEACH_ELEV_M,
  ## within BEACH_DIST_M of the ocean. Feathered so sand blends into the plain.
  b_elev <- as.numeric(Sys.getenv("BEACH_ELEV_M", "8"))
  b_dist <- as.numeric(Sys.getenv("BEACH_DIST_M", "700"))
  ocr2 <- terra::rast(dem); terra::values(ocr2) <- as.vector(t(ocean * 1))
  ocr2[ocr2 == 0] <- NA
  d2sea <- terra::as.matrix(fast_dist(ocr2), wide = TRUE)         # m from land to ocean
  beach <- instate & (m <= b_elev) & (d2sea <= b_dist)
  beach[is.na(beach)] <- FALSE
  bfr <- terra::rast(dem); terra::values(bfr) <- as.vector(t(beach * 1))
  bfr <- terra::focal(bfr, w = 5, fun = mean, na.rm = TRUE)        # feather inland edge
  bmat <- terra::as.matrix(bfr, wide = TRUE); bmat[is.na(bmat)] <- 0
  bmat[!instate] <- 0
  bmat[bmat < 0.02] <- 0; bmat[bmat > 1] <- 1
  png::writePNG(bmat, file.path(outdir, paste0(slug, "_beach.png")))
  message(sprintf("wrote %s_beach.png (%d px, <=%.0f m elev, <=%.0f m from sea)",
                  slug, sum(beach), b_elev, b_dist))

  ## COAST TAPER: ramp the terrain down to sea level as it approaches the shore.
  ## Without this the displaced mesh drops from full cliff height straight to 0
  ## at the mask edge, rendering as a ribbed vertical grey CURTAIN along the
  ## coast (the "shabby extruded shapes on the sea face"). 0 at the waterline ->
  ## 1 by COAST_TAPER_M inland. Only the seaward side is affected: inland state
  ## borders are far from the ocean, so their taper is already 1 and the carved
  ## slab edge there is untouched.
  ct_m <- as.numeric(Sys.getenv("COAST_TAPER_M", "0"))
  if (ct_m > 0) {
    tp <- d2sea / ct_m
    tp[tp < 0] <- 0; tp[tp > 1] <- 1                # clamp IN PLACE (pmin/pmax drop dims)
    tp <- tp * tp * (3 - 2 * tp)                                   # smoothstep
    tp[!instate] <- 0
    tp[is.na(tp)] <- 0
    png::writePNG(tp, file.path(outdir, paste0(slug, "_coast.png")))
    message(sprintf("wrote %s_coast.png (taper %.0f m to sea level)", slug, ct_m))
  }

  ## WAVES: thin white dashes running parallel to the shore inside the band --
  ## the classic cartographic wave symbol. Concentric thin rings at fixed
  ## distances offshore, broken into dashes by a coarse random field.
  if (as.numeric(Sys.getenv("WAVES", "0")) > 0) {
    rings <- as.numeric(strsplit(Sys.getenv("WAVE_RINGS_M", "260,620,1050"), ",")[[1]])
    wthk  <- as.numeric(Sys.getenv("WAVE_THICK_M", "55"))
    wave  <- matrix(FALSE, nrow(dmat), ncol(dmat))
    for (d in rings) wave <- wave | (abs(dmat - d) <= wthk)
    wave <- wave & ocean
    set.seed(as.integer(Sys.getenv("WAVE_SEED", "7")))
    nsr <- terra::rast(nrows = 240, ncols = 200, extent = terra::ext(terra::rast(dem)),
                       crs = terra::crs(terra::rast(dem)))
    terra::values(nsr) <- runif(240 * 200)
    nsu <- terra::as.matrix(terra::resample(nsr, terra::rast(dem), method = "bilinear"),
                            wide = TRUE)
    wave <- wave & (nsu > as.numeric(Sys.getenv("WAVE_DASH", "0.52")))
    wave[is.na(wave)] <- FALSE
    png::writePNG(wave * 1, file.path(outdir, paste0(slug, "_waves.png")))
    message(sprintf("wrote %s_waves.png (%d px, %d rings)", slug, sum(wave), length(rings)))
  }
}

## rivers: rasterize the cached OSM gpkg onto the DEM grid (thin lines) -------
## Aligned to the exact DEM grid so it registers pixel-perfect with the height
## map in Blender. Buffered slightly so thin lines survive downsampling.
riv_gpkg <- file.path(outdir, paste0(slug, "_rivers.gpkg"))
if (file.exists(riv_gpkg)) {
  suppressPackageStartupMessages(library(terra))
  rv  <- terra::vect(riv_gpkg)
  ## RIVER_BUFFER_M: half-width in metres. 200 reads FAT on a small, dense-network
  ## state (Goa looked like "land between lots of rivers"); drop to ~60 there.
  rbuf <- as.numeric(Sys.getenv("RIVER_BUFFER_M", "200"))
  rvb <- terra::buffer(rv, width = rbuf)
  rr  <- terra::rasterize(rvb, terra::rast(dem), background = 0)
  rmat <- terra::as.matrix(rr, wide = TRUE); rmat[is.na(rmat)] <- 0
  png::writePNG((rmat > 0) * 1, file.path(outdir, paste0(slug, "_rivers.png")))
  message(sprintf("wrote %s_rivers.png (%d px)", slug, sum(rmat > 0)))
}

## lakes / reservoirs: rasterize cached water polygons (filled) --------------
lk_gpkg <- file.path(outdir, paste0(slug, "_lakes.gpkg"))
if (file.exists(lk_gpkg)) {
  suppressPackageStartupMessages(library(terra))
  lv <- terra::vect(lk_gpkg)
  lr <- terra::rasterize(lv, terra::rast(dem), background = 0, touches = TRUE)
  lmat <- terra::as.matrix(lr, wide = TRUE); lmat[is.na(lmat)] <- 0
  png::writePNG((lmat > 0) * 1, file.path(outdir, paste0(slug, "_lakes.png")))
  message(sprintf("wrote %s_lakes.png (%d px)", slug, sum(lmat > 0)))
}

## state outline (simplified exterior rings) for the Blender base slab --------
osimp <- sf::st_simplify(sel, dTolerance = 0.004, preserveTopology = TRUE)
co <- as.data.frame(sf::st_coordinates(osimp))
for (L in c("L1", "L2", "L3")) if (!L %in% names(co)) co[[L]] <- 1
ext <- co[co$L1 == 1, ]                              # exterior rings only (drop holes)
rings <- lapply(split(ext, interaction(ext$L3, ext$L2, drop = TRUE)), function(d)
  lapply(seq_len(nrow(d)), function(i) c(d$X[i], d$Y[i])))
jsonlite::write_json(unname(rings), file.path(outdir, paste0(slug, "_outline.json")),
                     auto_unbox = TRUE)
message(sprintf("wrote %s_outline.json (%d ring[s])", slug, length(rings)))

## metadata for Blender scale ------------------------------------------------
e <- raster::extent(dem)
meanlat <- (e@ymin + e@ymax) / 2
dlon <- e@xmax - e@xmin; dlat <- e@ymax - e@ymin
width_km  <- dlon * 111.32 * cos(meanlat * pi / 180)
height_km <- dlat * 111.32
meta <- list(
  state = state, zoom = zoom, ncol = ncol(m), nrow = nrow(m),
  elev_min_m = mn, elev_max_m = mx, elev_range_km = (mx - mn) / 1000,
  width_km = width_km, height_km = height_km,
  aspect = width_km / height_km,                 # true geographic width:height
  sea = sea_mode,                                # TRUE = coastal grid extended into the sea
  xmin = e@xmin, xmax = e@xmax, ymin = e@ymin, ymax = e@ymax)
jsonlite::write_json(meta, file.path(outdir, paste0(slug, "_meta.json")),
                     auto_unbox = TRUE, pretty = TRUE)
message(sprintf("wrote %s_height.png (%dx%d), mask, meta | elev %.0f-%.0fm aspect %.3f",
                slug, ncol(m), nrow(m), mn, mx, meta$aspect))
