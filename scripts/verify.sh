#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

FOVEA_VERIFY_PROFILE=${FOVEA_VERIFY_PROFILE:-smart}
case "$FOVEA_VERIFY_PROFILE" in
    smart|premerge|release|workbench-smoke)
        exec python3 scripts/run-verification-profile.py --profile "$FOVEA_VERIFY_PROFILE"
        ;;
    qualification)
        # The maximal matrix is deliberately explicit. It is no longer a default
        # developer loop, and no required qualification proof can be disabled.
        export RUN_IOS_EXAMPLE=1
        export RUN_STORE_GENERATION_CONTENTION=1
        export RUN_COMPONENT_CLEAN_COPY=1
        export RUN_PRODUCTION_COVERAGE=1
        export RUN_RELEASE=1
        export RUN_THREAD_SANITIZER=1
        export RUN_ADDRESS_SANITIZER=1
        export RUN_IOS_SIMULATOR=1
        export RUN_CRITICAL_MUTANTS=1
        export FOVEA_QUALIFICATION_ACTIVE=1
        FOVEA_QUALIFICATION_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
        FOVEA_QUALIFICATION_STARTED_EPOCH=$(date +%s)
        FOVEA_QUALIFICATION_SESSION_DIR="$ROOT/.artifacts/verification/qualification-runs/$FOVEA_QUALIFICATION_RUN_ID"
        export FOVEA_QUALIFICATION_RUN_ID FOVEA_QUALIFICATION_STARTED_EPOCH FOVEA_QUALIFICATION_SESSION_DIR
        rm -rf "$FOVEA_QUALIFICATION_SESSION_DIR"
        mkdir -p "$FOVEA_QUALIFICATION_SESSION_DIR"
        ;;
    *)
        printf 'Unknown FOVEA_VERIFY_PROFILE: %s\n' "$FOVEA_VERIFY_PROFILE" >&2
        exit 2
        ;;
esac

record_qualification_assurance() {
    if [ "${FOVEA_QUALIFICATION_ACTIVE:-0}" = "1" ]; then
        python3 scripts/write-qualification-receipt.py "$1"
    fi
}

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
printf 'Using DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
xcodebuild -version
xcrun swift --version
python3 scripts/check-swift-toolchain.py
VERIFIED_COMMIT=$(git rev-parse HEAD)
printf 'Verified commit: %s\n' "$VERIFIED_COMMIT"

python3 scripts/check-project-memory.py
python3 scripts/check-workload-registry.py
python3 scripts/check-actions-budget-governance.py
python3 scripts/render-project-context.py

python3 scripts/check-architecture-boundaries.py
python3 scripts/check-component-pins.py
xcrun swift package resolve
python3 scripts/analyze-mathematical-architecture.py
python3 scripts/model-check-cache-transactions.py
python3 scripts/model-check-validated-encoded-handoff.py
python3 scripts/model-check-adaptive-image-admission.py
python3 scripts/model-check-http-metadata-limits.py
python3 scripts/model-check-transport-retry.py
python3 scripts/model-check-permit-scheduler.py
python3 scripts/model-check-shared-task-registry.py
python3 scripts/analyze-retry-jitter.py
python3 scripts/analyze-multi-resource-fairness.py
python3 scripts/check-mathematical-proof-obligations.py
python3 scripts/check-optimization-parameters.py
python3 scripts/check-resource-envelope.py
python3 scripts/model-check-decode-resource-composition.py
python3 scripts/check-imageio-resource-lifetime-ledger.py
python3 scripts/prove-namespace-generation-manifest-bound.py
python3 scripts/audit-numeric-constants.py
python3 scripts/check-comparison-governance.py
python3 scripts/check-negative-results.py
python3 scripts/check-latency-distribution-analysis.py
python3 scripts/analyze-delayed-hit-cache.py
python3 scripts/verify-comparative-lab.py
python3 scripts/check-cache-lab-plan.py
python3 scripts/test-cache-lab-host-monitor.py
python3 scripts/test-cache-lab-source-identity.py
xcrun swift test --package-path Benchmarks/CacheLab
python3 scripts/test-cache-lab-formal-process-model.py
python3 scripts/check-cache-decision-domain.py
python3 scripts/analyze-cache-policies.py
python3 scripts/check-mathematical-research.py
python3 scripts/check-comment-quality.py
python3 scripts/check-privacy-manifests.py
python3 scripts/check-structural-quality.py
python3 scripts/check-docs.py
python3 scripts/check-engineering-knowledge.py
python3 scripts/verify-documentation.py
python3 scripts/validate-documentation-report.py
python3 scripts/check-test-traceability.py
python3 scripts/validate-progressive-presentation-evidence.py \
    docs/research/progressive-presentation-simulator-evidence-2026-08.json
