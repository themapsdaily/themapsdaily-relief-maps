#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Render a top-notch 3D shaded-relief map of an Indian state, with rivers +
# city/capital labels (Inter font).
#
#   Rscript render_state.R "<State>" [zoom] [zscale] [samples] [phi]
#   Rscript render_state.R "Uttarakhand" 9 40 256 90
#
# zoom    = DEM resolution (8 coarse .. 11 fine).
# zscale  = vertical scale. HIGHER = flatter/more natural; LOWER = spiky.
# samples = path-trace quality (<=256). ~60 preview, 256 final.
# phi     = camera tilt (90 = top-down, the mappdout/California look; clamped
#           to 89.5 to dodge the HQ-camera gimbal lock at exactly 90).
#
# Output = 1080x1920 VERTICAL studio canvas (grey backdrop baked in by the
#          path tracer; drop straight onto an IG/story slide).
#
# Env toggles (fast iteration):
#   RELIEF_AO=0            skip ambient occlusion (slow)
#   RELIEF_OUT_W/OUT_H     canvas px (default 1080x1920; use 540x960 for preview)
#   RELIEF_GROUND=#cfcfd4  studio backdrop albedo
#   RELIEF_VIGNETTE=0      skip the radial backdrop vignette
#   RELIEF_RIVERS=0        skip rivers
#   RELIEF_LABELS=0        skip city labels
#   RELIEF_LABELSIZE       label size (default 24)
#
# Per-state city labels: curated cities/<slug>.csv (name,lat,long,capital);
# falls back to OSM place nodes if no CSV. Rivers + cities cached to output/.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(rayshader); library(rayrender); library(elevatr); library(sf)
  library(terra); library(raster); library(rgl); library(osmdata); library(systemfonts)
})
options(rgl.useNULL = TRUE)

args    <- commandArgs(trailingOnly = TRUE)
state   <- if (length(args) >= 1) args[[1]]             else "Uttarakhand"
zoom    <- if (length(args) >= 2) as.integer(args[[2]])  else 9L
zscale  <- if (length(args) >= 3) as.numeric(args[[3]])  else 40
samples <- if (length(args) >= 4) as.integer(args[[4]])  else 256L
phi     <- if (length(args) >= 5) as.numeric(args[[5]])  else 90
phi     <- min(phi, 89.5)   # exact 90 gimbal-locks the HQ camera (up || view)
do_ao   <- Sys.getenv("RELIEF_AO",     "1") != "0"
outw    <- as.integer(Sys.getenv("RELIEF_OUT_W", Sys.getenv("RELIEF_W", "1080")))
outh    <- as.integer(Sys.getenv("RELIEF_OUT_H", "1350"))    # 4:5 IG portrait (1080x1350)
groundcol <- Sys.getenv("RELIEF_GROUND", "#d7d7d7")          # CA grey (215); exposure tuned ~1:1 below
do_riv  <- Sys.getenv("RELIEF_RIVERS", "1") != "0"
do_lab  <- Sys.getenv("RELIEF_LABELS", "1") != "0"
labsize <- as.numeric(Sys.getenv("RELIEF_LABELSIZE", "24"))
zoomf   <- as.numeric(Sys.getenv("RELIEF_ZOOM", "1.0"))    # higher = zoom out / more margin
boundary <- Sys.getenv("RELIEF_BOUNDARY", "data/boundaries/india-2021.geojson")
outdir  <- "output"; dir.create(outdir, showWarnings = FALSE)
slug    <- gsub("\\s+", "_", tolower(state))
demfile <- file.path(outdir, sprintf("%s_dem_z%d.tif", slug, zoom))
rivfile <- file.path(outdir, sprintf("%s_rivers.gpkg", slug))
message(sprintf("State=%s zoom=%d zscale=%s samples=%d phi=%s ao=%s riv=%s lab=%s out=%dx%d",
                state, zoom, zscale, samples, phi, do_ao, do_riv, do_lab, outw, outh))

## Register Inter (deterministic; overrides any system copy) -----------------
if (file.exists("fonts/Inter-400.ttf"))
  try(systemfonts::register_font(name = "Inter",
        plain = "fonts/Inter-400.ttf", bold = "fonts/Inter-700.ttf"), silent = TRUE)

## 1. Boundary --------------------------------------------------------------
ind_sf <- sf::st_read(boundary, quiet = TRUE)
sel    <- ind_sf[ind_sf$st_nm == state, ]
if (nrow(sel) == 0)
  stop(sprintf("State '%s' not found. Options:\n%s",
               state, paste(sort(ind_sf$st_nm), collapse = ", ")))
sel <- sf::st_make_valid(sf::st_transform(sel, 4326))

