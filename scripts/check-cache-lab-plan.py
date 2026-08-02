#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "Benchmarks/CacheLab/cache-plan.json"
ARCHIVED_PLAN_V3 = ROOT / "Benchmarks/CacheLab/plans/cache-plan-v3.json"
ARCHIVED_PLAN_V2 = ROOT / "Benchmarks/CacheLab/plans/cache-plan-v2.json"
ARCHIVED_PLAN_V1 = ROOT / "Benchmarks/CacheLab/plans/cache-plan-v1.json"
LOCK = ROOT / "docs/research/cache-comparator-lock.json"
RESOLVED = ROOT / "Benchmarks/CacheLab/Package.resolved"
ARTIFACT = ROOT / ".artifacts/cache-lab/plan-verification.json"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def main() -> int:
    plan = json.loads(PLAN.read_text())
    archived_v3 = json.loads(ARCHIVED_PLAN_V3.read_text())
    archived_v2 = json.loads(ARCHIVED_PLAN_V2.read_text())
    archived_v1 = json.loads(ARCHIVED_PLAN_V1.read_text())
    lock = json.loads(LOCK.read_text())
    if plan.get("schemaVersion") != 4 or plan.get("planID") != "FOVEA-CACHE-LAB-V4":
        fail("unexpected Cache Lab V4 plan identity")
    if plan.get("status") != "preregistered-before-next-formal-results":
        fail("Cache Lab V4 claim families must remain preregistered before the next formal run")
    if archived_v3.get("schemaVersion") != 3 or archived_v3.get("planID") != "FOVEA-CACHE-LAB-V3":
        fail("Cache Lab V3 archive is missing or changed identity")
    if archived_v3.get("archivedPlan") != "Benchmarks/CacheLab/plans/cache-plan-v2.json":
        fail("Cache Lab V3 archive must retain the V2 chain")
    if archived_v2.get("schemaVersion") != 2 or archived_v2.get("planID") != "FOVEA-CACHE-LAB-V2":
        fail("Cache Lab V2 archive is missing or changed identity")
    if archived_v2.get("archivedPlan") != "Benchmarks/CacheLab/plans/cache-plan-v1.json":
        fail("Cache Lab V2 archive must retain the V1 chain")
    if archived_v1.get("schemaVersion") != 1 or archived_v1.get("planID") != "FOVEA-CACHE-LAB-V1":
        fail("Cache Lab V1 archive is missing or changed identity")
    if plan.get("archivedPlan") != "Benchmarks/CacheLab/plans/cache-plan-v3.json":
        fail("Cache Lab V4 must bind the archived V3 plan")
    archived_claims = plan.get("archivedClaimFamilyRegistry")
    if archived_claims != "Benchmarks/CacheLab/plans/statistical-claim-families-cachelab-v3.json" or not (ROOT / archived_claims).is_file():
        fail("Cache Lab V4 must preserve the V3 claim-family registry")
    if plan.get("statisticalClaimFamilies") != "Benchmarks/statistical-claim-families.json":
        fail("Cache Lab V4 must bind the statistical claim-family registry")
    if not (ROOT / plan["statisticalClaimFamilies"]).is_file():
        fail("statistical claim-family registry is missing")
        fail("statistical claim-family registry is missing")

    source_policy = plan.get("sourceIdentityPolicy", {})
    if source_policy.get("reportSchemaVersion") != 4:
        fail("Cache Lab source identity policy must require report schema 4")
    if source_policy.get("components") != ["Fovea", "Akashic"]:
        fail("Cache Lab source identity policy must bind Fovea and Akashic")
    if set(source_policy.get("requiredFields", [])) != {
        "commit", "sourceTreeDigest", "includesWorkingTreeChanges", "dependencyMode"
    }:
        fail("Cache Lab source identity fields are incomplete")
    trusted = source_policy.get("trustedCertificate", {})
    if trusted != {
        "foveaDependencyMode": "root-worktree",
        "akashicDependencyMode": "source-control-checkout",
        "akashicDeclaredRevisionMustEqualMeasuredCommit": True,
        "workingTreesMustBeClean": True,
    }:
        fail("Cache Lab trusted source-resolution policy is incomplete")
    if "Schema 2 and 3" not in source_policy.get("legacyReports", ""):
        fail("Cache Lab must explicitly downgrade legacy schema 2 and 3 reports")

    host_policy = plan.get("hostExecutionPolicy", {})
    if host_policy != {
        "schemaVersion": 3,
        "policyID": "external-compiler-process-block-v3",
        "formalRequiredConsecutiveCleanSamples": 10,
        "sampleIntervalMilliseconds": 1000,
        "runnerMustBePrebuilt": True,
        "directBinaryRequired": True,
        "buildExcludedFromMeasurement": True,
        "wholeRunnerMonitoringRequired": True,
        "abortFormalOnExternalCompiler": True,
        "processModel": "independent-process-per-resampling-unit",
        "formalAcceptedBlockCount": 20,
        "correctnessProcess": (
            "separate-monitored-process-excluded-from-statistical-runs"
        ),
        "contaminatedAttemptPolicy": (
            "discard-current-process-block-and-retry-after-quiescence"
        ),
        "acceptedBlockRetention": (
            "retain-complete-clean-blocks-across-rejected-attempts"
        ),
        "resultPublication": "atomic-after-complete-campaign",
        "externalActivity": (
            "Build drivers are always disqualifying; standalone compiler/linker processes "
            "are disqualifying while actively consuming CPU."
        ),
        "processIdentification": (
            "Use the full command executable token because macOS ps comm may truncate long "
            "Xcode paths; build drivers always disqualify and standalone compilers "
            "disqualify while active."
        ),
    }:
        fail("Cache Lab host execution policy is incomplete or changed")


    claim = plan.get("claimPolicy", {})
    performance = claim.get("performance", "")
    if "Every applicable" not in performance or "dominance margin" not in performance or "optimal-floor" not in performance:
        fail("Cache Lab V4 performance policy must require endpoint-by-endpoint substantial dominance or an optimal-floor proof")
    if "blocks only its claim family" not in claim.get("scope", ""):
        fail("Cache Lab V4 must localize inconclusive evidence to its claim family")
    if claim.get("semanticStratification") != (
        "Only contestants in the same semanticGroup and durabilityLevel are ranked directly. "
        "Native PINCache results remain descriptive."
    ):
        fail("Cache Lab semantic stratification policy is missing")

    disk = plan.get("comparators", {}).get("disk")
    if not isinstance(disk, list) or len(disk) != 2:
        fail("Cache Lab V4 must declare native and wrapped PIN disk contestants")
    by_contestant = {item.get("contestant"): item for item in disk}
    native = by_contestant.get("PINDiskCacheNative", {})
    wrapped = by_contestant.get("PINDiskCacheDurableValidated", {})
    if native.get("durabilityLevel") != "D1" or native.get("rankingRole") != "descriptive":
        fail("native PINCache must remain a descriptive D1 contestant")
    if wrapped.get("durabilityLevel") != "D5" or wrapped.get("rankingRole") != "primary":
        fail("durable-validated PIN wrapper must be the D5 primary contestant")
    expected_wrapper = {
        "pin-write-completes",
        "data-file-fsync",
        "data-parent-directory-fsync",
        "api-readback-content-id-validation",
        "durable-proof-publication",
        "proof-gates-visibility",
    }
    if set(wrapped.get("wrapperSemantics", [])) != expected_wrapper:
        fail("durable PIN wrapper semantics are incomplete")
    if "not to native PINCache" not in wrapped.get("attribution", ""):
        fail("wrapper semantics must not be attributed to native PINCache")

    queue_policy = (
        "Each contestant instance owns a dedicated PINOperationQueue that is drained at "
        "batch and teardown boundaries."
    )
    if native.get("operationQueueIsolation") != queue_policy:
        fail("native PIN contestant must isolate and drain its operation queue")
    if wrapped.get("operationQueueIsolation") != queue_policy:
        fail("durable PIN contestant must isolate and drain its operation queue")
    disk_workloads = plan.get("diskWorkloads", {})
    if set(disk_workloads) != {"DISK-ADVERSARIAL-V2", "DISK-MIXED-V4"}:
        fail("Cache Lab V4 disk workload identities are incomplete")
    mixed = disk_workloads.get("DISK-MIXED-V4", {})
    completion = mixed.get("completionBoundary", {})
    if set(completion) != {"writeThroughput", "readThroughput", "teardown"}:
        fail("disk mixed workload completion boundaries are incomplete")
    if not all("quiescen" in value.lower() for value in completion.values()):
        fail("disk mixed workload must bind quiescence at every completion boundary")
    if "background-work-does-not-cross-measurement-window" not in mixed.get(
        "hardCorrectness", []
    ):
        fail("disk mixed workload must forbid deferred work crossing measurement windows")


    sut = plan.get("systemUnderTestConfiguration", {})
    expected_sut = {
        "memoryType": "AkashicMemory.ShardedMemoryCache<String,Data>",
        "shardCount": 8,
        "costSemantics": "exact-global-cost-limit-with-all-shard-large-entry-slow-path",
        "parameterStatus": "selected-after-v4-correctness-calibration-before-formal-results",
        "selectionEvidence": {
            "eightShardRetention": "five-independent-processes-x-twenty-rounds-3200-hot-probes-all-passed",
            "sixteenShardRejection": "failed-619-of-640-hot-retention-in-one-process",
            "thirtyTwoShardRejection": "failed-21-of-32-hot-retention-per-round-in-v3-diagnostic",
        },
    }
    if sut != expected_sut:
        fail("Cache Lab V4 must bind the selected eight-shard configuration and rejected alternatives")

    memory = plan.get("memoryWorkloads", {})
    if set(memory) != {"MEM-HOT-SCAN-V4", "MEM-CONCURRENT-V3"}:
        fail("Cache Lab V4 must use the implemented-round hot workload and precomputed concurrent workload")
    for workload_id in ("MEM-HOT-SCAN-V4", "MEM-CONCURRENT-V3"):
        workload = memory[workload_id]
        boundary = workload.get("corpusGenerationBoundary", "")
        if "before" not in boundary.lower() or "cache" not in boundary.lower():
            fail(f"{workload_id}: timed cache boundary is not explicit")
    concurrent_prior = memory["MEM-CONCURRENT-V3"].get("methodChangeFromV2", "")
    if "V2" not in concurrent_prior or "V3" not in concurrent_prior:
        fail("MEM-CONCURRENT-V3 must retain its V2 method-change record")

    hot_v4 = memory["MEM-HOT-SCAN-V4"]
    if hot_v4.get("rounds") != 20 or "fresh" not in hot_v4.get("roundIsolation", "").lower():
        fail("MEM-HOT-SCAN-V4 must execute twenty fresh-cache rounds")
    if "declared twenty rounds" not in hot_v4.get("methodChangeFromV3", ""):
        fail("MEM-HOT-SCAN-V4 must record the V3 round-count mismatch")

    disk_v4 = plan.get("diskWorkloads", {}).get("DISK-MIXED-V4", {})
    if disk_v4.get("p99SampleRounds") != 8:
        fail("DISK-MIXED-V4 must use eight p99 sampling rounds")
    if "1536" not in disk_v4.get("methodChangeFromV3", ""):
        fail("DISK-MIXED-V4 must record its expanded p99 sample count")
    if "do not enter throughput" not in disk_v4.get("p99SamplingBoundary", ""):
        fail("DISK-MIXED-V4 must separate p99 sampling from throughput duration")

    workload_source = (ROOT / "Benchmarks/CacheLab/Sources/CacheLabCore/CacheWorkloads.swift").read_text()
    if "rounds: Int = 20" not in workload_source or "normalizedRounds * operationCountPerRound" not in workload_source:
        fail("MEM-HOT-SCAN-V4 implementation does not execute/report twenty rounds")
    if "p99SampleRounds: Int = 8" not in workload_source or "p99ReadSampleCount: readLatencies.count" not in workload_source:
        fail("DISK-MIXED-V4 implementation does not report eight-round p99 sampling")

    statistics = plan.get("statistics", {})
    if statistics.get("repetitions") != 20:
        fail("formal Cache Lab must retain twenty repetitions")
    if statistics.get("bootstrapIterations") != 10_000:
        fail("Cache Lab bootstrap count must remain 10000")
    if statistics.get("equivalenceMethod") != "paired-bootstrap-TOST":
        fail("Cache Lab V4 must use paired bootstrap TOST")
    if statistics.get("multipleComparisonCorrection") != "Holm-within-metric-family":
        fail("Cache Lab V4 must retain Holm correction")
    if statistics.get("resamplingUnit") != "process-run-after-within-run-median":
        fail("Cache Lab resampling unit must remain the independent process-run block")
    if statistics.get("formalProcessModel") != (
        "one-independent-runner-process-per-resampling-unit"
    ):
        fail("formal Cache Lab must execute each resampling unit in its own process")

    primary_metrics = {
        metric
        for section in ("memoryWorkloads", "diskWorkloads")
        for workload in plan.get(section, {}).values()
        for metric in workload.get("primaryMetrics", [])
    }
    rules = plan.get("metricDecisionRules", {})
    if set(rules) != primary_metrics:
        fail("every Cache Lab primary metric must have exactly one decision rule")
    for metric, rule in rules.items():
        if rule.get("scale") not in {"absolute-difference", "log-ratio"}:
            fail(f"{metric}: invalid decision scale")
        if rule.get("direction") not in {"higher", "lower"}:
            fail(f"{metric}: invalid metric direction")
        margins = [
            rule.get("equivalenceMargin"),
            rule.get("nonInferiorityMargin"),
            rule.get("superiorityMargin"),
            rule.get("dominanceMargin"),
        ]
        if not all(isinstance(value, (int, float)) and value > 0 for value in margins):
            fail(f"{metric}: all decision margins must be positive")
        minimum_dominance = 0.05 if rule.get("scale") == "absolute-difference" else 0.20
        if float(rule["dominanceMargin"]) < minimum_dominance:
            fail(f"{metric}: dominance margin is below the preregistered substantial-lead floor")

    expected = {"LRUCache", "PINCache"}
    items = {item["name"]: item for item in lock.get("comparators", [])}
    if set(items) != expected:
        fail("Cache Lab lock must contain LRUCache and PINCache")
    for name, item in items.items():
        source = ROOT / ".artifacts/cache-comparators/sources" / name
        head = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            text=True,
            capture_output=True,
            check=False,
        )
        if head.returncode != 0 or head.stdout.strip() != item["exactCommit"]:
            fail(f"{name} checkout differs from Cache Lab lock")
        dirty = subprocess.run(
            ["git", "-C", str(source), "status", "--porcelain"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        if dirty:
            fail(f"{name} Cache Lab checkout is dirty")

    resolved = json.loads(RESOLVED.read_text())
    pins = {pin["identity"]: pin for pin in resolved.get("pins", [])}
    operation = pins.get("pinoperation", {}).get("state", {})
    if operation.get("version") != "1.2.3" or operation.get("revision") != "a74f978733bdaf982758bfa23d70a189f4b4c1b6":
        fail("PINOperation transitive dependency is not exactly locked")
    required_files = [
        "Benchmarks/CacheLab/Sources/CacheLabCore/CacheContestants.swift",
        "Benchmarks/CacheLab/Sources/CacheLabCore/PINDurableValidatedDiskContestant.swift",
        "Benchmarks/CacheLab/Sources/CacheLabCore/CacheWorkloads.swift",
        "Benchmarks/CacheLab/Tests/CacheLabTests/CacheLabTests.swift",
        "scripts/analyze-cache-lab.py",
        "scripts/run-cache-lab.py",
        "scripts/cache_lab_host_monitor.py",
        "scripts/test-cache-lab-host-monitor.py",
        "scripts/test-cache-lab-formal-process-model.py",
        "scripts/test-cache-lab-source-identity.py",
        "Benchmarks/CacheLab/Sources/CacheLabCore/CacheLabReport.swift",
        "Benchmarks/CacheLab/Sources/CacheLabRunner/CacheLabMain.swift",
    ]
    if any(not (ROOT / path).is_file() for path in required_files):
        fail("Cache Lab V4 implementation is incomplete")

    digest = hashlib.sha256(canonical(plan)).hexdigest()
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(
        json.dumps(
            {
                "schemaVersion": 4,
                "planID": plan["planID"],
                "planSHA256": digest,
                "archivedPlanV3SHA256": hashlib.sha256(canonical(archived_v3)).hexdigest(),
                "archivedPlanV2SHA256": hashlib.sha256(canonical(archived_v2)).hexdigest(),
                "archivedPlanV1SHA256": hashlib.sha256(canonical(archived_v1)).hexdigest(),
                "comparators": sorted(items),
                "status": "passed",
            },
            indent=2,
            sort_keys=True,
        ) + "\n"
    )
    print(f"Cache Lab plan valid: {plan['planID']} sha256:{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
