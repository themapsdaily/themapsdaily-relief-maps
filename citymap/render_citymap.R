#!/usr/bin/env Rscript
# Black-on-white OSM road "line map" renderer for print.
#   Rscript citymap/render_citymap.R <slug> [--refresh]
# Reads the city's row from citymap/cities.csv, downloads OSM roads + railways
# (tiled, cached in citymap/cache/<slug>/), and writes to output/cities/<slug>/:
#   <slug>_line.pdf          vector, 24x36 in
#   <slug>_line.png          300 dpi, 12x18 in (3600x5400)
#   <slug>_line_preview.jpg  ~1200 px wide, for email
# A new city = a new row in cities.csv. Never a new script.
suppressPackageStartupMessages(library(sf))   # GDAL's OSM driver parses the Overpass XML

# ---- paths ------------------------------------------------------------------
args  <- commandArgs(trailingOnly = TRUE)
farg  <- grep("^--file=", commandArgs(FALSE), value = TRUE)
here  <- if (length(farg)) dirname(normalizePath(sub("^--file=", "", farg[1]))) else normalizePath("citymap")
root  <- dirname(here)
slug  <- args[!grepl("^--", args)][1]
refresh <- "--refresh" %in% args
if (is.na(slug)) stop("usage: Rscript citymap/render_citymap.R <slug> [--refresh]")

cities <- read.csv(file.path(here, "cities.csv"), stringsAsFactors = FALSE)
row <- cities[cities$slug == slug, ]
if (nrow(row) != 1) stop("slug not in citymap/cities.csv: ", slug)
ar <- if (grepl(":", row$aspect)) { p <- as.numeric(strsplit(row$aspect, ":")[[1]]); p[1] / p[2] } else as.numeric(row$aspect)

cache_dir <- file.path(here, "cache", slug)
out_dir   <- file.path(root, "output", "cities", slug)
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(out_dir,   recursive = TRUE, showWarnings = FALSE)

# ---- design constants (inches on the 24x36 page; PNG is the same page scaled) --
PAGE_W <- 24; PAGE_H <- 36
FRAME_INSET <- 0.5      # page edge to outer frame edge
FRAME_THICK <- 0.42     # frame thickness
# line widths in points on the 24x36 page, by class
WIDTHS <- c(motorway = 2.6, trunk = 2.6, primary = 2.0, secondary = 1.35,
            tertiary = 1.0, residential = 0.5, minor = 0.32, rail = 0.55)
MIN_PT_PNG <- 0.30      # floor after scaling for the 12x18 PNG
SERVERS <- c("https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter", "https://overpass.private.coffee/api/interpreter")
PAUSE_S <- 8            # between Overpass requests
TILE_DEG <- 0.08        # tile height in degrees

# ---- extent: expand the bbox to the map window's aspect ------------------------
inner_w <- PAGE_W - 2 * (FRAME_INSET + FRAME_THICK)
inner_h <- PAGE_H - 2 * (FRAME_INSET + FRAME_THICK)
bb_ll <- st_bbox(c(xmin = row$west, ymin = row$south, xmax = row$east, ymax = row$north), crs = 4326)
utm_zone <- floor((mean(c(row$west, row$east)) + 180) / 6) + 1
crs_m <- 32600 + utm_zone + if (mean(c(row$south, row$north)) < 0) 100 else 0
bb_m <- st_bbox(st_transform(st_as_sfc(bb_ll), crs_m))
w <- bb_m$xmax - bb_m$xmin; h <- bb_m$ymax - bb_m$ymin
target <- inner_w / inner_h
if (w / h < target) { d <- h * target - w; bb_m[c("xmin", "xmax")] <- c(bb_m$xmin - d / 2, bb_m$xmax + d / 2)
} else               { d <- w / target - h; bb_m[c("ymin", "ymax")] <- c(bb_m$ymin - d / 2, bb_m$ymax + d / 2) }
bb_ll2 <- st_bbox(st_transform(st_as_sfc(bb_m), 4326))   # bbox actually fetched

