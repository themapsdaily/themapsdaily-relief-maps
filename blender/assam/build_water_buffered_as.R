#!/usr/bin/env Rscript
# Assam water layer WITHOUT the heavy OSM water-polygon relations (they time out
# on Overpass because the Brahmaputra is one giant multipolygon). Instead build
# the signature wide channels by BUFFERING the river centerlines from the raw
# waterway=river dump: the Brahmaputra gets a fat buffer (it is 5-10 km wide and
# braided across the valley), the Barak a moderate one. Tributaries stay thin in
# the separate rivers layer. Optionally unions in any beel polygons already saved
# to output/assam/assam_beels.gpkg. -> output/assam/assam_lakes.gpkg (blue fill).
suppressPackageStartupMessages({library(sf); library(jsonlite)})
sf::sf_use_s2(FALSE)
LAEA <- "+proj=laea +lat_0=26.0 +lon_0=92.8 +datum=WGS84 +units=m"

BRAHMA_HALF <- as.numeric(Sys.getenv("BRAHMA_HALF_M", "2800"))   # half-width metres
BARAK_HALF  <- as.numeric(Sys.getenv("BARAK_HALF_M",  "550"))

j  <- jsonlite::fromJSON("output/assam/as_rivers.json", simplifyVector = FALSE)
ws <- Filter(function(e) e$type == "way" && !is.null(e$geometry) && length(e$geometry) >= 2,
             j$elements)
nm <- vapply(ws, function(w) { n <- w$tags$name; if (is.null(n)) "" else n }, character(1))
nm <- iconv(nm, from = "UTF-8", to = "ASCII//TRANSLIT"); nm[is.na(nm)] <- ""   # barāk -> barak
mk_lines <- function(idx) {
  if (!length(idx)) return(NULL)
  lns <- lapply(ws[idx], function(w)
    sf::st_linestring(do.call(rbind, lapply(w$geometry, function(p) c(p$lon, p$lat)))))
  sf::st_sfc(lns, crs = 4326)
}
is_brahma <- grepl("brahmaputra", nm, ignore.case = TRUE)
is_barak  <- grepl("barak", nm, ignore.case = TRUE)
cat(sprintf("brahmaputra ways: %d | barak ways: %d\n", sum(is_brahma), sum(is_barak)))

st <- sf::st_read("output/assam/assam_boundary.gpkg", quiet = TRUE)
buf_to_poly <- function(sfc, half_m) {
  if (is.null(sfc)) return(NULL)
  b <- sf::st_buffer(sf::st_transform(sfc, LAEA), half_m)
  sf::st_transform(sf::st_union(b), 4326)
}
polys <- list()
pb <- buf_to_poly(mk_lines(which(is_brahma)), BRAHMA_HALF); if (!is.null(pb)) polys[["Brahmaputra"]] <- pb
pk <- buf_to_poly(mk_lines(which(is_barak)),  BARAK_HALF);  if (!is.null(pk)) polys[["Barak"]] <- pk

geoms <- do.call(c, unname(polys))
w <- sf::st_sf(name = names(polys), geometry = geoms)
w <- sf::st_make_valid(w)
w <- suppressWarnings(sf::st_intersection(w, sf::st_geometry(st)))   # clip to state

## fold in any pre-fetched beel/lake polygons if present
beels <- "output/assam/assam_beels.gpkg"
if (file.exists(beels)) {
  bl <- sf::st_read(beels, quiet = TRUE)
  bl <- sf::st_transform(sf::st_make_valid(bl), 4326)
  if (!"name" %in% names(bl)) bl$name <- ""
  w <- rbind(w[, "name"], bl[, "name"])
  cat(sprintf("merged %d beel/lake polygons\n", nrow(bl)))
}
w$km2 <- as.numeric(sf::st_area(sf::st_transform(sf::st_geometry(w), LAEA))) / 1e6
cat(sprintf("water bodies: %d (total %.0f km2)\n", nrow(w), sum(w$km2)))
print(sf::st_drop_geometry(w))
sf::st_write(w["name"], "output/assam/assam_lakes.gpkg", delete_dsn = TRUE, quiet = TRUE)
cat("wrote assam_lakes.gpkg\n")
