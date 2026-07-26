#!/usr/bin/env Rscript
# Stitch the OSM relation's member ways into a single high-detail polygon.
# st_node() chokes on large sfc in this build (see Maharashtra notes) -> union
# alone polygonizes fine because OSM member ways share exact endpoint coords.
suppressPackageStartupMessages({library(sf); library(jsonlite)})
sf::sf_use_s2(FALSE)
d   <- jsonlite::fromJSON("output/arunachal_pradesh/ap_boundary_raw.json",
                          simplifyVector = FALSE)
rel <- d$elements[[1]]
ways <- Filter(function(m) m$type == "way" && !is.null(m$geometry), rel$members)
message(sprintf("member ways with geometry: %d / %d", length(ways), length(rel$members)))
lns <- lapply(ways, function(w) {
  g <- do.call(rbind, lapply(w$geometry, function(p) c(p$lon, p$lat)))
  if (nrow(g) < 2) NULL else sf::st_linestring(g)
})
lns <- Filter(Negate(is.null), lns)
sfc <- sf::st_sfc(lns, crs = 4326)
message(sprintf("linestrings: %d  vertices: %d", length(sfc), nrow(sf::st_coordinates(sfc))))
poly <- sf::st_polygonize(sf::st_union(sfc))
poly <- sf::st_collection_extract(poly, "POLYGON")
poly <- sf::st_cast(poly, "POLYGON")
## keep the LARGEST part (drops stray fragments from unclosed side ways)
ar   <- as.numeric(sf::st_area(sf::st_transform(poly,
          "+proj=laea +lat_0=28 +lon_0=94.5 +units=m")))
message(sprintf("parts: %d  areas(km2): %s", length(poly),
                paste(round(sort(ar/1e6, decreasing = TRUE)[1:min(5,length(ar))]), collapse=", ")))
big  <- poly[which.max(ar)]
out  <- sf::st_sf(state = "Arunachal Pradesh", geometry = sf::st_sfc(big, crs = 4326))
out  <- sf::st_make_valid(out)
a_km2 <- as.numeric(sf::st_area(sf::st_transform(out,
           "+proj=laea +lat_0=28 +lon_0=94.5 +units=m"))) / 1e6
bb <- sf::st_bbox(out)
message(sprintf("FINAL vertices: %d  area: %.0f km2 (official 83,743)",
                nrow(sf::st_coordinates(out)), a_km2))
message(sprintf("bbox: %.4f %.4f %.4f %.4f", bb[1], bb[2], bb[3], bb[4]))
sf::st_write(out, "output/arunachal_pradesh/arunachal_pradesh_boundary.gpkg",
             delete_dsn = TRUE, quiet = TRUE)
message("wrote arunachal_pradesh_boundary.gpkg")
