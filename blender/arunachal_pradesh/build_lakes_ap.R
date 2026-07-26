#!/usr/bin/env Rscript
# Clip the merged OSM water polygons to the state, report the size distribution,
# and area-filter. Arunachal has no large natural lakes -- the value of this
# layer is the WIDE braided channels of the Siang/Brahmaputra, Dibang and Lohit,
# which natural=water carries as river areas.
suppressPackageStartupMessages({library(sf)})
sf::sf_use_s2(FALSE)                                    # OSM water rings self-intersect
pr <- "+proj=laea +lat_0=28 +lon_0=94.5 +units=m"
w  <- sf::st_read("output/arunachal_pradesh/ap_lakes_merged.geojson", quiet=TRUE)
st <- sf::st_read("output/arunachal_pradesh/arunachal_pradesh_boundary.gpkg", quiet=TRUE)
w  <- sf::st_make_valid(w)
wi <- suppressWarnings(sf::st_intersection(w, sf::st_geometry(st)))
wi <- wi[!sf::st_is_empty(wi), ]
wi$area_km2 <- as.numeric(sf::st_area(sf::st_transform(wi, pr)))/1e6
wi <- wi[order(-wi$area_km2), ]
cat(sprintf("clipped water polygons: %d  total %.1f km2\n", nrow(wi), sum(wi$area_km2)))
cat("\nsize distribution (km2):\n")
print(round(quantile(wi$area_km2, c(.5,.75,.9,.95,.99,1)), 3))
for (t in c(0.05,0.1,0.2,0.5,1,2,5)) cat(sprintf("  >= %5.2f km2 : %4d polys, %7.1f km2\n",
    t, sum(wi$area_km2>=t), sum(wi$area_km2[wi$area_km2>=t])))
cat("\ntop 20 by area:\n")
top <- head(sf::st_drop_geometry(wi)[,c("name","water","area_km2")], 20)
print(top, row.names=FALSE)
cat("\nNAMED water bodies >= 0.05 km2:\n")
nm <- wi[nzchar(wi$name) & wi$area_km2 >= 0.05, ]
if (nrow(nm)) {
  ct <- sf::st_coordinates(sf::st_centroid(sf::st_geometry(nm)))
  for (i in seq_len(nrow(nm)))
    cat(sprintf("  %-34s %7.3f km2  at %.4f, %.4f\n", nm$name[i], nm$area_km2[i], ct[i,2], ct[i,1]))
} else cat("  (none)\n")
thr <- as.numeric(Sys.getenv("LAKE_MIN_KM2", "0.05"))
out <- wi[wi$area_km2 >= thr, ]
out <- sf::st_sf(geometry = sf::st_geometry(out))
sf::st_write(out, "output/arunachal_pradesh/arunachal_pradesh_lakes.gpkg", delete_dsn=TRUE, quiet=TRUE)
cat(sprintf("\nwrote arunachal_pradesh_lakes.gpkg (%d polys >= %.2f km2)\n", nrow(out), thr))
