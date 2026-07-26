#!/usr/bin/env bash
# One-time setup for the relief-map renderer.
set -euo pipefail

echo "==> System libraries"
# R + geospatial stack (gdal/geos/proj) + the ones the R packages compile against:
#   udunits    -> units -> sf
#   imagemagick-> magick (Magick++)
#   cmake      -> libimath/libopenexr -> rayrender
brew install r gdal geos proj udunits imagemagick cmake pkg-config

echo "==> R packages (compiles rayshader/sf/rayrender from source; takes a while)"
# Export include/lib paths so sf finds proj.h and units finds udunits2.
export PKG_CONFIG_PATH="/opt/homebrew/opt/proj/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"
export CPPFLAGS="-I/opt/homebrew/include"
export LDFLAGS="-L/opt/homebrew/lib"
Rscript -e 'pkgs <- c("rayshader","rayrender","elevatr","sf","terra","raster","osmdata","rgl","magick","units");
            need <- setdiff(pkgs, rownames(installed.packages()));
            if (length(need)) install.packages(need, repos = "https://cloud.r-project.org", Ncpus = 4);
            miss <- setdiff(pkgs, rownames(installed.packages()));
            cat(if (length(miss)) paste("STILL MISSING:", paste(miss, collapse=", ")) else "ALL OK", "\n")'

echo "==> Done. Try:  Rscript render_state.R \"Uttarakhand\" 9 12"
