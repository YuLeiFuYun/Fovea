#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "Benchmarks/ComparativeLab/experiment-plan.json"
LOCK = ROOT / "docs/research/comparator-lock.json"
ARTIFACT = ROOT / ".artifacts/comparators/experiment-plan.json"
SELECTION = ROOT / "Benchmarks/ComparativeLab/dataset-selection.json"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def main() -> int:
    plan = json.loads(PLAN.read_text())
    lock = json.loads(LOCK.read_text())
    if plan.get("schemaVersion") != 1 or plan.get("planID") != "FOVEA-P0B-COMP-V1":
        fail("unexpected comparative experiment plan identity")
    if plan.get("status") != "preregistered-before-formal-results":
        fail("experiment plan must remain preregistered before formal results")
    comparators = plan.get("comparators", {})
    locked = {item["name"]: item for item in lock["comparators"]}
    if comparators.get("systemUnderTest") != {
        "name": "Fovea",
        "identity": "runner-injected-head-tree-dirty-state",
    }:
        fail("Fovea plan must require runner-injected commit/tree/dirty identity")
    if comparators.get("platformBaseline") != {
        "name": "Apple URLSession + URLCache + ImageIO",
        "sourceIdentity": "platform-build",
        "requiredBindings": ["xcodeBuild", "osBuild", "deviceProfileID"],
    }:
        fail("Apple native platform baseline identity drifted")
    for key, expected_name in (("primary", "Nuke"), ("requiredSecondary", "Kingfisher")):
        item = comparators.get(key, {})
        expected = locked[expected_name]
        if item.get("name") != expected_name:
            fail(f"{key} must remain {expected_name}")
        if item.get("version") != expected["tag"] or item.get("exactCommit") != expected["exactCommit"]:
            fail(f"{expected_name} plan identity differs from comparator lock")
    required_additional = comparators.get("requiredAdditional")
    expected_additional = ["SDWebImage", "PINRemoteImage"]
    if not isinstance(required_additional, list) or [item.get("name") for item in required_additional] != expected_additional:
        fail("required A-tier additions must remain SDWebImage and PINRemoteImage")
    for item in required_additional:
        expected = locked[item["name"]]
        if item.get("version") != expected["tag"] or item.get("exactCommit") != expected["exactCommit"]:
            fail(f"{item['name']} plan identity differs from comparator lock")
    retained = comparators.get("retainedBTier")
    if not isinstance(retained, list) or [item.get("name") for item in retained] != ["AlamofireImage"]:
        fail("AlamofireImage must remain the sole B-tier retained comparator")
    expected_alamofire = locked["AlamofireImage"]
    if retained[0].get("version") != expected_alamofire["tag"] or retained[0].get("exactCommit") != expected_alamofire["exactCommit"]:
        fail("AlamofireImage B-tier identity differs from comparator lock")
    independent = comparators.get("independentSurface")
    if independent != [{
        "name": "SwiftUI paired surface",
        "comparators": ["Apple AsyncImage", "Fovea"],
        "plan": "Benchmarks/AsyncImageLab/experiment-plan.json",
        "applicability": "Benchmarks/AsyncImageLab/applicability.json",
        "claimFamilies": "Benchmarks/AsyncImageLab/claim-families.json",
        "performanceRanking": "only-common-endpoints-within-paired-swiftui-surface",
    }]:
        fail("paired SwiftUI surface binding drifted")
    for relative in (
        independent[0]["plan"], independent[0]["applicability"],
        independent[0]["claimFamilies"],
    ):
        if not (ROOT / relative).is_file():
            fail(f"missing SwiftUI surface manifest: {relative}")
    matrix = comparators.get("matrixPolicy", {})
    expected_a_tier = [
        "Apple URLSession + URLCache + ImageIO", "Apple AsyncImage", "Nuke", "Kingfisher",
        "SDWebImage", "PINRemoteImage", "Fovea",
    ]
    expected_headless = [
        "Apple URLSession + URLCache + ImageIO", "Fovea", "Nuke", "Kingfisher",
        "SDWebImage", "PINRemoteImage",
    ]
    if matrix.get("aTierUnifiedApp") != expected_a_tier:
        fail("complete A-tier unified app matrix drifted")
    if matrix.get("aTierHeadlessW1W3") != expected_headless:
        fail("A-tier headless W1-W3 set drifted")
    if matrix.get("aTierIndependentSurface") != ["Apple AsyncImage"]:
        fail("AsyncImage must remain the independent A-tier surface")
    if matrix.get("bTierRetained") != ["AlamofireImage"] or matrix.get("bTierDoesNotSatisfyATierSlot") is not True:
        fail("B-tier policy must not substitute for an A-tier slot")

    governance = plan.get("comparisonGovernance", {})
    expected_governance = {
        "ontology": "docs/research/comparison-ontology.json",
        "comparatorRegistry": "docs/research/comparator-registry.json",
        "claimPolicy": "Benchmarks/claim-policy.json",
        "semanticComparability": "required-before-performance-ranking",
    }
    if governance != expected_governance:
        fail("experiment plan must bind the exact comparison governance manifests")
    for relative in (governance["ontology"], governance["comparatorRegistry"], governance["claimPolicy"]):
        if not (ROOT / relative).is_file():
            fail(f"missing comparison governance manifest: {relative}")
    if plan.get("statisticalClaimFamilies") != "Benchmarks/statistical-claim-families.json":
        fail("experiment plan must bind the statistical claim-family registry")
    if not (ROOT / plan["statisticalClaimFamilies"]).is_file():
        fail("statistical claim-family registry is missing")

    devices = plan.get("devices", {})
    if devices.get("simulatorCountsAsPhysicalDevice") is not False:
        fail("simulator must never satisfy a physical-device slot")
    if devices.get("primary", {}).get("role") != "primary-current-mid":
        fail("iPhone 16e primary role must remain primary-current-mid")
    if devices.get("primary", {}).get("requiredStableOSReplication") is not True:
        fail("primary beta device must require stable-OS replication")
    if devices.get("secondary", {}).get("required") is not True:
        fail("secondary lower-performance physical device must remain required")

    execution = plan.get("execution", {})
    if execution.get("coldCacheRepetitions", 0) < 10 or execution.get("warmStateRepetitions", 0) < 20:
        fail("formal repetitions are below the preregistered minimum")
    if execution.get("thermalStateRequiredAtStart") != "nominal":
        fail("formal physical blocks must start at nominal thermal state")
    if "invalidate the entire randomized block" not in execution.get("thermalInvalidation", ""):
        fail("thermal drift must invalidate and rerun the whole randomized block")
    steady = execution.get("steadyState", {})
    if steady.get("maximumWarmupSeconds") != 120 or "post-hoc" not in steady.get("diagnostic", ""):
        fail("steady-state diagnostics must be bounded and prohibit post-hoc discarding")
    permutations = execution.get("interleaving", {}).get("block")
    expected_set = {
        "Apple URLSession + URLCache + ImageIO", "Fovea", "Nuke", "Kingfisher",
        "SDWebImage", "PINRemoteImage",
    }
    if not isinstance(permutations, list) or len(permutations) != 12:
        fail("A-tier headless order must contain twelve preregistered rows")
    if any(set(row) != expected_set or len(row) != 6 for row in permutations):
        fail("invalid six-comparator A-tier interleaving row")
    positions = {name: [0] * 6 for name in expected_set}
    for row in permutations:
        for index, name in enumerate(row):
            positions[name][index] += 1
    if any(counts != [2, 2, 2, 2, 2, 2] for counts in positions.values()):
        fail("A-tier interleaving must place every comparator twice in every position")
    b_tier = execution.get("bTierSupplemental", {})
    if b_tier.get("comparators") != ["AlamofireImage"] or "excluded-from-a-tier" not in b_tier.get("policy", ""):
        fail("B-tier supplemental execution policy drifted")

    statistics = plan.get("statistics", {})
    if statistics.get("bootstrapIterations", 0) < 10_000:
        fail("bootstrap iteration count is below 10,000")
    if statistics.get("resamplingUnit") != "run-session-cluster":
        fail("statistics must resample by run/session cluster")

    outcome = plan.get("outcomePolicy", {})
    if outcome.get("betaOSResults") != "provisional-only":
        fail("beta OS results must remain provisional")
    if outcome.get("missingMetric") != "incomparable-not-zero":
        fail("missing metrics must not be imputed as zero")
    if outcome.get("bestClaimRule") != "best-within-scope-requires-open-L2-family-all-primary-endpoints-noninferior-equivalent-or-superior-and-at-least-one-practically-superior":
        fail("best-claim rule must be bounded to an opened L2 claim family")
    if outcome.get("applicableCorrectnessRule") != "fovea-must-pass-every-hard-correctness-check-for-every-implemented-capability":
        fail("applicable correctness rule is missing")
    if outcome.get("unsupportedCapability") != "reported-as-capability-gap-and-excluded-from-existing-capability-ranking":
        fail("unsupported capability policy is missing")

    native = plan.get("nativeUpstreamTestSuites", {})
    if native.get("aTierRequired") != ["Nuke", "Kingfisher", "SDWebImage", "PINRemoteImage"]:
        fail("all four A-tier external native suites must remain required")
    if native.get("bTierRetained") != ["AlamofireImage"]:
        fail("AlamofireImage native suite must remain B-tier retained evidence")
    if "unmodified" not in native.get("policy", "") or "classify-every-exclusion" not in native.get("policy", ""):
        fail("native upstream test policy must preserve original tests and classify exclusions")
    challenge = plan.get("challengeSuite", {})
    if challenge.get("manifest") != "Benchmarks/ComparativeLab/challenge-suite.json":
        fail("experiment plan must bind the challenge-suite manifest")
    if not (ROOT / challenge["manifest"]).is_file():
        fail("challenge-suite manifest is missing")

    workloads = plan.get("workloads", {})
    required_workloads = {"W1-SCROLL-V1", "W2-HERO-V1", "W3-AUTH-V1"}
    if set(workloads) != required_workloads:
        fail("experiment plan must contain exactly W1, W2, and W3")
    if len(workloads["W1-SCROLL-V1"].get("primaryMetrics", [])) > 3:
        fail("W1 may preregister at most three primary metrics")
    if len(workloads["W2-HERO-V1"].get("primaryMetrics", [])) > 3:
        fail("W2 may preregister at most three primary metrics")
    if workloads["W3-AUTH-V1"].get("primaryMetrics") != []:
        fail("W3 is a zero-leak correctness gate, not a performance tradeoff")
    primary_metrics = {
        metric
        for workload in workloads.values()
        for metric in workload.get("primaryMetrics", [])
    }
    thresholds = plan.get("metricDecisionThresholds", {})
    if set(thresholds) != primary_metrics:
        fail("every primary metric must have exactly one preregistered decision threshold")
    for metric, threshold in thresholds.items():
        if threshold.get("direction") not in {"lower", "higher"}:
            fail(f"invalid metric direction for {metric}")
        margin = threshold.get("equivalenceAbsolute")
        if not isinstance(margin, (int, float)) or margin <= 0:
            fail(f"equivalence margin must be positive for {metric}")
        if not threshold.get("unit") or not threshold.get("scope"):
            fail(f"metric threshold must bind unit and scope for {metric}")

    dataset = plan.get("dataset", {})
    selection_path = dataset.get("selectionManifest")
    if selection_path != "Benchmarks/ComparativeLab/dataset-selection.json":
        fail("experiment plan must bind the committed dataset selection manifest")
    selection_manifest = json.loads(SELECTION.read_text())
    if selection_manifest.get("schemaVersion") != 1:
        fail("dataset selection schemaVersion must be 1")
    if selection_manifest.get("assetCount") != 128 or len(selection_manifest.get("assets", [])) != 128:
        fail("dataset selection must contain exactly 128 assets")
    expected_selection_digest = hashlib.sha256(canonical(selection_manifest["assets"])).hexdigest()
    if selection_manifest.get("selectionSHA256") != expected_selection_digest:
        fail("dataset selection digest does not match its assets")
    ids = [item.get("assetID") for item in selection_manifest["assets"]]
    if ids != sorted(ids) or len(set(ids)) != len(ids):
        fail("dataset selection asset IDs must be unique and lexicographically ordered")
    if any(item.get("requestURL", "").split("?", 1)[0].startswith("https://commons.wikimedia.org/wiki/Special:Redirect/file/") is False for item in selection_manifest["assets"]):
        fail("dataset selection contains a non-Commons request URL")
    selection = dataset.get("remoteFeedSelection", {})
    if selection.get("count") != 128 or selection.get("order") != "lexicographic-asset-id":
        fail("W1 feed dataset selection must remain deterministic at 128 assets")
    for fixture in dataset.get("heroFixtures", []):
        if not (ROOT / fixture).is_file():
            fail(f"missing preregistered hero fixture: {fixture}")

    digest = hashlib.sha256(canonical(plan)).hexdigest()
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(
        json.dumps(
            {
                "planID": plan["planID"],
                "planSHA256": digest,
                "schemaVersion": 1,
                "status": "passed",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    print(f"Comparative experiment plan valid: {plan['planID']} sha256:{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