# ---- OSM download, tiled + cached ----------------------------------------------
FEATURES <- c('"highway"~"^(motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|service|track|road|pedestrian)$"',
              '"railway"~"^(rail|light_rail|monorail|subway)$"')
ny <- max(1, ceiling((bb_ll2["ymax"] - bb_ll2["ymin"]) / TILE_DEG))
nx <- max(1, ceiling((bb_ll2["xmax"] - bb_ll2["xmin"]) / (TILE_DEG * 0.9)))
xs <- seq(bb_ll2["xmin"], bb_ll2["xmax"], length.out = nx + 1)
ys <- seq(bb_ll2["ymin"], bb_ll2["ymax"], length.out = ny + 1)

fetch_tile <- function(b, f) {
  if (file.exists(f) && !refresh) return(readRDS(f))
  # Overpass QL by hand (own curl call: real User-Agent, our own retry/backoff).
  bb <- sprintf("(%f,%f,%f,%f)", b[2], b[1], b[4], b[3])
  ql <- paste0("[out:xml][timeout:180];(",
               paste0("way[", FEATURES, "]", bb, ";", collapse = ""),
               ");out body;>;out skel qt;")
  xml <- tempfile(fileext = ".osm")
  for (attempt in 1:8) {
    srv <- SERVERS[(attempt - 1) %% length(SERVERS) + 1]
    code <- suppressWarnings(system2("curl", c("-s", "-m", "300", "-A", shQuote("citymap-render/1.0 (print map sample)"),
                  "-o", shQuote(xml), "-w", "%{http_code}", "--data-urlencode", shQuote(paste0("data=", ql)), shQuote(srv)), stdout = TRUE))
    Sys.sleep(PAUSE_S)
    ok <- identical(code, "200") && file.exists(xml) && file.size(xml) > 0 &&
          !any(grepl("<remark>.*(runtime error|timed out)", readLines(xml, n = 40, warn = FALSE)))
    if (ok) {
      res <- try({
        l <- suppressWarnings(st_read(xml, layer = "lines", quiet = TRUE))
        l$tunnel <- ifelse(grepl('"tunnel"=>"(yes|building_passage)"', l$other_tags), "yes", NA_character_)
        l <- l[!duplicated(l$osm_id), ]
        l <- st_set_crs(l, 4326)
        l[, c("osm_id", "highway", "railway", "tunnel")]
      }, silent = TRUE)
      if (!inherits(res, "try-error")) { saveRDS(res, f); return(res) }
    }
    message("  tile failed (attempt ", attempt, ", HTTP ", paste(code, collapse = ""), ", ", srv, "); backing off")
    Sys.sleep(PAUSE_S * attempt * 2)
  }
  stop("tile failed 8 times: ", f)
}
# Preferred source: a Geofabrik region extract on disk (cities.csv `pbf`, saved in
# citymap/cache/osm/). Public Overpass servers are often at capacity (2026-11-23:
# every tile got 502/504), so Overpass tiles are only the fallback.
pbf <- if (!is.null(row$pbf) && nzchar(row$pbf)) file.path(here, "cache", "osm", row$pbf) else ""
roads_rds <- file.path(cache_dir, "roads_pbf.rds")
if (nzchar(pbf) && file.exists(pbf)) {
  if (file.exists(roads_rds) && !refresh) {
    roads <- readRDS(roads_rds)
  } else {
    message("reading ", basename(pbf), " (clipped to the map extent)")
    roads <- suppressWarnings(st_read(pbf, layer = "lines", quiet = TRUE,
      query = "SELECT osm_id, highway, railway, other_tags FROM lines WHERE highway IS NOT NULL OR railway IS NOT NULL",
      wkt_filter = st_as_text(st_as_sfc(bb_ll2))))
    keep_hw <- c("motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link",
                 "tertiary", "tertiary_link", "unclassified", "residential", "living_street", "service", "track", "road", "pedestrian")
    roads <- roads[(roads$highway %in% keep_hw) | (roads$railway %in% c("rail", "light_rail", "monorail", "subway")), ]
    roads$tunnel <- ifelse(grepl('"tunnel"=>"(yes|building_passage)"', roads$other_tags), "yes", NA_character_)
    roads <- st_set_crs(roads[, c("osm_id", "highway", "railway", "tunnel")], 4326)
    saveRDS(roads, roads_rds)
  }
} else {
  tiles <- list()
  for (i in seq_len(nx)) for (j in seq_len(ny)) {
    b <- c(xs[i], ys[j], xs[i + 1], ys[j + 1])
    f <- file.path(cache_dir, sprintf("tile_%d_%d.rds", i, j))
    message(sprintf("tile %d/%d (%s)", (i - 1) * ny + j, nx * ny, if (file.exists(f) && !refresh) "cached" else "download"))
    tiles[[length(tiles) + 1]] <- fetch_tile(b, f)
  }
  roads <- do.call(rbind, tiles)
}
roads <- roads[!duplicated(roads$osm_id), ]
message("ways: ", nrow(roads))

