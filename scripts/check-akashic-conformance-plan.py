#!/usr/bin/env python3
"""Validate the named Akashic component and Fovea-host conformance obligations."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "docs/project-memory/akashic-conformance-plan.json"
ARTIFACT = ROOT / ".artifacts/project-memory/akashic-conformance-plan-verification.json"


def canonical_digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def main() -> int:
    document: dict[str, Any] = json.loads(PLAN.read_text())
    errors: list[str] = []

    if document.get("schemaVersion") != 1:
        errors.append("unexpected schemaVersion")
    if document.get("planID") != "AKASHIC-CONFORMANCE-PLAN-V1":
        errors.append("unexpected planID")
    if document.get("status") != "component-and-host-public-ci-evidence-physical-release-pending":
        errors.append("plan must preserve public-CI and physical-release distinction")
    if document.get("independentEvidenceRole") != "retained-pre-publication-qualification-not-current-pin-identity":
        errors.append("retained independent evidence role drifted")

    for key in ("contract", "migration", "independentEvidence"):
        relative = document.get(key)
        if not isinstance(relative, str) or not (ROOT / relative).is_file():
            errors.append(f"missing {key} file: {relative}")

    rules = document.get("rules", {})
    expected_rules = {
        "componentEvidenceDoesNotReplaceHostEvidence": True,
        "cacheMissDoesNotEraseStructuredStorageFailure": True,
        "crossPartitionDeduplicationDefault": "forbidden",
        "writerModel": "single-active-writer-per-store-generation",
        "diskMigration": "new-store-generation-rebuildable-cache",
        "unboundedEnumeration": "forbidden",
    }
    for key, expected in expected_rules.items():
        if rules.get(key) != expected:
            errors.append(f"rule {key} drifted: {rules.get(key)!r}")

    obligations = document.get("obligations", [])
    ids: list[str] = []
    families: set[str] = set()
    phases: set[str] = set()
    required_fields = {"id", "family", "phase", "name", "requirement", "evidence", "status"}
    for item in obligations:
        if not isinstance(item, dict):
            errors.append("obligation must be an object")
            continue
        missing = required_fields - item.keys()
        identifier = item.get("id")
        if missing:
            errors.append(f"{identifier}: missing {sorted(missing)}")
        if not isinstance(identifier, str) or identifier in ids:
            errors.append(f"invalid or duplicate obligation id: {identifier}")
        else:
            ids.append(identifier)
        family = item.get("family")
        phase = item.get("phase")
        if not isinstance(family, str) or not family:
            errors.append(f"{identifier}: family missing")
        else:
            families.add(family)
        if phase not in {"P3", "P4", "P5", "P6"}:
            errors.append(f"{identifier}: invalid phase {phase}")
        else:
            phases.add(phase)
        if not isinstance(item.get("name"), str) or len(item["name"]) < 8:
            errors.append(f"{identifier}: name too short")
        if not isinstance(item.get("requirement"), str) or len(item["requirement"]) < 40:
            errors.append(f"{identifier}: requirement too short")
        evidence = item.get("evidence")
        if not isinstance(evidence, list) or not evidence or not all(
            isinstance(value, str) and value for value in evidence
        ):
            errors.append(f"{identifier}: evidence must be a nonempty string list")
        evidence_path = ROOT / document["independentEvidence"]
        independent_evidence = json.loads(evidence_path.read_text())
        expected_status = independent_evidence.get("obligationStatuses", {}).get(identifier)
        if expected_status is None:
            errors.append(f"{identifier}: independent evidence has no status")
            expected_status = "missing"
        if item.get("status") != expected_status:
            errors.append(
                f"{identifier}: expected status {expected_status}, got {item.get('status')}"
            )

    evidence_path = ROOT / document["independentEvidence"]
    independent_evidence = json.loads(evidence_path.read_text())
    expected_evidence_status = (
        "passed-local-committed-typed-fovea-default-domain-boundary-"
        "legacy-removal-exact-mirror-and-revision-rehearsal-nonrelease"
    )
    if independent_evidence.get("status") != expected_evidence_status:
        errors.append("independent evidence status drifted")
    subject = independent_evidence.get("subject", {})
    head = subject.get("head")
    if not isinstance(head, str) or len(head) != 40:
        errors.append("independent repository must record a full committed head")
    if subject.get("dirty") is not False:
        errors.append("independent repository must remain recorded as clean")
    migration = json.loads((ROOT / document["migration"]).read_text())
    if head != document.get("retainedEvidenceCommit"):
        errors.append("retained independent evidence commit drifted")
    if subject.get("remoteConfigured") is not False:
        errors.append("retained pre-publication evidence must preserve its original no-remote fact")
    pin_path = ROOT / str(document.get("currentPinRegistry", ""))
    if not pin_path.is_file():
        errors.append("current component pin registry is missing")
        current_pin = None
        current_tag = None
    else:
        pins = json.loads(pin_path.read_text())
        current_component = pins.get("components", {}).get("Akashic", {})
        current_pin = current_component.get("revision")
        current_tag = current_component.get("releaseTag")
    current_package = migration.get("independentPackage", {})
    if current_package.get("commit") != current_pin:
        errors.append("migration current Akashic commit differs from exact component pin")
    if current_package.get("remoteConfigured") is not True:
        errors.append("current Akashic package must record its public remote")
    if current_package.get("tagged") is not True or current_package.get("tag") != current_tag:
        errors.append("migration current Akashic tag differs from exact component pin registry")
    public_ci = current_package.get("publicCI")
    if not isinstance(public_ci, dict):
        errors.append("current Akashic public CI record must be structured")
    else:
        if public_ci.get("status") != "passed":
            errors.append("current Akashic public CI record is not passed")
        if public_ci.get("scope") != "main-current-pin":
            errors.append("current Akashic public CI record is not bound to main current pin")
        if public_ci.get("runner") != "xcode-27":
            errors.append("current Akashic Swift 6.4 CI must use the explicit xcode-27 runner")
        if public_ci.get("commit") != current_pin:
            errors.append("current Akashic public CI commit differs from exact component pin")
        if not isinstance(public_ci.get("runID"), int) or public_ci["runID"] <= 0:
            errors.append("current Akashic public CI run ID is missing")
    if independent_evidence.get("localGates", {}).get("processCrashMatrix", {}).get("powerLossClaim") is not False:
        errors.append("process crash evidence must not imply power-loss evidence")
    for host_id in ("AKASHIC-CT-022", "AKASHIC-CT-023", "AKASHIC-CT-024", "AKASHIC-CT-025", "AKASHIC-CT-026"):
        if independent_evidence.get("obligationStatuses", {}).get(host_id) != "implemented-host-local":
            errors.append(f"{host_id}: Fovea host obligation must remain implemented-host-local")

    expected_ids = [f"AKASHIC-CT-{number:03d}" for number in range(1, 31)]
    if ids != expected_ids:
        errors.append(
            "obligation ID sequence drifted: "
            f"expected={expected_ids} actual={ids}"
        )

    required_families = {
        "identity",
        "transaction",
        "deduplication",
        "integrity",
        "durability",
        "generation",
        "corruption",
        "filesystem-security",
        "resource",
        "concurrency",
        "host-adapter",
        "host-transaction",
        "host-revocation",
        "host-degradation",
        "host-security",
        "memory-cache",
        "release-governance",
    }
    if families != required_families:
        errors.append(
            "conformance family set drifted: "
            f"missing={sorted(required_families - families)} "
            f"unexpected={sorted(families - required_families)}"
        )
    if phases != {"P3", "P4", "P5", "P6"}:
        errors.append(f"conformance phases incomplete: {sorted(phases)}")

    exits = document.get("phaseExitRequirements", {})
    if set(exits) != {"P3", "P4", "P5", "P6"}:
        errors.append("phaseExitRequirements must cover P3 through P6")
    for phase, requirements in exits.items():
        if not isinstance(requirements, list) or len(requirements) < 2:
            errors.append(f"{phase}: exit requirements incomplete")

    result = {
        "schemaVersion": 1,
        "planID": document.get("planID"),
        "planSHA256": canonical_digest(document),
        "obligationCount": len(obligations),
        "familyCount": len(families),
        "phaseCount": len(phases),
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic conformance plan: "
        f"obligations={len(obligations)} families={len(families)} phases={len(phases)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