python3 scripts/check-process-group-cleanup.py
python3 scripts/check-tooling-syntax.py
python3 scripts/check-reference-provenance.py
python3 scripts/check-sensitive-material.py
python3 scripts/test-image-metadata.py
python3 scripts/check-supply-chain.py
python3 scripts/lint-fovea-swift-format.py
python3 scripts/run-http-conformance.py
python3 scripts/verify-demos.py
if [ "${RUN_IOS_EXAMPLE:-1}" = "1" ]; then
    ios_example_args=
    if [ "${RUN_LIVE_NETWORK:-0}" != "1" ]; then
        ios_example_args="--skip-live-network"
    fi
    # shellcheck disable=SC2086
    python3 scripts/verify-ios-example.py $ios_example_args
    record_qualification_assurance deterministic-workbench-complete
fi
python3 scripts/run-loopback-network-lab.py
if [ "${RUN_LIVE_NETWORK:-0}" = "1" ]; then
    python3 scripts/run-live-network-lab.py --timeout 240 --attempts 2
fi

rm -rf .artifacts/benchmarks
mkdir -p .artifacts/benchmarks
FOVEA_BENCHMARK_OUTPUT_DIR="$ROOT/.artifacts/benchmarks" \
FOVEA_VERIFIED_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf unverified-local)" \
python3 scripts/run-swift-strict.py test
python3 scripts/validate-benchmark-artifacts.py .artifacts/benchmarks/*.json

if [ "${RUN_STORE_GENERATION_CONTENTION:-1}" = "1" ]; then
    scripts/run-store-generation-contention.py
fi

if [ "${RUN_COMPONENT_CLEAN_COPY:-0}" = "1" ]; then
    scripts/verify-component-clean-copy.py
    record_qualification_assurance component-clean-copy
fi

if [ "${RUN_PRODUCTION_COVERAGE:-1}" = "1" ]; then
    scripts/run-production-coverage.py
    scripts/validate-production-coverage.py
    record_qualification_assurance production-coverage
fi

if [ "${RUN_RELEASE:-1}" = "1" ]; then
    python3 scripts/run-swift-strict.py build -c release
    record_qualification_assurance release-build
fi

if [ "${RUN_THREAD_SANITIZER:-1}" = "1" ]; then
    python3 scripts/run-swift-strict.py test --sanitize=thread
    record_qualification_assurance thread-sanitizer
fi

if [ "${RUN_ADDRESS_SANITIZER:-1}" = "1" ]; then
    python3 scripts/run-swift-strict.py test --sanitize=address
    record_qualification_assurance address-sanitizer
fi

if [ "${RUN_IOS_SIMULATOR:-1}" = "1" ]; then
    simulator_id=$(python3 scripts/select-ios-simulator.py)
    printf 'Using iOS Simulator %s\n' "$simulator_id"
    # 不把 warnings-as-errors 全局注入 SwiftPM 图；Xcode 27 会把它与外部包的
    # -suppress-warnings 判定为冲突。Fovea 自有源码由前面的 run-swift-strict 门审计。
    xcodebuild \
        -scheme Fovea-Package \
        -destination "platform=iOS Simulator,id=$simulator_id" \
        -collect-test-diagnostics never \
        APPINTENTS_METADATA_PROCESSING_ENABLED=NO \
        test
    record_qualification_assurance ios-simulator-package-tests
fi

if [ "${RUN_CRITICAL_MUTANTS:-0}" = "1" ]; then
    # 先验证全部变异仍能精确应用，避免昂贵测试矩阵运行到后半段才暴露陈旧锚点。
    python3 scripts/run-critical-mutants.py --validate-applications
    python3 scripts/run-critical-mutants.py
    python3 scripts/validate-critical-mutation-report.py
    record_qualification_assurance critical-mutation-suite
fi

set -- evidence/*.json
if [ -e "$1" ]; then
    python3 scripts/validate-evidence.py "$@"
fi

python3 scripts/write-qualification-certificate.py