# ---- classify ------------------------------------------------------------------
hw <- sub("_link$", "", roads$highway)
cls <- ifelse(!is.na(roads$railway), "rail",
       ifelse(hw %in% c("motorway", "trunk", "primary", "secondary", "tertiary", "residential"), hw,
       ifelse(hw %in% c("unclassified", "living_street", "road", "pedestrian"), "residential", "minor")))
cls[!is.na(roads$railway) & roads$tunnel %in% c("yes", "building_passage")] <- NA   # hide underground rail
roads$cls <- cls
roads <- roads[!is.na(roads$cls), ]
roads <- st_transform(roads, crs_m)
roads <- suppressWarnings(st_crop(roads, bb_m))
roads <- roads[!st_is_empty(roads), ]
roads <- suppressWarnings(st_cast(roads, "MULTILINESTRING"))

# ---- drawing ---------------------------------------------------------------------
x0 <- FRAME_INSET + FRAME_THICK; y0 <- x0; x1 <- PAGE_W - x0; y1 <- PAGE_H - y0
sx <- (x1 - x0) / (bb_m$xmax - bb_m$xmin)      # metres -> page inches (same both axes)
to_page <- function(g) {
  st_geometry(g) <- (st_geometry(g) - c(bb_m$xmin, bb_m$ymin)) * sx + c(x0, y0)
  st_geometry(g)
}
pg <- to_page(roads)

# text as vector outlines (works identically on pdf and png devices)
text_polys <- function(txt, font, cap_in, tracking = 0) {
  sh <- textshaping::shape_text(txt, path = font, size = 100, res = 72)$shape
  go <- systemfonts::glyph_outline(sh$index, rep(font, nrow(sh)), size = 100, tolerance = 0.2)
  ref <- systemfonts::glyph_outline(textshaping::shape_text("H", path = font, size = 100, res = 72)$shape$index[1], font, size = 100)
  k <- cap_in / diff(range(ref$y))
  go$gi <- go$glyph; go$x <- go$x
  list(go = go, sh = sh, k = k, ymin_ref = min(ref$y))
}
draw_text <- function(txt, font, cap_in, x, y, tracking = 0) {
  # y = baseline. Place glyph by glyph with pen advance from the shaper.
  sh <- textshaping::shape_text(txt, path = font, size = 100, res = 72)$shape
  ref <- systemfonts::glyph_outline(textshaping::shape_text("H", path = font, size = 100, res = 72)$shape$index[1], font, size = 100)
  k <- cap_in / diff(range(ref$y))
  pen <- sh$x_offset
  total <- 0
  for (n in seq_len(nrow(sh))) {
    o <- systemfonts::glyph_outline(sh$index[n], font, size = 100, tolerance = 0.2)
    if (is.null(o) || nrow(o) == 0) next
    px <- x + (sh$x_offset[n] + o$x) * k + tracking * (n - 1)
    py <- y + o$y * k
    key <- paste(o$glyph, o$contour)
    xy <- split(data.frame(x = px, y = py), factor(key, unique(key)))
    xs_ <- unlist(lapply(xy, function(d) c(d$x, NA))); ys_ <- unlist(lapply(xy, function(d) c(d$y, NA)))
    polypath(xs_[-length(xs_)], ys_[-length(ys_)], rule = "winding", col = "black", border = NA)
    total <- max(total, max(px) - x)
  }
  total
}
text_width <- function(txt, font, cap_in, tracking = 0) {
  sh <- textshaping::shape_text(txt, path = font, size = 100, res = 72)$shape
  ref <- systemfonts::glyph_outline(textshaping::shape_text("H", path = font, size = 100, res = 72)$shape$index[1], font, size = 100)
  k <- cap_in / diff(range(ref$y))
  last <- nrow(sh)
  o <- systemfonts::glyph_outline(sh$index[last], font, size = 100, tolerance = 0.2)
  (sh$x_offset[last] + max(o$x)) * k + tracking * (last - 1)
}

