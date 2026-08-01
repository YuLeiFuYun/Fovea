#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PLAN_PATH = ROOT / "Benchmarks/AsyncImageLab/experiment-plan.json"
APPLICABILITY_PATH = ROOT / "Benchmarks/AsyncImageLab/applicability.json"
CLAIMS_PATH = ROOT / "Benchmarks/AsyncImageLab/claim-families.json"
PROJECT_PATH = ROOT / "Benchmarks/ComparativeLab/Apps/project.yml"
ARTIFACT = ROOT / ".artifacts/asyncimage-lab/plan-verification.json"


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain an object")
    return value


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def main() -> int:
    plan = load(PLAN_PATH)
    applicability = load(APPLICABILITY_PATH)
    claims = load(CLAIMS_PATH)
    project = PROJECT_PATH.read_text()
    errors: list[str] = []
    expected_comparators = ["Apple AsyncImage", "Fovea"]
    expected_workloads = {
        "W1-SCROLL-V1",
        "W2-HERO-V1",
        "W10-SWIFTUI-IDENTITY-CHURN-V1",
    }

    if plan.get("schemaVersion") != 5 or plan.get("planID") != "FOVEA-SWIFTUI-SURFACE-LAB-V5":
        errors.append("unexpected SwiftUI surface plan identity")
    if plan.get("status") != "preregistered-after-v4-visible-versus-terminal-audit-before-v5-results":
        errors.append("SwiftUI surface V5 plan must remain preregistered")
    if plan.get("supersedes") != "Benchmarks/AsyncImageLab/plans/experiment-plan-v4.json":
        errors.append("SwiftUI surface V4 plan archive binding is missing")
    archived_plan = load(ROOT / "Benchmarks/AsyncImageLab/plans/experiment-plan-v4.json")
    if archived_plan.get("schemaVersion") != 4 or archived_plan.get("planID") != "FOVEA-SWIFTUI-SURFACE-LAB-V4":
        errors.append("archived SwiftUI V4 plan identity drifted")
    comparators = plan.get("comparators", {})
    if comparators.get("platform") != {
        "name": "Apple AsyncImage",
        "sourceIdentity": "platform-build",
        "requiredBindings": ["xcodeBuild", "osBuild", "deviceProfileID"],
    }:
        errors.append("AsyncImage platform identity contract drifted")
    if comparators.get("systemUnderTest") != {
        "name": "Fovea",
        "sourceIdentity": "runner-injected-head-tree-dirty-state",
        "surface": "FoveaResponsiveImage",
    }:
        errors.append("Fovea SwiftUI surface identity contract drifted")
    if plan.get("claimFamilies") != "Benchmarks/AsyncImageLab/claim-families.json":
        errors.append("SwiftUI surface plan does not bind claim families")
    if plan.get("applicability") != "Benchmarks/AsyncImageLab/applicability.json":
        errors.append("SwiftUI surface plan does not bind applicability")
    if set(plan.get("workloads", {})) != expected_workloads:
        errors.append("SwiftUI surface plan must contain exactly W1, W2 and W10")
    for identifier, workload in plan.get("workloads", {}).items():
        if workload.get("cacheStates") != ["uncontrolled-system-cache"]:
            errors.append(f"{identifier}: surface cache state must remain explicitly qualified")
        if not workload.get("hardChecks"):
            errors.append(f"{identifier}: hard checks are missing")
    execution = plan.get("execution", {})
    if execution.get("pairedOrder") != [
        ["Apple AsyncImage", "Fovea"], ["Fovea", "Apple AsyncImage"]
    ]:
        errors.append("paired SwiftUI surface order drifted")
    if execution.get("samplerWarmupFrames") != 3:
        errors.append("SwiftUI sampler warmup must remain three display frames")
    if execution.get("surfaceArming") != "mount-inert-root-wait-three-display-frames-start-samplers-then-arm":
        errors.append("SwiftUI surface arming boundary drifted")
    if execution.get("sourceIdentityCapture") != "after-resource-preparation-xcodegen-and-build-before-first-launch":
        errors.append("SwiftUI source identity capture boundary drifted")
    if execution.get("visibleSuccessObservation") != "first-full-quality-rendered-view-onAppear: AsyncImage success; Fovea UInt16.max preview or final fallback":
        errors.append("SwiftUI V5 first-full-quality visible boundary drifted")
    if execution.get("terminalPhaseObservation") != "separately recorded; Fovea terminal means durable final, AsyncImage terminal does not expose cache durability and is not cross-ranked as durability":
        errors.append("SwiftUI V5 terminal phase boundary drifted")
    if execution.get("simulatorPairedBlocks") != 5:
        errors.append("SwiftUI simulator calibration must retain five paired blocks")
    if execution.get("appContainerIsolation") != "uninstall-and-reinstall-prebuilt-app-before-every-comparator-run":
        errors.append("SwiftUI app-container isolation boundary drifted")
    if execution.get("foveaCacheIsolation") != "unique-run-nonce-cache-root-with-fail-closed-cleanup":
        errors.append("Fovea SwiftUI cache isolation boundary drifted")
    if execution.get("requestCacheIsolation") != "shared-paired-block-nonce-appended-to-every-origin-URL":
        errors.append("SwiftUI paired request-cache isolation boundary drifted")
    if execution.get("artifactIndexing") != "comparator-workload-run-index":
        errors.append("SwiftUI artifact indexing boundary drifted")
    if execution.get("pairedBlockUnit") != "same-workload-same-run-nonce-two-comparator-processes":
        errors.append("SwiftUI paired-block unit drifted")

    if applicability.get("schemaVersion") != 2 or applicability.get("contractID") != "FOVEA-SWIFTUI-SURFACE-APPLICABILITY-V2":
        errors.append("unexpected SwiftUI surface applicability identity")
    if applicability.get("comparators") != expected_comparators:
        errors.append("SwiftUI surface comparator set drifted")
    if applicability.get("supersedes") != "Benchmarks/AsyncImageLab/plans/applicability-v1.json":
        errors.append("SwiftUI surface applicability V1 archive binding is missing")
    applicable = {item.get("id") for item in applicability.get("applicableWorkloads", [])}
    if applicable != expected_workloads:
        errors.append("SwiftUI applicable workload set drifted")
    not_comparable = {item.get("id") for item in applicability.get("notComparableWorkloads", [])}
    if not_comparable != {"W3-AUTH-V1", "W7-THOUSAND-CONCURRENT-V1"}:
        errors.append("SwiftUI surface W3/W7 boundary drifted")
    for key in (
        "unsupportedIsNotZero",
        "headlessAdapterForbidden",
        "platformIdentityRequired",
        "simulatorEvidenceIsProvisional",
        "pairedTraceRequired",
        "commonEndpointsOnlyForRanking",
        "foveaExtraCapabilitiesReportedSeparately",
    ):
        if applicability.get("rules", {}).get(key) is not True:
            errors.append(f"SwiftUI applicability rule {key} must remain true")

    if claims.get("schemaVersion") != 4 or claims.get("registryID") != "FOVEA-SWIFTUI-SURFACE-CLAIMS-V4":
        errors.append("unexpected SwiftUI surface claim registry")
    if claims.get("status") != "preregistered-after-v4-visible-versus-terminal-audit-before-v5-results":
        errors.append("SwiftUI V5 claim registry must remain preregistered")
    if claims.get("supersedes") != "Benchmarks/AsyncImageLab/plans/claim-families-v3.json":
        errors.append("SwiftUI V3 claim archive binding is missing")
    archived_claims = load(ROOT / "Benchmarks/AsyncImageLab/plans/claim-families-v3.json")
    if archived_claims.get("schemaVersion") != 3 or archived_claims.get("registryID") != "FOVEA-SWIFTUI-SURFACE-CLAIMS-V3":
        errors.append("archived SwiftUI V3 claim identity drifted")
    if claims.get("comparators") != expected_comparators:
        errors.append("SwiftUI claim comparator set drifted")
    claim_workloads = {
        workload
        for family in claims.get("families", [])
        for workload in family.get("workloadIDs", [])
    }
    if claim_workloads != expected_workloads or len(claims.get("families", [])) != 3:
        errors.append("SwiftUI claim workload families are incomplete")
    rules = claims.get("rules", {})
    if rules.get("commonEndpointsOnly") is not True or rules.get("missingMetric") != "not-comparable-not-zero":
        errors.append("SwiftUI claim truth boundary drifted")
    if rules.get("samplerArming") != "after-inert-root-three-frame-warmup":
        errors.append("SwiftUI claim sampler arming boundary drifted")
    if rules.get("visibleSuccessBoundary") != "first-full-quality-rendered-view-onAppear":
        errors.append("SwiftUI V5 claim visible boundary drifted")
    if rules.get("terminalPhaseBoundary") != "separate-diagnostic-not-common-durability-ranking":
        errors.append("SwiftUI V5 claim terminal boundary drifted")
    if rules.get("minimumSimulatorPairedBlocks") != 5:
        errors.append("SwiftUI claim minimum paired-block count drifted")
    if rules.get("simulatorCalibrationUnit") != "paired-block":
        errors.append("SwiftUI simulator calibration unit drifted")
    if rules.get("pairedBlockCacheIsolation") != "fresh-app-container-and-shared-run-nonce":
        errors.append("SwiftUI paired-block cache isolation rule drifted")

    required_project_tokens = [
        "AsyncImageComparatorBench:",
        "PRODUCT_BUNDLE_IDENTIFIER: dev.fovea.comparative.asyncimage",
        "FoveaSwiftUIComparatorBench:",
        "PRODUCT_BUNDLE_IDENTIFIER: dev.fovea.comparative.foveaswiftui",
        "-D FOVEA_SWIFTUI_SURFACE",
        "INFOPLIST_KEY_NSAppTransportSecurity_NSAllowsLocalNetworking: YES",
    ]
    for token in required_project_tokens:
        if token not in project:
            errors.append(f"SwiftUI project target missing token: {token}")
    for relative in (
        "Benchmarks/ComparativeLab/Apps/AsyncImage/AsyncImageBenchmarkApp.swift",
        "Benchmarks/ComparativeLab/Apps/AsyncImage/AsyncImageBenchmarkRuntime.swift",
        "Benchmarks/ComparativeLab/Apps/AsyncImage/AsyncImageBenchmarkViews.swift",
        "Benchmarks/ComparativeLab/Apps/Shared/LoopbackBenchmarkOriginServer.swift",
    ):
        if not (ROOT / relative).is_file():
            errors.append(f"missing SwiftUI surface source: {relative}")

    result = {
        "schemaVersion": 5,
        "planID": plan.get("planID"),
        "planSHA256": digest(plan),
        "applicabilitySHA256": digest(applicability),
        "claimFamilySHA256": digest(claims),
        "comparators": expected_comparators,
        "applicableWorkloads": sorted(applicable),
        "notComparableWorkloads": sorted(not_comparable),
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "SwiftUI surface plan: "
        f"comparators={len(expected_comparators)} applicable={len(applicable)} "
        f"notComparable={len(not_comparable)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
