#!/usr/bin/env Rscript
# Find the true DEM summit near each named peak. Radius is deliberately TIGHT
# (r=0.02 deg): Maharashtra showed r=0.06 wanders onto a neighbouring summit
# (Kalsubai drifted 4.1 km). Also reports the state-wide DEM maximum so the
# palette's top stop can be attributed to a real place.
suppressPackageStartupMessages({library(terra)})
setwd("/Users/siddharthpetare/projects/themapsdaily-relief-maps")
d <- terra::rast("output/chhattisgarh/chhattisgarh_dem_z10.tif")

cat("=== state-wide DEM maximum ===\n")
mx <- terra::where.max(d)
xy <- terra::xyFromCell(d, mx[1, "cell"])
cat(sprintf("  %.4f N, %.4f E  = %.0f m\n", xy[2], xy[1], mx[1, "value"]))

## candidates: published/approximate positions, snapped below
cand <- data.frame(
  name = c("Gaurlata", "Bailadila", "Mainpat", "Jashpur Hills", "Chhuri Hills", "Maikal Range"),
  lat  = c(23.1500, 18.6700, 22.8500, 22.8800, 22.3000, 22.1000),
  long = c(83.6500, 81.2300, 83.1000, 84.1000, 82.4000, 81.2000)
)
R <- as.numeric(Sys.getenv("SNAP_R", "0.02"))
cat(sprintf("\n=== snapped summits (r = %.3f deg) ===\n", R))
for (i in seq_len(nrow(cand))) {
  e <- terra::ext(cand$long[i] - R, cand$long[i] + R, cand$lat[i] - R, cand$lat[i] + R)
  s <- try(terra::crop(d, e), silent = TRUE)
  if (inherits(s, "try-error") || all(is.na(terra::values(s)))) {
    cat(sprintf("  %-15s OUTSIDE / no data\n", cand$name[i])); next
  }
  w  <- terra::where.max(s)
  p  <- terra::xyFromCell(s, w[1, "cell"])
  dk <- sqrt(((p[1]-cand$long[i])*111.32*cos(cand$lat[i]*pi/180))^2 + ((p[2]-cand$lat[i])*110.57)^2)
  cat(sprintf("  %-15s %.4f N %.4f E  %.0f m   (moved %.1f km)\n",
              cand$name[i], p[2], p[1], w[1, "value"], dk))
}