## 2. DEM (cached) ----------------------------------------------------------
if (file.exists(demfile)) {
  message("using cached DEM: ", demfile); dem <- raster::raster(demfile)
} else {
  dem <- elevatr::get_elev_raster(locations = sel, z = zoom, clip = "locations")
  raster::writeRaster(dem, demfile, overwrite = TRUE)
}
mat <- rayshader::raster_to_matrix(dem)

## Fill small interior NoData holes (they render as black voids at top-down).
## Only cells with >=6 valid neighbours fill, so the state boundary is preserved.
fill_interior_holes <- function(m, passes = 8L, thresh = 6L) {
  nr <- nrow(m); nc <- ncol(m)
  for (p in seq_len(passes)) {
    if (!anyNA(m)) break
    good <- matrix(0L, nr, nc); acc <- matrix(0, nr, nc)
    for (di in -1:1) for (dj in -1:1) {
      if (di == 0 && dj == 0) next
      sub <- m[pmin(pmax((1:nr) + di, 1), nr), pmin(pmax((1:nc) + dj, 1), nc)]
      g <- !is.na(sub); good <- good + g
      sub[is.na(sub)] <- 0; acc <- acc + sub
    }
    fillable <- is.na(m) & good >= thresh
    if (!any(fillable)) break
    m[fillable] <- (acc / pmax(good, 1L))[fillable]
  }
  m
}
mat <- fill_interior_holes(mat)

## Downsample very-fine DEMs (z10 ~5000px) to a workable shading size; still far
## finer than the 1080 canvas, so ridge detail supersamples down cleanly.
maxdim <- as.integer(Sys.getenv("RELIEF_MAXDIM", "2600"))
if (max(dim(mat)) > maxdim) {
  mat <- rayshader::resize_matrix(mat, scale = maxdim / max(dim(mat)))
  message(sprintf("resized matrix to %dx%d", nrow(mat), ncol(mat)))
}

ext <- raster::extent(dem)
zr  <- diff(range(mat, na.rm = TRUE))

## 3. Hypsometric palette (mappdout look: seafoam lowlands -> tan -> brown
##    ridges -> cream peaks). Teal is reserved for the lowest ~15%.
## Matched to sampled mappdout/California tones: muted grey-green seafoam valley,
## earthy sienna mountains (not orange), soft cream peaks (not pure white).
pal  <- grDevices::colorRampPalette(c(
  "#66A778", "#8CB488", "#B0BC93", "#CFC196", "#C69C5E", "#A6733E",
  "#BE8F58", "#D5C8A2", "#E7DDC5", "#F3EDDE"))(256)   # lowlands greener (was too blue)
# Sharpen the relief: shade with an EXAGGERATED height (lower effective zscale =
# steeper apparent slopes = longer, crisper shadows). RELIEF_EXAG tunes it.
exag <- as.numeric(Sys.getenv("RELIEF_EXAG", "2.8"))
szs  <- zscale / exag
# CA relief = DEEP shadows + high contrast. max_darken low = shadows go dark.
sunalt <- as.numeric(Sys.getenv("RELIEF_SUNALT", "30"))   # lower = more grazing contrast
hs <- rayshader::height_shade(mat, texture = pal) |>
  # SLOPE SHADING = the internal contrast. Shaded faces go dark, lit faces keep
  # full colour. Low max_darken = STRONG. (This was crippled at 0.50 before.)
  rayshader::add_shadow(
    rayshader::lamb_shade(mat, zscale = szs, sunaltitude = sunalt),
    max_darken = as.numeric(Sys.getenv("RELIEF_SLOPE", "0.15"))) |>
  # cast shadows down the valleys
  rayshader::add_shadow(
    rayshader::ray_shade(mat, zscale = szs, sunaltitude = sunalt, lambert = FALSE),
    max_darken = 0.12) |>
  # fine ridge micro-detail — Leland-Brown texture shading = the etched CA look.
  # This is the granularity lever: strong contrast + low max_darken.
  rayshader::add_shadow(
    rayshader::texture_shade(mat, detail = 0.92,
      contrast = as.numeric(Sys.getenv("RELIEF_TEXCON", "22")), brightness = 7),
    max_darken = as.numeric(Sys.getenv("RELIEF_TEX", "0.32")))
if (do_ao)
  hs <- hs |> rayshader::add_shadow(
    rayshader::ambient_shade(mat, zscale = szs), max_darken = 0.42)   # lift mid/valleys