draw_map <- function(scale) {
  par(mar = c(0, 0, 0, 0), xaxs = "i", yaxs = "i", bg = "white", lend = 1, ljoin = 1)
  plot.new(); plot.window(c(0, PAGE_W), c(0, PAGE_H))
  rect(0, 0, PAGE_W, PAGE_H, col = "white", border = NA)
  # frame
  rect(FRAME_INSET, FRAME_INSET, PAGE_W - FRAME_INSET, PAGE_H - FRAME_INSET, col = "black", border = NA)
  rect(x0, y0, x1, y1, col = "white", border = NA)
  clip(x0, x1, y0, y1)
  lwd_of <- function(pt) max(pt * scale, if (scale < 1) MIN_PT_PNG else 0) * 96 / 72
  # thinnest first so the hierarchy reads
  for (cl in c("minor", "residential", "tertiary", "secondary", "primary", "trunk", "motorway", "rail")) {
    g <- pg[roads$cls == cl]
    if (length(g)) plot(g, add = TRUE, lwd = lwd_of(WIDTHS[[cl]]), col = "black")
  }
  clip(0, PAGE_W, 0, PAGE_H)
  # label knockout + text
  font_c <- file.path(root, "fonts", "Inter-700.ttf"); font_s <- file.path(root, "fonts", "Inter-600.ttf")
  cap_c <- 1.35; cap_s <- 0.42; trk_s <- 0.05
  max_w <- 0.42 * (x1 - x0)
  wc <- text_width(row$city, font_c, cap_c); if (wc > max_w) { cap_c <- cap_c * max_w / wc; wc <- max_w }
  ws <- text_width(row$state, font_s, cap_s, trk_s)
  pad <- 0.45; gap <- 0.32
  bx1 <- x0 + pad + max(wc, ws) + pad
  by1 <- y0 + pad + cap_s + gap + cap_c + pad
  rect(x0, y0, bx1, by1, col = "white", border = NA)
  draw_text(row$state, font_s, cap_s, x0 + pad, y0 + pad, trk_s)
  draw_text(row$city,  font_c, cap_c, x0 + pad, y0 + pad + cap_s + gap)
  # re-stroke the frame's inner edge so roads/box never nick it
  rect(FRAME_INSET, FRAME_INSET, PAGE_W - FRAME_INSET, PAGE_H - FRAME_INSET, border = "black", col = NA, lwd = 0)
}

f_pdf <- file.path(out_dir, paste0(slug, "_line.pdf"))
f_png <- file.path(out_dir, paste0(slug, "_line.png"))
f_jpg <- file.path(out_dir, paste0(slug, "_line_preview.jpg"))

message("PDF"); grDevices::pdf(f_pdf, width = PAGE_W, height = PAGE_H, useDingbats = FALSE, title = paste(row$city, "line map"))
draw_map(1); invisible(dev.off())
message("PNG"); ragg::agg_png(f_png, width = 12, height = 18, units = "in", res = 300, background = "white")
draw_map(0.5); invisible(dev.off())
message("JPG")
im <- magick::image_read(f_png)
im <- magick::image_resize(im, "1200x")
magick::image_write(im, f_jpg, format = "jpeg", quality = 90)
for (f in c(f_pdf, f_png, f_jpg)) message(f, "  ", round(file.size(f) / 1e6, 2), " MB")
