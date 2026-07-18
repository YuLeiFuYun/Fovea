#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
printf 'Using DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
xcodebuild -version
xcrun swift --version

python3 scripts/check-phase0a-surface.py
python3 scripts/check-docs.py
xcrun swift-format lint --strict -r Sources Tests Package.swift

rm -rf .artifacts/benchmarks
mkdir -p .artifacts/benchmarks
FOVEA_BENCHMARK_OUTPUT_DIR="$ROOT/.artifacts/benchmarks" \
FOVEA_VERIFIED_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf unverified-local)" \
xcrun swift test
python3 scripts/validate-benchmark-artifacts.py .artifacts/benchmarks/*.json

if [ "${RUN_IOS_SIMULATOR:-1}" = "1" ]; then
    simulator_id=$(python3 scripts/select-ios-simulator.py)
    printf 'Using iOS Simulator %s\n' "$simulator_id"
    xcodebuild \
        -scheme Fovea-Package \
        -destination "platform=iOS Simulator,id=$simulator_id" \
        APPINTENTS_METADATA_PROCESSING_ENABLED=NO \
        test
fi

if [ "${RUN_CRITICAL_MUTANTS:-0}" = "1" ]; then
    python3 scripts/run-critical-mutants.py
    python3 scripts/validate-critical-mutation-report.py
fi

set -- evidence/*.json
if [ -e "$1" ]; then
    python3 scripts/validate-evidence.py "$@"
fi
