#!/usr/bin/env Rscript
# Void diagnostics + local-outlier profile + hypsometry for the Chhattisgarh DEM.
# Decides clamp-vs-despike and gives the palette its measured elevation bands.
suppressPackageStartupMessages({library(terra)})
setwd("/Users/siddharthpetare/projects/themapsdaily-relief-maps")
f <- Sys.getenv("DEMFILE", "output/chhattisgarh/chhattisgarh_dem_z10.tif")
d <- terra::rast(f)
v <- terra::values(d, mat = FALSE)
v <- v[!is.na(v)]
cat(sprintf("cells (non-NA): %d\n", length(v)))
cat(sprintf("range: %.0f .. %.0f m\n", min(v), max(v)))
cat("--- low tail ---\n")
for (t in c(0, 20, 40, 60, 70, 80, 100)) cat(sprintf("  cells < %4d m: %8d (%.5f%%)\n", t, sum(v < t), 100*sum(v < t)/length(v)))
cat("low percentiles: \n"); print(round(quantile(v, c(1e-5, 1e-4, 1e-3, 0.0001, 0.001, 0.01, 0.05))))
cat("high percentiles: \n"); print(round(quantile(v, c(0.95, 0.99, 0.999, 0.9999, 0.99999, 1))))

cat("\n--- local-outlier profile (|dem - focal median 5x5|) ---\n")
med <- terra::focal(d, w = 5, fun = "median", na.rm = TRUE)
dv  <- abs(d - med)
q   <- terra::global(dv, fun = function(x) quantile(x, c(0.99, 0.999, 0.9999, 0.99999, 1), na.rm = TRUE))
print(round(q, 1))

cat("\n--- hypsometry (100 m bands) ---\n")
br <- seq(floor(min(v)/100)*100, ceiling(max(v)/100)*100, by = 100)
h  <- table(cut(v, br))
pc <- round(100 * as.numeric(h) / length(v), 2)
for (i in seq_along(pc)) if (pc[i] > 0) cat(sprintf("  %s : %6.2f%%\n", names(h)[i], pc[i]))