## 4. Rivers (cached OSM fetch; manual composite avoids the broken add_overlay)
fetch_rivers <- function(sel) {
  bb <- as.numeric(sf::st_bbox(sel))
  for (u in c("https://overpass-api.de/api/interpreter",
              "https://overpass.kumi.systems/api/interpreter")) {
    r <- tryCatch({ osmdata::set_overpass_url(u)
      osmdata::opq(bbox = bb, timeout = 180) |>
        osmdata::add_osm_feature(key = "waterway", value = "river") |>
        osmdata::osmdata_sf() |> (\(d) d$osm_lines)()
    }, error = function(e) { message("  overpass ", u, " -> ", conditionMessage(e)); NULL })
    if (!is.null(r) && nrow(r) > 0) return(r)
  }
  NULL
}
get_rivers <- function() {
  if (file.exists(rivfile)) return(sf::st_read(rivfile, quiet = TRUE))
  lines <- fetch_rivers(sel)
  if (is.null(lines) || nrow(lines) == 0) return(NULL)
  lines <- sf::st_intersection(sf::st_transform(lines, 4326), sel)["geometry"]
  sf::st_write(lines, rivfile, quiet = TRUE, delete_dsn = TRUE)
  lines
}
composite_overlay <- function(base, ov) {          # alpha-blend RGBA ov onto base
  a <- ov[, , 4]; a[is.na(a)] <- 0
  for (k in 1:min(3, dim(base)[3])) {
    och <- ov[, , k]; och[is.na(och)] <- 0
    base[, , k] <- base[, , k] * (1 - a) + och * a
  }
  base
}
if (do_riv) tryCatch({
  lines <- get_rivers()
  if (!is.null(lines) && nrow(lines) > 0) {
    ov <- rayshader::generate_line_overlay(lines, extent = ext, heightmap = mat,
                                           color = "#4E86A6", linewidth = 1.5)   # thinner, muted
    hs <- composite_overlay(hs, ov)
    message(sprintf("rivers: %d segments", nrow(lines)))
  } else message("rivers: none")
}, error = function(e) message("rivers skipped: ", conditionMessage(e)))

## 5. Render the relief as a flat transparent layer (top-down 2D, north up) ---
## No path tracer: this is the mappdout/California method. Terrain colour and the
## grey backdrop are now INDEPENDENT layers (composited in step 6), so the grey
## can be an exact studio tone while the terrain stays bright & vivid.
outfile    <- file.path(outdir, sprintf("%s.png", slug))
relieffile <- file.path(outdir, sprintf("%s_relief.png", slug))
rw <- ncol(mat); rh <- nrow(mat)
# height_shade leaves NoData cells opaque-black in places; force a clean alpha
# from the RGB NoData mask so the exterior is fully transparent (not black).
if (length(dim(hs)) == 3) {
  namask <- is.na(hs[, , 1])
  for (k in 1:3) { ch <- hs[, , k]; ch[namask] <- 0; hs[, , k] <- ch }
  if (dim(hs)[3] >= 4) hs[, , 4] <- ifelse(namask, 0, 1)
  else hs <- array(c(hs[, , 1], hs[, , 2], hs[, , 3], ifelse(namask, 0, 1)),
                   dim = c(dim(hs)[1], dim(hs)[2], 4))
}
ragg::agg_png(relieffile, width = rw, height = rh, background = "transparent")
par(mar = c(0, 0, 0, 0)); rayshader::plot_map(hs)
invisible(grDevices::dev.off())

## 6. Composite onto the flat grey studio canvas + soft drop shadow -----------
relief <- magick::image_trim(magick::image_read(relieffile))   # drop plot_map's letterbox padding so terrain spans the DEM extent edge-to-edge (label projection depends on this)
# crisp up the ridge detail (unsharp mask at native relief res, before downscale)
shpn <- as.numeric(Sys.getenv("RELIEF_SHARPEN", "1.1"))
if (shpn > 0) relief <- magick::image_unsharp(relief, radius = 0, sigma = 1.2, amount = shpn, threshold = 0.01)
# undo the EPSG:4326 squish: stretch HEIGHT by 1/cos(lat) -> true proportions.
klat   <- 1 / cos(((ext@ymin + ext@ymax) / 2) * pi / 180)
ti     <- magick::image_info(relief)
relief <- magick::image_resize(relief, sprintf("%dx%d!", ti$width, round(ti$height * klat)))
ri     <- magick::image_info(relief)
marg   <- as.numeric(Sys.getenv("RELIEF_MARGIN", "0.09"))
s      <- min(outw * (1 - 2 * marg) / ri$width, outh * (1 - 2 * marg) / ri$height)
pw     <- round(ri$width * s); ph <- round(ri$height * s)
ox     <- round((outw - pw) / 2); oy <- round((outh - ph) / 2)
relief <- magick::image_resize(relief, sprintf("%dx%d!", pw, ph))

transparent_bg <- tolower(groundcol) %in% c("none", "transparent")
canvas <- magick::image_blank(outw, outh, color = if (transparent_bg) "none" else groundcol)

