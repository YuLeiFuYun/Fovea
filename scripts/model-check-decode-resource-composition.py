#!/usr/bin/env python3
"""Retain counterexamples for decode resource composition before a second codec is admitted."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from component_paths import ComponentPathError, resolve_reference

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "docs/research/decode-resource-composition-model.json"
AUDIT = ROOT / "docs/research/decode-resource-contract-audit-2026-07.md"
ARTIFACT = ROOT / ".artifacts/resource-contract/decode-resource-composition.json"


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain an object")
    return value


def canonical_digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def peak(allocations: list[dict[str, Any]], selected: set[str] | None = None) -> int:
    relevant = [item for item in allocations if selected is None or item["id"] in selected]
    boundaries = sorted({point for item in relevant for point in (item["start"], item["end"])})
    if len(boundaries) < 2:
        return 0
    result = 0
    for left, right in zip(boundaries, boundaries[1:]):
        if right <= left:
            continue
        active = sum(
            item["bytes"]
            for item in relevant
            if item["start"] < right and item["end"] > left
        )
        result = max(result, active)
    return result


def classify(estimate: int, actual: int) -> str:
    if estimate < actual:
        return "under"
    if estimate > actual:
        return "over"
    return "exact"


def main() -> int:
    model = load(MODEL)
    errors: list[str] = []
    results: list[dict[str, Any]] = []
    case_ids: set[str] = set()
    max_under = 0
    max_exact = 0
    sum_over = 0
    partial_overlap_seen = False

    if model.get("modelID") != "FOVEA-DECODE-RESOURCE-COMPOSITION-MODEL-V1":
        errors.append("unexpected model identity")
    implementation = model.get("currentImplementation", {})
    try:
        code_path = resolve_reference(implementation.get("codePath", ""))
    except ComponentPathError as error:
        errors.append(f"current implementation path could not be resolved: {error}")
        code_path = Path("/__invalid_component_path__")
    fragment = implementation.get("codeFragment", "")
    if not code_path.is_file() or fragment not in code_path.read_text():
        errors.append("current max-reported-totals implementation binding drifted")
    if "不得让第二个 codec 获得默认生产准入" not in AUDIT.read_text():
        errors.append("audit no longer preserves the interim second-codec admission gate")

    for case in model.get("cases", []):
        identifier = case.get("id")
        if not isinstance(identifier, str) or identifier in case_ids:
            errors.append(f"invalid or duplicate case ID: {identifier}")
            continue
        case_ids.add(identifier)
        allocations = case.get("allocations", [])
        allocation_ids = {item.get("id") for item in allocations}
        if None in allocation_ids or len(allocation_ids) != len(allocations):
            errors.append(f"{identifier}: invalid allocation IDs")
            continue
        for item in allocations:
            if not isinstance(item.get("bytes"), int) or item["bytes"] <= 0:
                errors.append(f"{identifier}: allocation bytes must be positive")
            if not isinstance(item.get("start"), int) or not isinstance(item.get("end"), int) or item["end"] <= item["start"]:
                errors.append(f"{identifier}: invalid allocation interval for {item.get('id')}")
        generic = set(case.get("genericCovers", []))
        backend = set(case.get("backendCovers", []))
        unknown = (generic | backend) - allocation_ids
        if unknown:
            errors.append(f"{identifier}: unknown covered allocations {sorted(unknown)}")
            continue

        true_peak = peak(allocations)
        generic_peak = peak(allocations, generic)
        backend_peak = peak(allocations, backend)
        max_reported = max(generic_peak, backend_peak)
        sum_reported = generic_peak + backend_peak
        union_reported = peak(allocations, generic | backend)
        max_classification = classify(max_reported, true_peak)
        sum_classification = classify(sum_reported, true_peak)
        union_classification = classify(union_reported, true_peak)

        expected = case.get("expected", {})
        observed = {
            "truePeak": true_peak,
            "genericReported": generic_peak,
            "backendReported": backend_peak,
            "maxReported": max_reported,
            "sumReported": sum_reported,
            "unionReported": union_reported,
            "maxClassification": max_classification,
            "sumClassification": sum_classification,
            "unionClassification": union_classification,
        }
        for key in ("truePeak", "maxReported", "sumReported", "unionReported", "maxClassification"):
            if observed[key] != expected.get(key):
                errors.append(f"{identifier}: {key} expected={expected.get(key)} observed={observed[key]}")

        max_under += int(max_classification == "under")
        max_exact += int(max_classification == "exact")
        sum_over += int(sum_classification == "over")
        partial_overlap_seen = partial_overlap_seen or identifier == "partial-overlap"
        results.append({"id": identifier, **observed})

    required = model.get("requiredWitnesses", {})
    if max_under < required.get("maxUnderReportCasesAtLeast", 0):
        errors.append("insufficient retained max under-report witnesses")
    if max_exact < required.get("maxExactCasesAtLeast", 0):
        errors.append("insufficient retained max exact witnesses")
    if sum_over < required.get("sumOverReportCasesAtLeast", 0):
        errors.append("insufficient retained sum over-report witnesses")
    if required.get("partialOverlapCaseRequired") is True and not partial_overlap_seen:
        errors.append("partial-overlap witness is required")

    artifact = {
        "schemaVersion": 1,
        "modelID": model.get("modelID"),
        "modelSHA256": canonical_digest(model),
        "status": "failed" if errors else "passed",
        "caseCount": len(results),
        "maxUnderReportWitnesses": max_under,
        "maxExactWitnesses": max_exact,
        "sumOverReportWitnesses": sum_over,
        "results": results,
        "errors": errors,
        "conclusion": "max-reported-totals is conditionally valid only when coverage and lifetime premises are explicit",
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(artifact, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(
        "Decode resource composition: "
        f"cases={len(results)} max_under={max_under} max_exact={max_exact} "
        f"sum_over={sum_over} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
