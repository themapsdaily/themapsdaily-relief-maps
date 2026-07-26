#!/usr/bin/env Rscript
# Fetch OSM rivers (waterway=river) for a state -> output/<slug>_rivers.gpkg.
# export_dem.R rasterizes it to _rivers.png; relief.py paints it muted blue.
#   Rscript blender/fetch_rivers.R "Goa"
# Set OVERPASS_URL to use a faster mirror (the default endpoint is often queued).
suppressPackageStartupMessages({ library(sf); library(osmdata) })
ou <- Sys.getenv("OVERPASS_URL", "")
if (nzchar(ou)) osmdata::set_overpass_url(ou)

args  <- commandArgs(trailingOnly = TRUE)
state <- if (length(args) >= 1) args[[1]] else "Goa"
slug  <- gsub("\\s+", "_", tolower(state))
boundary <- Sys.getenv("RELIEF_BOUNDARY", "data/boundaries/india-2021.geojson")
outdir <- file.path("output", slug); dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

sel <- sf::st_read(boundary, quiet = TRUE); sel <- sel[sel$st_nm == state, ]
if (nrow(sel) == 0) stop("state not found: ", state)
sel <- sf::st_make_valid(sf::st_transform(sel, 4326)); bb <- sf::st_bbox(sel)

message("fetching OSM waterway=river for ", state, " via ", if (nzchar(ou)) ou else "default ...")
q <- osmdata::opq(bbox = c(bb["xmin"], bb["ymin"], bb["xmax"], bb["ymax"]), timeout = 120) |>
     osmdata::add_osm_feature(key = "waterway", value = "river")
d <- osmdata::osmdata_sf(q)

gs <- list()
if (!is.null(d$osm_lines) && nrow(d$osm_lines) > 0) gs[[length(gs)+1]] <- sf::st_geometry(d$osm_lines)
if (!is.null(d$osm_multilines) && nrow(d$osm_multilines) > 0) gs[[length(gs)+1]] <- sf::st_geometry(d$osm_multilines)
if (length(gs) == 0) stop("no river lines returned")

r <- sf::st_sf(geometry = do.call(c, gs))
r <- suppressWarnings(sf::st_intersection(r, sf::st_union(sel)))
r <- r[!sf::st_is_empty(r), ]
if (nrow(r) == 0) stop("no rivers after clip")
sf::st_write(r, file.path(outdir, paste0(slug, "_rivers.gpkg")), delete_dsn = TRUE, quiet = TRUE)
message(sprintf("wrote %s_rivers.gpkg (%d line features)", slug, nrow(r)))
