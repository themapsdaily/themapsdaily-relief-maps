#!/usr/bin/env Rscript
# Clip the merged OSM rivers to the state and LENGTH-FILTER them.
# Arunachal is the wettest state in the Himalaya, so an unfiltered waterway=river
# layer renders as a solid blue web over the forest. Keep named systems whose
# total length is significant, plus long unnamed trunk ways.
suppressPackageStartupMessages({library(sf)})
sf::sf_use_s2(FALSE)
r <- sf::st_read("output/arunachal_pradesh/ap_rivers_merged.geojson", quiet = TRUE)
st <- sf::st_read("output/arunachal_pradesh/arunachal_pradesh_boundary.gpkg", quiet = TRUE)
r <- sf::st_make_valid(r)
ri <- suppressWarnings(sf::st_intersection(r, sf::st_geometry(st)))
ri <- ri[!sf::st_is_empty(ri), ]
ri <- suppressWarnings(sf::st_cast(ri, "LINESTRING"))
ri$len_km <- as.numeric(sf::st_length(sf::st_transform(ri,
              "+proj=laea +lat_0=28 +lon_0=94.5 +units=m"))) / 1000
cat(sprintf("clipped ways: %d  total %.0f km\n", nrow(ri), sum(ri$len_km)))
## named-system totals
nm <- ri[nzchar(ri$name), ]
agg <- aggregate(len_km ~ name, data = sf::st_drop_geometry(nm), FUN = sum)
agg <- agg[order(-agg$len_km), ]
cat("\ntop named systems (km):\n"); print(head(agg, 22), row.names = FALSE)
cat(sprintf("\nnamed ways: %d (%.0f km) | unnamed: %d (%.0f km)\n",
            nrow(nm), sum(nm$len_km), sum(!nzchar(ri$name)),
            sum(ri$len_km[!nzchar(ri$name)])))
cat("\nunnamed way length distribution:\n")
print(round(quantile(ri$len_km[!nzchar(ri$name)], c(.25,.5,.75,.9,.95,.99,1)), 2))
## FILTER: named systems >= NAMED_MIN km total, unnamed ways >= UNNAMED_MIN km
named_min   <- as.numeric(Sys.getenv("NAMED_MIN", "20"))
unnamed_min <- as.numeric(Sys.getenv("UNNAMED_MIN", "6"))
keep_names <- agg$name[agg$len_km >= named_min]
keep <- (ri$name %in% keep_names) | (!nzchar(ri$name) & ri$len_km >= unnamed_min)
out <- ri[keep, ]
cat(sprintf("\nFILTER named>=%.0fkm (%d systems) + unnamed>=%.0fkm -> %d ways / %.0f km\n",
            named_min, length(keep_names), unnamed_min, nrow(out), sum(out$len_km)))
out <- sf::st_sf(geometry = sf::st_geometry(out))   # geometry-only is all export_dem.R needs
sf::st_write(out, "output/arunachal_pradesh/arunachal_pradesh_rivers.gpkg",
             delete_dsn = TRUE, quiet = TRUE)
cat("wrote arunachal_pradesh_rivers.gpkg\n")
