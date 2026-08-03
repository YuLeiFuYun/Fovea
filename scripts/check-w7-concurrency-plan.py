#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "Benchmarks/W7ConcurrencyLab/experiment-plan.json"
CLAIMS = ROOT / "Benchmarks/W7ConcurrencyLab/claim-families.json"
WORKLOADS = ROOT / "Benchmarks/workload-registry.json"
WORKLOAD_SOURCE = ROOT / "Benchmarks/ComparativeLab/Apps/Shared/W7ConcurrencyWorkload.swift"
ORIGIN_SOURCE = ROOT / "Benchmarks/ComparativeLab/Apps/Shared/BenchmarkOrigin.swift"
BENCHMARK_MODELS = ROOT / "Benchmarks/ComparativeLab/Apps/Shared/BenchmarkModels.swift"
RUNNER_SOURCE = ROOT / "scripts/run-w7-concurrency-lab.py"
CORE_CONTRACT_SOURCE = ROOT / "Benchmarks/ComparativeLab/Sources/ComparativeLabCore/ComparativeLabCore.swift"
FOVEA_ADAPTER_SOURCE = ROOT / "Benchmarks/ComparativeLab/Adapters/FoveaAdapterPackage/Sources/FoveaComparatorAdapter/FoveaComparatorAdapter.swift"
KINGFISHER_ADAPTER_SOURCE = ROOT / "Benchmarks/ComparativeLab/Adapters/KingfisherAdapterPackage/Sources/KingfisherComparatorAdapter/KingfisherComparatorAdapter.swift"
PIN_ADAPTER_SOURCE = ROOT / "Benchmarks/ComparativeLab/Adapters/PINRemoteImageAdapterPackage/Sources/PINRemoteImageComparatorAdapter/PINRemoteImageComparatorAdapter.swift"


