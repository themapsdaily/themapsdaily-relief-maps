#!/usr/bin/env Rscript
# Parse raw Overpass natural=water JSON (ways + relations) -> clip to state ->
# area-filter -> output/meghalaya/meghalaya_lakes.gpkg.
suppressPackageStartupMessages({library(sf); library(jsonlite)})
sf::sf_use_s2(FALSE)   # OSM water rings self-intersect
LAEA <- "+proj=laea +lat_0=25.6 +lon_0=91.3 +datum=WGS84 +units=m"
km2 <- function(g) as.numeric(sf::st_area(sf::st_transform(sf::st_geometry(g), LAEA))) / 1e6
setwd("/Users/siddharthpetare/projects/themapsdaily-relief-maps")
st <- sf::st_read("output/meghalaya/meghalaya_boundary.gpkg", quiet = TRUE)

j <- jsonlite::fromJSON("output/meghalaya/ml_lakes.json", simplifyVector = FALSE)
nmof <- function(e) { n <- e$tags$name; if (is.null(n)) "" else n }
ring <- function(geom) do.call(rbind, lapply(geom, function(p) c(p$lon, p$lat)))

ws <- Filter(function(e) e$type == "way" && !is.null(e$geometry) && length(e$geometry) >= 4,
             j$elements)
wp <- lapply(ws, function(w) { r <- ring(w$geometry)
  if (!identical(r[1, ], r[nrow(r), ])) r <- rbind(r, r[1, ])
  sf::st_polygon(list(r)) })
wsf <- sf::st_sf(name = vapply(ws, nmof, character(1)),
                 geometry = sf::st_sfc(wp, crs = 4326))

rs <- Filter(function(e) e$type == "relation", j$elements)
rp <- lapply(rs, function(rel) {
  mm <- Filter(function(m) m$type == "way" && !is.null(m$geometry) &&
                 (is.null(m$role) || m$role %in% c("outer", "")), rel$members)
  if (length(mm) == 0) return(NULL)
  lns <- lapply(mm, function(m) sf::st_linestring(ring(m$geometry)))
  g <- try(suppressWarnings(sf::st_collection_extract(
    sf::st_polygonize(sf::st_union(sf::st_sfc(lns, crs = 4326))), "POLYGON")), silent = TRUE)
  if (inherits(g, "try-error") || length(g) == 0) return(NULL)
  sf::st_sf(name = nmof(rel), geometry = sf::st_cast(g, "POLYGON"))
})
rp <- do.call(rbind, Filter(Negate(is.null), rp))
cat(sprintf("way polys %d | relation polys %d\n", nrow(wsf), if (is.null(rp)) 0 else nrow(rp)))

all <- if (is.null(rp)) wsf else rbind(wsf, sf::st_sf(name = rp$name, geometry = sf::st_geometry(rp)))
all <- sf::st_make_valid(all)
all <- all[sf::st_geometry_type(all) %in% c("POLYGON", "MULTIPOLYGON"), ]
all <- suppressWarnings(sf::st_intersection(all, sf::st_geometry(st)))
all$km2 <- km2(all)
## Meghalaya is ~299 km wide at ~10.7 render px/km. Umiam is the only body that
## really reads; keep >= 0.4 km2 so quarry ponds and paddy tanks don't speckle it.
MIN <- as.numeric(Sys.getenv("LAKE_MIN_KM2", "0.4"))
big <- all[!is.na(all$km2) & all$km2 >= MIN, ]
big <- big[order(-big$km2), ]
cat(sprintf("kept %d bodies >= %.2f km2 (total %.1f km2)\n", nrow(big), MIN, sum(big$km2)))
print(utils::head(sf::st_drop_geometry(big), 20))
sf::st_write(big["name"], "output/meghalaya/meghalaya_lakes.gpkg", delete_dsn = TRUE, quiet = TRUE)
cat("wrote meghalaya_lakes.gpkg\n")
