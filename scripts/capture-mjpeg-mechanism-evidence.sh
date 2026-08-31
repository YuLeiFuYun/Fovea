#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-"$ROOT/.artifacts/performance/w5-mjpeg-mechanism"}
exec python3 "$ROOT/Tools/Performance/capture_mjpeg_mechanism.py" --output "$OUTPUT"
