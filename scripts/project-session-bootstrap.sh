#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

python3 scripts/check-project-memory.py
python3 scripts/check-workload-registry.py
python3 scripts/render-project-context.py
cat .artifacts/project-memory/current-context.md
