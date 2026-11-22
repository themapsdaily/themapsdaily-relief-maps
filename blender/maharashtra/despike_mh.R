#!/usr/bin/env Rscript
# Despike the cached Maharashtra DEM in place (Kerala recipe, generalised).
# elevatr terrain tiles carry void CLUSTERS here (a 2158 m spike sitting next to
# -427 m cells) which stretch the 0..1 normalization and wash the palette: the
# state's real top is ~1540 m at z9, so a 2158 m outlier throws away a quarter of
# the ramp. Real terrain deviates <160 m from its 5x5 median even on the Western
# Ghats escarpment (99.99th pct), while the void tail runs to 1585 m -> replace
# only cells beyond 200 m with the local median. 265 of 14.6M cells.
suppressPackageStartupMessages({library(terra); library(sf)})
sf::sf_use_s2(FALSE); terra::terraOptions(memfrac = 0.6)
setwd(Sys.getenv("RELIEF_MAPS_ROOT", "."))
f  <- "output/maharashtra/maharashtra_dem_z9_sea.tif"
d  <- terra::rast(f)
st <- terra::vect("output/maharashtra/maharashtra_boundary.gpkg")
med <- terra::rast("/private/tmp/claude-501/-Users-siddharthpetare-projects-themapsdaily-web/7cc03767-2f6c-4459-9995-30a79111005b/scratchpad/mh_med5.tif")
THR <- 200
bad <- abs(d - med) > THR
n <- terra::global(bad, "sum", na.rm = TRUE)[1, 1]
cat(sprintf("despiking %d cells (|dev| > %d m)\n", n, THR))
fixed <- terra::ifel(bad, med, d)
terra::writeRaster(fixed, f, overwrite = TRUE, datatype = "FLT4S")
mm <- terra::mask(terra::rast(f), st)
v <- terra::values(mm); v <- v[!is.na(v)]
cat(sprintf("after despike, in-state elev: %.0f .. %.0f m\n", min(v), max(v)))
cat("top cells:\n")
print(round(sort(v, decreasing = TRUE)[1:8]))
