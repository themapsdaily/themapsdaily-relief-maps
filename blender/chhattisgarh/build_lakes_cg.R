#!/usr/bin/env Rscript
# Merge the reservoir TILES -> de-dupe by OSM id (tiles overlap) -> polygonize ->
# clip to state -> area-filter -> output/chhattisgarh/chhattisgarh_lakes.gpkg.
# Refuses to build from a partial set: a failed tile still writes a file, so the
# tiles are validated by PARSING, never by counting files.
suppressPackageStartupMessages({library(sf); library(jsonlite)})
sf::sf_use_s2(FALSE)   # OSM water rings self-intersect
LAEA <- "+proj=laea +lat_0=21.0 +lon_0=82.3 +datum=WGS84 +units=m"
km2  <- function(g) as.numeric(sf::st_area(sf::st_transform(sf::st_geometry(g), LAEA))) / 1e6
setwd(Sys.getenv("RELIEF_MAPS_ROOT", "."))
st <- sf::st_read("output/chhattisgarh/chhattisgarh_boundary.gpkg", quiet = TRUE)

tiles <- sort(Sys.glob("output/chhattisgarh/lake_tiles/tile_*.json"))
NEXP  <- as.integer(Sys.getenv("N_TILES", "6"))
if (length(tiles) < NEXP) stop(sprintf("only %d/%d tiles present", length(tiles), NEXP))
els <- list()
for (f in tiles) {
  j <- try(jsonlite::fromJSON(f, simplifyVector = FALSE), silent = TRUE)
  if (inherits(j, "try-error") || is.null(j$elements))
    stop(sprintf("tile %s is not valid JSON (HTML error page?) -- refusing partial layer", f))
  cat(sprintf("  %s: %d elements\n", basename(f), length(j$elements)))
  els <- c(els, j$elements)
}
ids <- vapply(els, function(e) paste0(e$type, "/", e$id), character(1))
els <- els[!duplicated(ids)]
cat(sprintf("total %d elements, %d unique after de-dupe\n", length(ids), length(els)))

nmof <- function(e) { n <- e$tags$name; if (is.null(n)) "" else n }
ring <- function(geom) do.call(rbind, lapply(geom, function(p) c(p$lon, p$lat)))

ws <- Filter(function(e) e$type == "way" && !is.null(e$geometry) && length(e$geometry) >= 4, els)
wp <- lapply(ws, function(w) { r <- ring(w$geometry)
  if (!identical(r[1, ], r[nrow(r), ])) r <- rbind(r, r[1, ])
  sf::st_polygon(list(r)) })
wsf <- sf::st_sf(name = vapply(ws, nmof, character(1)), geometry = sf::st_sfc(wp, crs = 4326))

rs <- Filter(function(e) e$type == "relation" && !is.null(e$members), els)
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
## ~4.5 render px/km at 3200 -> a 2.5 km2 body is ~7 px across, about the floor
## for something that reads as water rather than a speck.
MIN <- as.numeric(Sys.getenv("LAKE_MIN_KM2", "2.5"))
big <- all[!is.na(all$km2) & all$km2 >= MIN, ]
big <- big[order(-big$km2), ]
cat(sprintf("kept %d bodies >= %.2f km2 (total %.1f km2)\n", nrow(big), MIN, sum(big$km2)))
print(utils::head(sf::st_drop_geometry(big), 25))
sf::st_write(big["name"], "output/chhattisgarh/chhattisgarh_lakes.gpkg", delete_dsn = TRUE, quiet = TRUE)
cat("wrote chhattisgarh_lakes.gpkg\n")
