#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-command Blender relief render for a state.
#
#   blender/render_state.sh "<State>" [zoom]
#
# Steps:
#   1. export_dem.R -> output/<slug>_height.tif + _mask.png + _meta.json
#      (skipped if they already exist for this slug; pass FORCE_EXPORT=1 to redo)
#   2. relief.py    -> output/<slug>_blender.png
#
# Run from the relief-maps/ directory. All BL_* env knobs (see relief.py) pass
# straight through, e.g.:
#   BL_EXAG=2.6 BL_RES=3000 BL_SAMPLES=256 blender/render_state.sh "Uttarakhand"
#   FORCE_EXPORT=1 blender/render_state.sh "Uttarakhand" 12   # re-fetch finer DEM
# ---------------------------------------------------------------------------
set -euo pipefail

STATE="${1:-Uttarakhand}"
ZOOM="${2:-10}"
BLENDER="${BLENDER:-/opt/homebrew/bin/blender}"
[ -x "$BLENDER" ] || BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.."                                   # -> relief-maps/
slug="$(echo "$STATE" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"

height="output/${slug}/${slug}_height.tif"
if [ "${FORCE_EXPORT:-0}" = "1" ] || [ ! -f "$height" ] || [ ! -f "output/${slug}/${slug}_meta.json" ]; then
  echo "==> export_dem.R $STATE z$ZOOM"
  Rscript blender/export_dem.R "$STATE" "$ZOOM"
else
  echo "==> reuse $height (FORCE_EXPORT=1 to re-export)"
fi

echo "==> blender relief.py $slug"
"$BLENDER" -b --python blender/relief.py -- "$slug" 2>&1 \
  | grep -vE "TIFFReadDirectory|DeprecationWarning|use_nodes" || true

echo "==> done: output/${slug}/${slug}${BL_SUFFIX:-_blender}.png"
