suppressPackageStartupMessages({library(sf)})
sf::sf_use_s2(FALSE)
setwd(Sys.getenv("RELIEF_MAPS_ROOT", "."))
LAEA <- "+proj=laea +lat_0=19 +lon_0=76.7 +datum=WGS84 +units=m"
r  <- sf::st_read("output/maharashtra/mh_rivers_merged.geojson", quiet = TRUE)
st <- sf::st_read("output/maharashtra/maharashtra_boundary.gpkg", quiet = TRUE)
r  <- suppressWarnings(sf::st_intersection(r, sf::st_geometry(st)))
r  <- r[sf::st_geometry_type(r) %in% c("LINESTRING","MULTILINESTRING"), ]
rp <- sf::st_transform(r, LAEA)
r$km <- as.numeric(sf::st_length(rp))/1000
cat(sprintf("in-state river ways: %d, total %.0f km\n", nrow(r), sum(r$km)))
## Maharashtra's OSM network is dense enough that drawing every tagged "river"
## turns the plateau into a blue web at this scale. Keep the real rivers: any
## NAMED system whose segments total >= MIN_SYS km, plus long unnamed ways.
MIN_SYS <- 25; MIN_WAY <- 6
named <- r[nzchar(r$name), ]
tot <- tapply(named$km, named$name, sum)
keep_names <- names(tot)[tot >= MIN_SYS]
sel <- (nzchar(r$name) & r$name %in% keep_names) | (!nzchar(r$name) & r$km >= MIN_WAY)
out <- r[sel, ]
cat(sprintf("kept %d ways / %.0f km  (%d named systems >= %d km)\n",
            nrow(out), sum(out$km), length(keep_names), MIN_SYS))
cat("largest systems:\n")
print(round(head(sort(tot, decreasing = TRUE), 18)))
sf::st_write(sf::st_sf(geometry = sf::st_geometry(out)),
             "output/maharashtra/maharashtra_rivers.gpkg", delete_dsn = TRUE, quiet = TRUE)
cat("wrote maharashtra_rivers.gpkg\n")
