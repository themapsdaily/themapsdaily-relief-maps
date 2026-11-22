#!/usr/bin/env Rscript
# Parse raw Overpass waterway=river JSON -> clip to state -> length-filter ->
# output/chhattisgarh/chhattisgarh_rivers.gpkg (geometry-only is all export_dem.R needs).
suppressPackageStartupMessages({library(sf); library(jsonlite)})
sf::sf_use_s2(FALSE)
setwd(Sys.getenv("RELIEF_MAPS_ROOT", "."))
LAEA <- "+proj=laea +lat_0=21.0 +lon_0=82.3 +datum=WGS84 +units=m"

j  <- jsonlite::fromJSON("output/chhattisgarh/cg_rivers.json", simplifyVector = FALSE)
ws <- Filter(function(e) e$type == "way" && !is.null(e$geometry) && length(e$geometry) >= 2,
             j$elements)
cat(sprintf("ways with geometry: %d\n", length(ws)))
lns  <- lapply(ws, function(w)
  sf::st_linestring(do.call(rbind, lapply(w$geometry, function(p) c(p$lon, p$lat)))))
nm   <- vapply(ws, function(w) { n <- w$tags$name; if (is.null(n)) "" else n }, character(1))
r    <- sf::st_sf(name = nm, geometry = sf::st_sfc(lns, crs = 4326))

st <- sf::st_read("output/chhattisgarh/chhattisgarh_boundary.gpkg", quiet = TRUE)
r  <- suppressWarnings(sf::st_intersection(r, sf::st_geometry(st)))
r  <- r[sf::st_geometry_type(r) %in% c("LINESTRING", "MULTILINESTRING"), ]
r$km <- as.numeric(sf::st_length(sf::st_transform(r, LAEA))) / 1000
cat(sprintf("in-state river ways: %d, total %.0f km\n", nrow(r), sum(r$km)))

## The Mahanadi basin drains almost the whole state -- unfiltered the plateau
## renders as a blue web. Keep named systems totalling >= MIN_SYS km plus long
## unnamed ways (the standard big-state filter).
MIN_SYS <- as.numeric(Sys.getenv("MIN_SYS", "20"))
MIN_WAY <- as.numeric(Sys.getenv("MIN_WAY", "5"))
named <- r[nzchar(r$name), ]
tot   <- tapply(named$km, named$name, sum)
keep  <- names(tot)[tot >= MIN_SYS]
sel   <- (nzchar(r$name) & r$name %in% keep) | (!nzchar(r$name) & r$km >= MIN_WAY)
out   <- r[sel, ]
cat(sprintf("kept %d ways / %.0f km  (%d named systems >= %g km)\n",
            nrow(out), sum(out$km), length(keep), MIN_SYS))
cat("largest systems:\n"); print(round(head(sort(tot, decreasing = TRUE), 20)))
sf::st_write(sf::st_sf(geometry = sf::st_geometry(out)),
             "output/chhattisgarh/chhattisgarh_rivers.gpkg", delete_dsn = TRUE, quiet = TRUE)
cat("wrote chhattisgarh_rivers.gpkg\n")
