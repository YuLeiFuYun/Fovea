#!/usr/bin/env python3
"""Validate the retained ImageIO decode resource lifetime ledger against source anchors."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

from component_paths import ComponentPathError, resolve_reference

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "docs/research/imageio-decode-resource-lifetime-ledger.json"
ARTIFACT = ROOT / ".artifacts/resource-envelope/imageio-lifetime-ledger-verification.json"


def canonical_digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def load() -> dict[str, Any]:
    value = json.loads(LEDGER.read_text())
    if not isinstance(value, dict):
        raise TypeError("lifetime ledger must contain an object")
    return value


def main() -> int:
    document = load()
    errors: list[str] = []

    if document.get("schemaVersion") != 1:
        errors.append("unexpected schemaVersion")
    if document.get("ledgerID") != "FOVEA-IMAGEIO-DECODE-RESOURCE-LIFETIME-V1":
        errors.append("unexpected ledgerID")
    if document.get("status") != "static-audit-retained-measurement-pending":
        errors.append("ledger status must preserve measurement-pending limitation")

    subject = document.get("subject", {})
    for relative in subject.get("sourcePaths", []):
        if not isinstance(relative, str):
            errors.append(f"missing subject source: {relative}")
            continue
        try:
            path = resolve_reference(relative)
        except ComponentPathError as error:
            errors.append(f"subject source resolution failed: {relative}: {error}")
            continue
        if not path.is_file():
            errors.append(f"missing subject source: {relative}")

    anchors = document.get("codeAnchors", [])
    if not isinstance(anchors, list) or len(anchors) < 7:
        errors.append("at least seven code anchors are required")
        anchors = []
    for anchor in anchors:
        if not isinstance(anchor, dict):
            errors.append("code anchor must be an object")
            continue
        reference = str(anchor.get("path", ""))
        try:
            path = resolve_reference(reference)
        except ComponentPathError as error:
            errors.append(f"anchor path resolution failed: {reference}: {error}")
            continue
        text = str(anchor.get("anchor", ""))
        if not path.is_file():
            errors.append(f"anchor path missing: {reference}")
            continue
        if not text or text not in path.read_text():
            errors.append(f"anchor drifted: {anchor.get('path')} :: {text}")

    resources = document.get("resources", [])
    resource_ids: set[str] = set()
    required_resource_fields = {
        "id",
        "owner",
        "physicalIdentity",
        "sizeModel",
        "currentWorkingSetCoverage",
        "lifetime",
        "evidenceClass",
    }
    for resource in resources:
        if not isinstance(resource, dict):
            errors.append("resource entry must be an object")
            continue
        missing = required_resource_fields - resource.keys()
        identifier = resource.get("id")
        if missing:
            errors.append(f"resource {identifier}: missing {sorted(missing)}")
        if not isinstance(identifier, str) or not identifier or identifier in resource_ids:
            errors.append(f"invalid or duplicate resource id: {identifier}")
        else:
            resource_ids.add(identifier)
        for field in required_resource_fields - {"id"}:
            if not isinstance(resource.get(field), str) or len(resource[field].strip()) < 4:
                errors.append(f"resource {identifier}: invalid {field}")

    required_resources = {
        "encoded-input-data",
        "imageio-source",
        "preparation-registry-entry",
        "thumbnail-surface",
        "imageio-private-raster-scratch",
        "color-conversion-context",
        "final-output-surface",
    }
    missing_resources = required_resources - resource_ids
    if missing_resources:
        errors.append(f"required resources missing: {sorted(missing_resources)}")

    phases = document.get("phases", [])
    phase_ids: set[str] = set()
    required_phase_fields = {"id", "begins", "ends", "permit", "liveResourceIDs", "notes"}
    for phase in phases:
        if not isinstance(phase, dict):
            errors.append("phase entry must be an object")
            continue
        missing = required_phase_fields - phase.keys()
        identifier = phase.get("id")
        if missing:
            errors.append(f"phase {identifier}: missing {sorted(missing)}")
        if not isinstance(identifier, str) or not identifier or identifier in phase_ids:
            errors.append(f"invalid or duplicate phase id: {identifier}")
        else:
            phase_ids.add(identifier)
        live = phase.get("liveResourceIDs", [])
        if not isinstance(live, list) or not live:
            errors.append(f"phase {identifier}: liveResourceIDs must be nonempty")
        else:
            unknown = set(live) - resource_ids
            if unknown:
                errors.append(f"phase {identifier}: unknown resources {sorted(unknown)}")

    required_phases = {
        "inspection",
        "prepared-wait",
        "raster-create",
        "color-normalize",
        "result-transfer",
        "operation-boundary-cancellation",
    }
    missing_phases = required_phases - phase_ids
    if missing_phases:
        errors.append(f"required phases missing: {sorted(missing_phases)}")

    gaps = document.get("requiredGaps", [])
    gap_ids = {
        gap.get("id") for gap in gaps if isinstance(gap, dict) and isinstance(gap.get("id"), str)
    }
    required_gaps = {
        "prepared-state-outlives-probe-permit",
        "framework-private-allocation-unbounded",
        "final-output-transfer-not-explicit",
        "alias-and-branch-composition-implicit",
        "operation-boundary-reclaim-tail-unmeasured",
    }
    if gap_ids != required_gaps:
        errors.append(
            "required gap set drifted: "
            f"missing={sorted(required_gaps - gap_ids)} unexpected={sorted(gap_ids - required_gaps)}"
        )
    for gap in gaps:
        if not isinstance(gap, dict):
            continue
        if gap.get("severity") not in {"medium", "high", "critical"}:
            errors.append(f"gap {gap.get('id')}: invalid severity")
        if not isinstance(gap.get("closure"), str) or len(gap["closure"].strip()) < 24:
            errors.append(f"gap {gap.get('id')}: closure criterion is missing")

    policy = document.get("admissionPolicy", {})
    if policy.get("secondBackendProductionQualified") != (
        "forbidden-until-required-gaps-closed-or-waived-by-explicit-adr"
    ):
        errors.append("second backend production qualification must remain fail closed")
    if policy.get("defaultBackendChange") != "forbidden":
        errors.append("default backend change must remain forbidden")

    result = {
        "schemaVersion": 1,
        "ledgerID": document.get("ledgerID"),
        "ledgerSHA256": canonical_digest(document),
        "phaseCount": len(phases),
        "resourceCount": len(resources),
        "gapCount": len(gaps),
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "ImageIO resource lifetime ledger: "
        f"phases={len(phases)} resources={len(resources)} gaps={len(gaps)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
