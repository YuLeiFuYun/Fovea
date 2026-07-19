#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
printf 'Using DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
xcodebuild -version
xcrun swift --version
VERIFIED_COMMIT=$(git rev-parse HEAD)
printf 'Verified commit: %s\n' "$VERIFIED_COMMIT"

python3 scripts/check-architecture-boundaries.py
python3 scripts/check-docs.py
python3 scripts/check-test-traceability.py
xcrun swift-format lint --strict -r Sources Tests Package.swift
python3 scripts/run-http-conformance.py

rm -rf .artifacts/benchmarks
mkdir -p .artifacts/benchmarks
FOVEA_BENCHMARK_OUTPUT_DIR="$ROOT/.artifacts/benchmarks" \
FOVEA_VERIFIED_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf unverified-local)" \
xcrun swift test -Xswiftc -warnings-as-errors
python3 scripts/validate-benchmark-artifacts.py .artifacts/benchmarks/*.json

if [ "${RUN_STORE_GENERATION_CONTENTION:-1}" = "1" ]; then
    scripts/run-store-generation-contention.py
fi

if [ "${RUN_PRODUCTION_COVERAGE:-1}" = "1" ]; then
    scripts/run-production-coverage.py
fi

if [ "${RUN_RELEASE:-1}" = "1" ]; then
    xcrun swift build -c release -Xswiftc -warnings-as-errors
fi

if [ "${RUN_THREAD_SANITIZER:-1}" = "1" ]; then
    xcrun swift test --sanitize=thread -Xswiftc -warnings-as-errors
fi

if [ "${RUN_ADDRESS_SANITIZER:-1}" = "1" ]; then
    xcrun swift test --sanitize=address -Xswiftc -warnings-as-errors
fi

if [ "${RUN_IOS_SIMULATOR:-1}" = "1" ]; then
    simulator_id=$(python3 scripts/select-ios-simulator.py)
    printf 'Using iOS Simulator %s\n' "$simulator_id"
    xcodebuild \
        -scheme Fovea-Package \
        -destination "platform=iOS Simulator,id=$simulator_id" \
        APPINTENTS_METADATA_PROCESSING_ENABLED=NO \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
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
