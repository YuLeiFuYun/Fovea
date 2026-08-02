#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import cache_lab_host_monitor as host_monitor

ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "scripts/analyze-cache-lab.py"
PLAN = ROOT / "Benchmarks/CacheLab/cache-plan.json"
CLAIMS = ROOT / "Benchmarks/statistical-claim-families.json"


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def identity(*, mode: str, dirty: bool, revision: str | None = None) -> str:
    value: dict[str, Any] = {
        "commit": "1" * 40,
        "sourceTreeDigest": "2" * 64,
        "includesWorkingTreeChanges": dirty,
        "dependencyMode": mode,
    }
    if revision is not None:
        value["declaredRevision"] = revision
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def host_evidence(*, contaminated: bool = False) -> dict[str, Any]:
    return {
        "schemaVersion": host_monitor.POLICY_SCHEMA_VERSION,
        "policyID": host_monitor.POLICY_ID,
        "runnerExecution": {
            "directBinary": True,
            "buildExcludedFromMeasurement": True,
            "completed": True,
            "processModel": "single-calibration-process",
        },
        "preflight": {
            "requiredCleanSamples": 0,
            "observedConsecutiveCleanSamples": 1,
            "observedSamples": 1,
            "sampleIntervalMilliseconds": 1000,
            "timeoutSeconds": 0,
            "passed": True,
            "externalProcesses": [],
        },
        "monitor": {
            "coveredEntireRunner": True,
            "sampleCount": 1,
            "contaminatedSampleCount": 1 if contaminated else 0,
            "sampleIntervalMilliseconds": 1000,
            "durationMilliseconds": 1,
            "contaminated": contaminated,
            "abortedForContamination": False,
            "timedOut": False,
            "externalProcesses": [],
        },
        "quiescentHostBound": not contaminated,
    }


def report(
    schema: int,
    source_identity: dict[str, str],
    *,
    execution_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    checks = [{"identifier": "fixture-correctness", "passed": True, "value": 0}]
    return {
        "schemaVersion": schema,
        "planID": "FOVEA-CACHE-LAB-V4",
        "executionMode": "calibration",
        "benchmarkScope": "hot",
        "provisional": True,
        "sourceIdentity": source_identity,
        "hostExecutionEvidence": execution_evidence or host_evidence(),
        "experimentPlanDigest": canonical_digest(PLAN),
        "claimFamilyDigest": canonical_digest(CLAIMS),
        "diskCorrectness": [],
        "runs": [
            {
                "repetition": 1,
                "memoryHotScan": [
                    {
                        "contestant": "Fovea",
                        "hotHits": 32,
                        "hotObjectCount": 32,
                        "operations": 4_128,
                        "durationNanoseconds": 1_000_000,
                        "p99OperationNanoseconds": 100,
                        "checks": checks,
                    },
                    {
                        "contestant": "LRUCache",
                        "hotHits": 16,
                        "hotObjectCount": 32,
                        "operations": 4_128,
                        "durationNanoseconds": 2_000_000,
                        "p99OperationNanoseconds": 200,
                        "checks": checks,
                    },
                ],
                "memoryConcurrent": [],
                "diskMixed": [],
            }
        ],
    }


def analyze(value: dict[str, Any], directory: Path, label: str) -> dict[str, Any]:
    source = directory / f"{label}-raw.json"
    output = directory / f"{label}-analysis.json"
    source.write_text(json.dumps(value, sort_keys=True) + "\n")
    subprocess.run(
        ["python3", str(ANALYZER), "--input", str(source), "--output", str(output)],
        cwd=ROOT,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return json.loads(output.read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="cache-lab-source-identity-") as raw_directory:
        directory = Path(raw_directory)
        fovea_dirty = identity(mode="root-worktree", dirty=True)
        fovea_clean = identity(mode="root-worktree", dirty=False)
        akashic_edited = identity(mode="edited", dirty=True, revision="1" * 40)
        akashic_clean = identity(
            mode="source-control-checkout", dirty=False, revision="1" * 40
        )
        akashic_mismatch = identity(
            mode="source-control-checkout", dirty=False, revision="3" * 40
        )

        legacy = analyze(report(3, {"Fovea": fovea_dirty}), directory, "legacy")
        require(not legacy["sourceIdentityBound"], "schema 3 must remain source-identity-unbound")
        require(
            "component-source-identity-invalid-or-unbound" in legacy["bestClaimBlockedReasons"],
            "schema 3 must be explicitly downgraded",
        )

        edited = analyze(
            report(4, {"Fovea": fovea_dirty, "Akashic": akashic_edited}),
            directory,
            "edited",
        )
        require(edited["sourceIdentityBound"], "schema 4 must bind both component identities")
        require(not edited["sourceResolutionBound"], "edited Akashic must not be trusted resolution")
        require(
            "dependency-resolution-untrusted-or-edited" in edited["bestClaimBlockedReasons"],
            "edited Akashic must block a trusted certificate",
        )

        clean = analyze(
            report(4, {"Fovea": fovea_clean, "Akashic": akashic_clean}),
            directory,
            "clean",
        )
        require(clean["sourceIdentityBound"], "clean schema 4 identities must bind")
        require(clean["sourceResolutionBound"], "exact Akashic checkout must bind resolution")
        require(clean["trustedCleanSource"], "clean exact component sources must be trusted")
        require(clean["hostExecutionEvidenceBound"], "schema 4 must bind host execution evidence")
        require(clean["quiescentHostBound"], "clean monitored host evidence must bind")
        require(not clean["bestClaimEligible"], "calibration must never become a formal certificate")

        contaminated = analyze(
            report(
                4,
                {"Fovea": fovea_clean, "Akashic": akashic_clean},
                execution_evidence=host_evidence(contaminated=True),
            ),
            directory,
            "contaminated",
        )
        require(
            contaminated["hostExecutionEvidenceBound"],
            "contaminated evidence must remain structurally bound",
        )
        require(
            not contaminated["quiescentHostBound"],
            "contaminated measurement must not bind a quiescent host",
        )
        require(
            "benchmark-host-contaminated-or-not-quiescent"
            in contaminated["bestClaimBlockedReasons"],
            "host contamination must block the claim",
        )

        mismatch = analyze(
            report(4, {"Fovea": fovea_clean, "Akashic": akashic_mismatch}),
            directory,
            "mismatch",
        )
        require(
            not mismatch["sourceResolutionBound"],
            "declared Akashic revision mismatch must invalidate source resolution",
        )

    print("Cache Lab source and host identity policy regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
