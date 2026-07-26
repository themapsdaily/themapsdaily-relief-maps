#!/usr/bin/env Rscript
# Where is the high ground, really? Cluster every cell above a threshold and
# report each cluster's summit, so peak labels are attributed to measured
# terrain instead of to published coordinates of uncertain provenance.
suppressPackageStartupMessages({library(terra)})
setwd("/Users/siddharthpetare/projects/themapsdaily-relief-maps")
d  <- terra::rast("output/chhattisgarh/chhattisgarh_dem_z10.tif")
TH <- as.numeric(Sys.getenv("TH", "1050"))
hi <- terra::ifel(d >= TH, 1, NA)
p  <- terra::patches(hi, directions = 8, zeroAsNA = TRUE)
cat(sprintf("threshold %.0f m\n", TH))
z  <- terra::zonal(d, p, fun = "max", na.rm = TRUE)
a  <- terra::zonal(terra::cellSize(d, unit = "km"), p, fun = "sum", na.rm = TRUE)
names(z) <- c("patch", "max_m"); names(a) <- c("patch", "km2")
m  <- merge(z, a, by = "patch")
m  <- m[order(-m$max_m), ]
m  <- m[m$km2 >= as.numeric(Sys.getenv("MIN_KM2", "1")), ]
cat(sprintf("clusters >= %s km2: %d\n\n", Sys.getenv("MIN_KM2", "1"), nrow(m)))
for (i in seq_len(min(nrow(m), 14))) {
  pid <- m$patch[i]
  msk <- terra::ifel(p == pid, d, NA)
  w   <- terra::where.max(msk)
  xy  <- terra::xyFromCell(msk, w[1, "cell"])
  cat(sprintf("  %2d. %.4f N %.4f E  %4.0f m  area %6.1f km2\n",
              i, xy[2], xy[1], m$max_m[i], m$km2[i]))
}
