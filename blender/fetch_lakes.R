#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Fetch OSM water bodies (lakes / reservoirs) for a state and cache them as
# output/<slug>_lakes.gpkg. export_dem.R then rasterizes that to _lakes.png and
# relief.py paints it blue. Run from the relief-maps/ dir:
#   Rscript blender/fetch_lakes.R "Uttarakhand"
# ---------------------------------------------------------------------------
suppressPackageStartupMessages({ library(sf); library(osmdata) })

args  <- commandArgs(trailingOnly = TRUE)
state <- if (length(args) >= 1) args[[1]] else "Uttarakhand"
slug  <- gsub("\\s+", "_", tolower(state))
boundary <- Sys.getenv("RELIEF_BOUNDARY", "data/boundaries/india-2021.geojson")
outdir <- file.path("output", slug)                 # per-state subfolder
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

sel <- sf::st_read(boundary, quiet = TRUE); sel <- sel[sel$st_nm == state, ]
if (nrow(sel) == 0) stop("state not found: ", state)
sel <- sf::st_make_valid(sf::st_transform(sel, 4326))
bb  <- sf::st_bbox(sel)

message("fetching OSM natural=water for ", state, " ...")
q <- osmdata::opq(bbox = c(bb["xmin"], bb["ymin"], bb["xmax"], bb["ymax"]),
                  timeout = 180) |>
     osmdata::add_osm_feature(key = "natural", value = "water")
d <- osmdata::osmdata_sf(q)

gs <- list()
if (!is.null(d$osm_polygons) && nrow(d$osm_polygons) > 0)
  gs[[length(gs) + 1]] <- sf::st_geometry(d$osm_polygons)
if (!is.null(d$osm_multipolygons) && nrow(d$osm_multipolygons) > 0)
  gs[[length(gs) + 1]] <- sf::st_geometry(d$osm_multipolygons)
if (length(gs) == 0) stop("no water polygons returned")

w <- sf::st_make_valid(sf::st_sf(geometry = do.call(c, gs)))
w <- suppressWarnings(sf::st_intersection(w, sf::st_union(sel)))   # clip to state
w <- w[!sf::st_is_empty(w), ]
w$area_km2 <- as.numeric(sf::st_area(w)) / 1e6
w <- w[w$area_km2 >= 0.2, ]                                        # drop tiny ponds
if (nrow(w) == 0) stop("no water bodies >= 0.2 km2 after clip")

sf::st_write(w, file.path(outdir, paste0(slug, "_lakes.gpkg")),
             delete_dsn = TRUE, quiet = TRUE)
message(sprintf("wrote %s_lakes.gpkg (%d bodies, %.1f km2 total)",
                slug, nrow(w), sum(w$area_km2)))