def canonical(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def main() -> int:
    plan = json.loads(PLAN.read_text())
    claims = json.loads(CLAIMS.read_text())
    workloads = json.loads(WORKLOADS.read_text())
    errors: list[str] = []
    execution = plan.get("execution", {})
    expected_simulator_identity = {
        "deviceProfileID": "ios27-simulator-calibration-v1",
        "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-17e",
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        "runtimeVersion": "27.0",
        "runtimeBuild": "24A5355p",
        "osChannel": "beta",
        "treeBoundBuildManifestRequired": True,
        "uniqueResultFilenameRequired": True,
    }
    if execution.get("simulatorCalibrationIdentity") != expected_simulator_identity:
        errors.append("W7 V9 Simulator calibration identity drifted")
    expected_status = (
        "preregistered-after-v8-native-preparation-counterexample-before-formal-results"
    )
    if plan.get("schemaVersion") != 9 or plan.get("planID") != "FOVEA-W7-CONCURRENCY-V9":
        errors.append("unexpected W7 plan identity")
    if plan.get("status") != expected_status:
        errors.append("W7 V9 plan must remain preregistered before formal results")
    if plan.get("supersedes") != "Benchmarks/W7ConcurrencyLab/plans/experiment-plan-v8.json":
        errors.append("W7 V8 plan archive binding is missing")
    archived_plan = json.loads(
        (ROOT / "Benchmarks/W7ConcurrencyLab/plans/experiment-plan-v8.json").read_text()
    )
    if archived_plan.get("schemaVersion") != 8 or archived_plan.get("planID") != "FOVEA-W7-CONCURRENCY-V8":
        errors.append("archived W7 V8 plan identity drifted")
    expected_comparators = [
        "Apple URLSession + URLCache + ImageIO", "Fovea", "Nuke", "Kingfisher",
        "SDWebImage", "PINRemoteImage",
    ]
    if plan.get("comparators") != expected_comparators:
        errors.append("W7 V9 A-tier headless comparator set drifted")
    supplemental = plan.get("bTierSupplemental", {})
    if supplemental.get("comparators") != ["AlamofireImage"] or "excluded from A-tier" not in supplemental.get("policy", ""):
        errors.append("W7 V9 B-tier supplemental policy drifted")
    not_applicable = plan.get("notApplicable", {})
    if set(not_applicable) != {"Apple AsyncImage"} or "headless" not in not_applicable.get("Apple AsyncImage", ""):
        errors.append("W7 V9 must preserve AsyncImage as not applicable")
    if execution.get("originConcurrentServiceLimit") != 8:
        errors.append("W7 origin-owned service limit must remain eight")
    if execution.get("clientConcurrentFetchBudget") != 8:
        errors.append("W7 client fetch budget must remain eight")
    if plan.get("workloadID") != "W7-THOUSAND-CONCURRENT-V1":
        errors.append("unexpected W7 workload identity")
    subtraces = plan.get("subtraces", {})
    single = subtraces.get("singleFlightCancellation", {})
    priority = subtraces.get("priorityScheduling", {})
    if execution.get("logicalRequestCount") != 1000:
        errors.append("W7 must contain exactly 1000 logical requests")
    if single.get("logicalRequests") != 512 or priority.get("logicalRequests") != 488:
        errors.append("W7 subtraces must remain 512 + 488")
    if single.get("groups") * single.get("subscribersPerGroup") != 512:
        errors.append("single-flight group shape drifted")
    probe = priority.get("starvationProbe", {})
    balanced = priority.get("balancedRoundRobin", {})
    if priority.get("blockerRequests") != 8:
        errors.append("W7 V9 must keep eight blocker requests")
    if probe.get("olderBackgroundRequests") != 1 or probe.get("newerImmediateRequests") != 31:
        errors.append("W7 V9 starvation probe shape drifted")
    internal_bypass = probe.get("internalMaximumGrantBypasses")
    observable_bypass = probe.get("maximumObservableOriginStartBypasses")
    derived_observable = internal_bypass + execution.get("clientConcurrentFetchBudget", 0) - 1         if isinstance(internal_bypass, int) else None
    if internal_bypass != 8:
        errors.append("W7 V9 internal grant-bypass bound drifted")
    if observable_bypass != 15 or observable_bypass != derived_observable:
        errors.append("W7 V9 origin-start bound must equal 8 + client budget - 1 = 15")
    if probe.get("observableBoundDerivation") !=         "internalMaximumGrantBypasses + clientConcurrentFetchBudget - 1":
        errors.append("W7 V9 observable-bound derivation is missing")
    if balanced.get("requestsPerPriority") * 4 != 448:
        errors.append("W7 V9 balanced burst shape drifted")
    if balanced.get("submissionOrder") != "round-robin-background-utility-visible-immediate":
        errors.append("W7 V9 must keep round-robin balanced arrivals")
    if 8 + 1 + 31 + balanced.get("logicalRequests", 0) != 488:
        errors.append("W7 V9 priority subtrace no longer totals 488")
    barrier = single.get("preparationBarrier", {})
    expected_barrier = {
        "closeBeforeLoadConstruction": True,
        "logicalLoadsRequiredBeforeRelease": 512,
        "nativeRequestCreationAllowedWhileClosed": True,
        "responseDeliveryScope": "/w7/shared-only",
        "releaseBeforeCancellationDelayStarts": True,
        "requiredObservedWaitersMinimum": 1,
    }
    if barrier != expected_barrier:
        errors.append("W7 V9 shared-response preparation barrier drifted")
    if "single-flight-preparation-gate-engaged" not in plan.get("hardChecks", []):
        errors.append("W7 V9 preparation barrier hard check is missing")
    expected_adapter_preparation = {
        "contract": "ComparatorLoad.waitUntilPrepared",
        "requiredPreparedLogicalLoads": 512,
        "foveaExactSubscriberOrdinalRange": "1...32-per-shared-identity",
        "asynchronousAdapterSignalBoundary": "native-task-receipt-or-operation-identifier-installed",
        "synchronousAdapterBoundary": "makeLoad-returned-after-native-operation-installation",
        "timeoutRule": "adapter-specific-bounded-fail-closed",
    }
    if single.get("adapterPreparation") != expected_adapter_preparation:
        errors.append("W7 V9 native adapter preparation contract drifted")
    if "logical-load-preparation-count-exact" not in plan.get("hardChecks", []):
        errors.append("W7 V9 logical preparation hard check is missing")
    workload_source = WORKLOAD_SOURCE.read_text()
    origin_source = ORIGIN_SOURCE.read_text()
    core_contract_source = CORE_CONTRACT_SOURCE.read_text()
    fovea_adapter_source = FOVEA_ADAPTER_SOURCE.read_text()
    kingfisher_adapter_source = KINGFISHER_ADAPTER_SOURCE.read_text()
    pin_adapter_source = PIN_ADAPTER_SOURCE.read_text()
    if "DeterministicBenchmarkURLProtocol.closeW7SharedPreparationGate()" not in workload_source:
        errors.append("W7 workload no longer closes the preparation gate")
    release_after_prepare = (
        "let collectionTask = Task.detached { await collect(coalescing) }\n"
        "        DeterministicBenchmarkURLProtocol.releaseW7SharedPreparationGate()"
    )
    if release_after_prepare not in workload_source:
        errors.append("W7 workload no longer releases the gate after all loads are prepared")
    if 'if route == "/w7/shared"' not in origin_source or (
        "state.waitForW7SharedPreparationGate()" not in origin_source
    ):
        errors.append("W7 origin no longer gates shared response delivery")
    if "w7SharedPreparationWaitCount" not in origin_source:
        errors.append("W7 origin no longer emits preparation-wait evidence")
    if "func waitUntilPrepared() async throws" not in core_contract_source:
        errors.append("ComparatorLoad lost the native preparation contract")
    workload_preparation_markers = [
        "let preparedLoadCount = try await waitUntilPrepared(coalescing)",
        'identifier: "logical-load-preparation-count-exact"',
    ]
    if any(marker not in workload_source for marker in workload_preparation_markers):
        errors.append("W7 workload no longer awaits all logical-load preparations")
    fovea_preparation_markers = [
        "fetchSubscriberCountForBenchmarking",
        "preparationOrdinal",
        "waitUntilPrepared:",
    ]
    if any(marker not in fovea_adapter_source for marker in fovea_preparation_markers):
        errors.append("Fovea adapter lost exact subscriber preparation evidence")
    if "preparation.markPrepared()" not in kingfisher_adapter_source:
        errors.append("Kingfisher adapter lost native task preparation signal")
    if "preparation.markPrepared()" not in pin_adapter_source:
        errors.append("PINRemoteImage adapter lost native task preparation signal")
    runner_source = RUNNER_SOURCE.read_text()
    benchmark_models = BENCHMARK_MODELS.read_text()
    runner_requirements = {
        "tree-bound build manifest": "def verify_build_manifest(",
        "manifest source identity": '"sourceIdentity": identity',
        "manifest simulator identity": '"simulatorIdentity": simulator_identity',
        "unique result filename": "uuid.uuid4().hex",
        "Simulator profile injection": "SIMCTL_CHILD_FOVEA_SIMULATOR_PROFILE_ID",
        "Simulator build injection": "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_BUILD",
        "runtime build binding": '"osBuild": build',
    }
    for label, marker in runner_requirements.items():
        if marker not in runner_source:
            errors.append(f"W7 runner lost {label}")
    model_requirements = [
        'injected["FOVEA_SIMULATOR_PROFILE_ID"]',
        'injected["FOVEA_SIMULATOR_OS_VERSION"]',
        'injected["FOVEA_SIMULATOR_OS_BUILD"]',
        'injected["FOVEA_SIMULATOR_OS_CHANNEL"]',
        "versionMatchesCurrentSimulator",
    ]
    if any(marker not in benchmark_models for marker in model_requirements):
        errors.append("W7 app lost fail-closed Simulator environment injection")
    if single.get("expectedCancelledSubscribers") != 256:
        errors.append("cancelled subscriber contract drifted")
    if single.get("expectedCompletedSubscribers") + priority.get("expectedCompletedSubscribers") != 744:
        errors.append("completed subscriber contract drifted")
    required = {
        "single-flight-origin-request-count",
        "p99-logical-latency",
        "peak-thread-count",
        "immediate-to-background-p95-ratio",
    }
    if set(plan.get("primaryEndpoints", {})) != required:
        errors.append("W7 primary endpoint set drifted")
    if claims.get("schemaVersion") != 9 or claims.get("registryID") != "FOVEA-W7-CONCURRENCY-CLAIMS-V9":
        errors.append("unexpected W7 claim registry identity")
    if claims.get("status") != expected_status:
        errors.append("W7 V9 claim registry must remain preregistered")
    if claims.get("supersedes") != "Benchmarks/W7ConcurrencyLab/plans/claim-families-v8.json":
        errors.append("W7 V8 claim archive binding is missing")
    archived_claims = json.loads(
        (ROOT / "Benchmarks/W7ConcurrencyLab/plans/claim-families-v8.json").read_text()
    )
    if archived_claims.get("schemaVersion") != 8 or archived_claims.get("registryID") != "FOVEA-W7-CONCURRENCY-CLAIMS-V8":
        errors.append("archived W7 V8 claim identity drifted")
    efficiency = next(
        (family for family in claims.get("families", []) if family.get("id") == "W7.ConcurrentEfficiency"),
        None,
    )
    if not efficiency:
        errors.append("W7 efficiency claim family is missing")
    else:
        if efficiency.get("comparators") != [
            "Apple URLSession + URLCache + ImageIO", "Nuke", "Kingfisher", "SDWebImage", "PINRemoteImage"
        ]:
            errors.append("W7 A-tier efficiency comparator set drifted")
        if efficiency.get("bTierSupplemental") != ["AlamofireImage"]:
            errors.append("W7 B-tier supplemental claim boundary drifted")
        if efficiency.get("multiplicity") != "holm-within-a-tier-headless-family":
            errors.append("W7 multiplicity must remain within A-tier headless family")
    claim_endpoints = {
        endpoint
        for family in claims.get("families", [])
        for endpoint in family.get("primaryEndpoints", [])
    }
    if claim_endpoints != required:
        errors.append("W7 claim endpoints differ from plan")
    w7 = next((item for item in workloads.get("workloads", []) if item.get("id") == "W7"), None)
    if not w7 or w7.get("canonicalID") != plan.get("workloadID"):
        errors.append("W7 workload registry binding drifted")
    print(
        f"W7 concurrency plan: errors={len(errors)} "
        f"planSHA256:{canonical(plan)} claimsSHA256:{canonical(claims)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
