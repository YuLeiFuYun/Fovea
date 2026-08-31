#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

OUTPUT=${1:-.artifacts/performance/derived-raster-container-final}
ITERATIONS=${2:-15}
GROUP=${3:-all}
case "$GROUP" in
  all|real|hero) ;;
  *) echo "usage: $0 [output-directory] [iterations] [all|real|hero]" >&2; exit 64 ;;
esac
if [ "$ITERATIONS" -ne 15 ]; then
  echo "retained directional matrix requires exactly 15 iterations" >&2
  exit 64
fi

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product FoveaDerivedRasterLab -Xswiftc -warnings-as-errors
BIN=$(xcrun swift build -c release --show-bin-path)/FoveaDerivedRasterLab
mkdir -p "$OUTPUT"

run_case() {
  input=$1
  name=$2
  width=$3
  height=$4
  "$BIN" \
    --input "$input" \
    --output "$OUTPUT/${name}-${width}x${height}.json" \
    --target-width "$width" \
    --target-height "$height" \
    --iterations "$ITERATIONS"
}

run_targets() {
  input=$1
  name=$2
  run_case "$input" "$name" 390 260
  run_case "$input" "$name" 780 520
  run_case "$input" "$name" 1170 780
}

if [ "$GROUP" = all ] || [ "$GROUP" = real ]; then
  PHOTO_ROOT=$ROOT/../ImageCraft/Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/sources
  run_targets "$PHOTO_ROOT/animal-usda-cow-sunset.jpg" animal-usda-cow-sunset
  run_targets "$PHOTO_ROOT/architecture-usda-snow.jpg" architecture-usda-snow
  run_targets "$PHOTO_ROOT/landscape-coconino-sunflowers.jpg" landscape-coconino-sunflowers
  run_targets "$PHOTO_ROOT/people-usda-meeting.jpg" people-usda-meeting
fi

if [ "$GROUP" = all ] || [ "$GROUP" = hero ]; then
  HERO_ROOT=$ROOT/Benchmarks/ComparativeLab/Apps/GeneratedResources/heroes
  run_targets "$HERO_ROOT/hero-12mp-4000x3000.jpg" hero-12mp-4000x3000
  run_targets "$HERO_ROOT/hero-24mp-6000x4000.jpg" hero-24mp-6000x4000
  run_targets "$HERO_ROOT/hero-48mp-8000x6000.jpg" hero-48mp-8000x6000
fi
