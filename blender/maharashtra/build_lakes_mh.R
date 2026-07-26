#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(sf)})
# OSM water rings self-intersect; s2 rejects them outright, and with s2 off
# st_area() wants lwgeom. Do areas in an equal-area projection instead.
sf::sf_use_s2(FALSE)
LAEA <- "+proj=laea +lat_0=19 +lon_0=76.7 +datum=WGS84 +units=m"
km2 <- function(g) as.numeric(sf::st_area(sf::st_transform(sf::st_geometry(g), LAEA))) / 1e6
setwd("/Users/siddharthpetare/projects/themapsdaily-relief-maps")
st <- sf::st_read("output/maharashtra/maharashtra_boundary.gpkg", quiet = TRUE)

w  <- sf::st_read("output/maharashtra/mh_water_ways.geojson", quiet = TRUE)
w  <- sf::st_make_valid(w); w <- w[!sf::st_is_empty(w), ]
rl <- suppressWarnings(sf::st_read("output/maharashtra/mh_water_rellines.geojson", quiet = TRUE))
cat(sprintf("way polys %d | relation lines %d over %d relations\n",
            nrow(w), nrow(rl), length(unique(rl$rid))))

rp <- lapply(split(seq_len(nrow(rl)), rl$rid), function(ix) {
  g <- try(suppressWarnings(sf::st_collection_extract(
    sf::st_polygonize(sf::st_union(sf::st_geometry(rl[ix, ]))), "POLYGON")), silent = TRUE)
  if (inherits(g, "try-error") || length(g) == 0) return(NULL)
  sf::st_sf(name = rl$name[ix[1]], geometry = sf::st_cast(g, "POLYGON"))
})
rp <- do.call(rbind, Filter(Negate(is.null), rp))
cat(sprintf("relation polys: %d\n", nrow(rp)))

all <- rbind(sf::st_sf(name = w$name, geometry = sf::st_geometry(w)),
             sf::st_sf(name = rp$name, geometry = sf::st_geometry(rp)))
all <- sf::st_make_valid(all)
all <- all[sf::st_geometry_type(all) %in% c("POLYGON", "MULTIPOLYGON"), ]
all$km2 <- km2(all)
## Maharashtra spans ~955 km at ~2.9 render px/km, so anything under ~3 km2 is a
## couple of pixels -> keep the big reservoirs, drop the farm-pond clutter.
MIN <- as.numeric(Sys.getenv("LAKE_MIN_KM2", "3"))
big <- all[!is.na(all$km2) & all$km2 >= MIN, ]
big <- suppressWarnings(sf::st_intersection(big, sf::st_geometry(st)))
big$km2 <- km2(big)
big <- big[big$km2 >= MIN * 0.5, ]
big <- big[order(-big$km2), ]
cat(sprintf("kept %d bodies >= %.1f km2 (total %.0f km2)\n", nrow(big), MIN, sum(big$km2)))
print(utils::head(sf::st_drop_geometry(big), 30))
sf::st_write(big["name"], "output/maharashtra/maharashtra_lakes.gpkg",
             delete_dsn = TRUE, quiet = TRUE)
cat("wrote maharashtra_lakes.gpkg\n")
