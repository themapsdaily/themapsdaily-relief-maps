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
Rscript -e 'pkgs <- c("rayshader","rayrender","elevatr","sf","terra","raster","osmdata","rgl","magick","units","ragg");
            need <- setdiff(pkgs, rownames(installed.packages()));
            if (length(need)) install.packages(need, repos = "https://cloud.r-project.org", Ncpus = 4);
            miss <- setdiff(pkgs, rownames(installed.packages()));
            cat(if (length(miss)) paste("STILL MISSING:", paste(miss, collapse=", ")) else "ALL OK", "\n")'

echo "==> Pin rayshader 0.37.3 + rayimage 0.26.1 (held back on 2026-11-24)"
# rayshader 0.38+ / rayimage 0.27+ change render_state.R's output: shade matrices
# come back transposed, lamb_shade returns 0 instead of NA outside the state (so
# the exterior is no longer transparent) and height_shade's colours are darker.
# Every other package stays at the latest CRAN version.
Rscript -e 'want <- c(rayimage = "0.26.1", rayshader = "0.37.3");
            for (p in names(want)) if (!requireNamespace(p, quietly = TRUE) ||
                as.character(packageVersion(p)) != want[[p]]) {
              url <- sprintf("https://cran.r-project.org/src/contrib/Archive/%s/%s_%s.tar.gz", p, p, want[[p]]);
              f <- file.path(tempdir(), basename(url)); download.file(url, f, quiet = TRUE);
              install.packages(f, repos = NULL, type = "source") };
            cat("rayshader", as.character(packageVersion("rayshader")),
                "rayimage", as.character(packageVersion("rayimage")), "\n")'

echo "==> Done. Try:  Rscript render_state.R \"Uttarakhand\" 9 12"