# soft drop shadow (only on a solid backdrop; skip it for a clean cutout)
if (!transparent_bg) {
  dx   <- round(pw * 0.012); dy <- round(ph * 0.016); blur <- max(6, round(pw * 0.018))
  shad <- magick::image_blank(pw, ph, color = "black") |>
    magick::image_composite(relief, operator = "CopyOpacity") |>
    magick::image_fx(expression = "0.34*a", channel = "alpha") |>
    magick::image_blur(0, blur)
  canvas <- magick::image_composite(canvas, shad, "over",
              offset = sprintf("+%d+%d", ox + dx, oy + dy))
}
canvas <- magick::image_composite(canvas, relief, "over",
            offset = sprintf("+%d+%d", ox, oy))
magick::image_write(canvas, outfile)

## 7. Project city labels (pure 2D lat/long -> canvas pixel; north up) --------
lab_px <- NULL
if (do_lab) tryCatch({
  cf     <- file.path("cities", paste0(slug, ".csv"))
  cities <- if (file.exists(cf)) utils::read.csv(cf, stringsAsFactors = FALSE) else NULL
  if (!is.null(cities) && nrow(cities) > 0) {
    fx <- (cities$long - ext@xmin) / (ext@xmax - ext@xmin)
    fy <- (ext@ymax - cities$lat)  / (ext@ymax - ext@ymin)
    lab_px <- data.frame(name = cities$name, capital = as.integer(cities$capital),
                         x = ox + fx * pw, y = oy + fy * ph)
    message(sprintf("labels: projected %d cities", nrow(lab_px)))
  }
}, error = function(e) message("labels skipped: ", conditionMessage(e)))

## 8. Draw Inter labels (upright, light halo, capital marked) + composite -----
if (do_lab && !is.null(lab_px) && nrow(lab_px) > 0) {
  layer <- file.path(outdir, sprintf("%s_labels.png", slug))
  ps    <- labsize * outw / 1920
  ragg::agg_png(layer, width = outw, height = outh, background = "transparent", pointsize = ps)
  par(mar = c(0, 0, 0, 0)); plot.new()
  plot.window(xlim = c(0, outw), ylim = c(outh, 0), xaxs = "i", yaxs = "i")
  halo <- max(0.8, ps * 0.045); gap <- ps * 0.5           # thin, soft border
  for (i in order(lab_px$capital)) {                     # capital drawn last (top)
    x <- lab_px$x[i]; y <- lab_px$y[i]; cap <- isTRUE(lab_px$capital[i] == 1)
    lab <- lab_px$name[i]; cx <- if (cap) 1.12 else 0.9; fw <- if (cap) 2 else 1
    tcol <- if (cap) "#6E1616" else "#2A2A2A"
    points(x, y, pch = 21, cex = if (cap) 1.15 else 0.7,
           bg = if (cap) "#B23A3A" else "#FFFFFF",
           col = if (cap) "#6E1616" else "#5A5A5A", lwd = if (cap) 1.3 else 0.8)
    for (a in seq(0, 2 * pi, length.out = 13)[-1])       # thin white halo ring
      text(x + gap + cos(a) * halo, y + sin(a) * halo, lab,
           adj = c(0, 0.5), family = "Inter", font = fw, cex = cx,
           col = grDevices::adjustcolor("white", 0.85))
    text(x + gap, y, lab, adj = c(0, 0.5), family = "Inter", font = fw, cex = cx, col = tcol)
  }
  dev.off()
  magick::image_composite(magick::image_read(outfile), magick::image_read(layer), "over") |>
    magick::image_write(outfile)
  message(sprintf("labels composited: %d", nrow(lab_px)))
}

## 8b. Subtle vividness pop (saturation + brightness) so the terrain reads as
##     rich as the reference; neutral grey backdrop is unaffected by saturation.
if (Sys.getenv("RELIEF_POP", "1") != "0") tryCatch({
  sat <- as.numeric(Sys.getenv("RELIEF_SAT", "118"))
  magick::image_read(outfile) |>
    magick::image_modulate(brightness = 100, saturation = sat) |>
    magick::image_level(black_point = 6, white_point = 95) |>   # photographic contrast stretch
    magick::image_write(outfile)
}, error = function(e) message("pop skipped: ", conditionMessage(e)))

## 9. Optional radial vignette (off by default) -> lighter centre, darker edges.
##    The grey ground already IS the full canvas, so no trim.
if (Sys.getenv("RELIEF_VIGNETTE", "0") != "0") tryCatch({
  base <- magick::image_read(outfile)
  info <- magick::image_info(base)
  vig  <- magick::image_read(sprintf("radial-gradient:none-#0000001A")) |>
    magick::image_resize(sprintf("%dx%d!", info$width, info$height))
  magick::image_composite(base, vig, "over") |> magick::image_write(outfile)
  message("vignette applied")
}, error = function(e) message("vignette skipped: ", conditionMessage(e)))
message("Saved -> ", outfile)
