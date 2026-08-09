#!/usr/bin/env bash
# Orchestrate the whole Assam data fetch+build, in order, from relief-maps/.
# Idempotent-ish: skips a step if its final gpkg already exists.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1   # -> relief-maps/
echo "############ [1/3] BOUNDARY ############"
if [ ! -f output/assam/assam_boundary.gpkg ]; then
  bash blender/assam/fetch_boundary_as.sh || { echo "BOUNDARY FETCH FAILED"; exit 1; }
  Rscript blender/assam/build_boundary_as.R || { echo "BOUNDARY BUILD FAILED"; exit 1; }
else echo "reuse assam_boundary.gpkg"; fi

echo "############ [2/3] RIVERS ############"
if [ ! -f output/assam/assam_rivers.gpkg ]; then
  bash blender/assam/fetch_rivers_as.sh || { echo "RIVERS FETCH FAILED"; exit 1; }
  Rscript blender/assam/build_rivers_as.R || { echo "RIVERS BUILD FAILED"; exit 1; }
else echo "reuse assam_rivers.gpkg"; fi

echo "############ [3/3] WATER (Brahmaputra + beels) ############"
if [ ! -f output/assam/assam_lakes.gpkg ]; then
  bash blender/assam/fetch_water_as.sh || { echo "WATER FETCH FAILED"; exit 1; }
  Rscript blender/assam/build_water_as.R || { echo "WATER BUILD FAILED"; exit 1; }
else echo "reuse assam_lakes.gpkg"; fi

echo "############ DATA READY ############"
ls -la output/assam/*.gpkg
