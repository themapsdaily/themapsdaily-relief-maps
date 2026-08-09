#!/usr/bin/env Rscript
# Stitch Assam boundary member ways -> largest polygon -> assam_boundary.gpkg.
suppressPackageStartupMessages({library(sf); library(jsonlite)})
sf::sf_use_s2(FALSE)
LAEA <- "+proj=laea +lat_0=26.0 +lon_0=92.8 +datum=WGS84 +units=m"
km2  <- function(g) as.numeric(sf::st_area(sf::st_transform(sf::st_geometry(g), LAEA))) / 1e6
j <- jsonlite::fromJSON("output/assam/as_boundary.json", simplifyVector = FALSE)
rel <- Filter(function(e) e$type == "relation", j$elements)[[1]]
mm <- Filter(function(m) m$type == "way" && !is.null(m$geometry), rel$members)
cat(sprintf("member ways with geom: %d\n", length(mm)))
lns <- lapply(mm, function(m)
  sf::st_linestring(do.call(rbind, lapply(m$geometry, function(p) c(p$lon, p$lat)))))
sl  <- sf::st_sfc(lns, crs = 4326)
u   <- sf::st_union(sl)
pp  <- sf::st_cast(sf::st_collection_extract(sf::st_polygonize(u), "POLYGON"), "POLYGON")
ar  <- km2(pp)
cat(sprintf("parts: %d | top areas km2: %s\n", length(ar),
            paste(round(head(sort(ar, decreasing = TRUE), 8)), collapse = ", ")))
big <- pp[which.max(ar)]
out <- sf::st_sf(name = "Assam", geometry = sf::st_make_valid(big))
sf::st_write(out, "output/assam/assam_boundary.gpkg", delete_dsn = TRUE, quiet = TRUE)
cat(sprintf("wrote: %d vertices, %.0f km2, bbox %s\n", nrow(sf::st_coordinates(out)),
            max(ar), paste(round(as.numeric(sf::st_bbox(out)), 4), collapse = " ")))
