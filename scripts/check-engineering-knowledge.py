#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = ROOT / "docs/engineering-knowledge.json"
SCHEMA_PATH = ROOT / "docs/schemas/engineering-knowledge.schema.json"
TRACEABILITY_PATH = ROOT / "docs/test-traceability.json"

LAW_ID = re.compile(r"^FOVEA-LAW-(\d{3})$")
EGG_ID = re.compile(r"^FOVEA-EGG-(\d{3})$")
CONTROL_CHARACTER = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

ALLOWED_DISCIPLINES = {
    "accounting",
    "chemistry",
    "complexity-science",
    "computer-science",
    "control-theory",
    "cybernetics",
    "design-science",
    "distributed-systems",
    "dynamical-systems",
    "ecology",
    "economics",
    "evidence-based-medicine",
    "evolutionary-biology",
    "experimental-science",
    "formal-methods",
    "image-science",
    "information-theory",
    "innovation-studies",
    "literature",
    "mathematics",
    "mechanism-design",
    "network-science",
    "operations-research",
    "organizational-theory",
    "philosophy",
    "philosophy-of-science",
    "physics",
    "resource-economics",
    "safety-engineering",
    "scientific-method",
    "security-engineering",
    "sociology",
    "software-architecture",
    "software-testing",
    "system-identification",
    "temporal-logic",
    "thermodynamics",
    "transaction-processing",
}

PRINCIPLE_STATUSES = {"operational", "experimental", "hypothesis", "retired"}
DISCOVERY_STATUSES = {"promoted", "deferred", "rejected", "retired"}

errors: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read valid JSON from {path.relative_to(ROOT)}: {error}")
        return {}


def require_dict(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
        return {}
    return value


def require_list(value: Any, label: str, *, nonempty: bool = False) -> list[Any]:
    if not isinstance(value, list):
        fail(f"{label} must be an array")
        return []
    if nonempty and not value:
        fail(f"{label} must not be empty")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
        return ""
    if value != value.strip():
        fail(f"{label} must not contain leading or trailing whitespace")
    if CONTROL_CHARACTER.search(value):
        fail(f"{label} contains a control character")
    return value


def string_list(value: Any, label: str, *, nonempty: bool = False) -> list[str]:
    raw = require_list(value, label, nonempty=nonempty)
    result: list[str] = []
    for index, item in enumerate(raw):
        text = require_string(item, f"{label}[{index}]")
        if text:
            result.append(text)
    if len(result) != len(set(result)):
        fail(f"{label} contains duplicate values")
    return result


def repository_path(raw: str, label: str) -> Path | None:
    path = (ROOT / raw).resolve()
    try:
        path.relative_to(ROOT.resolve())
    except ValueError:
        fail(f"{label} escapes the repository: {raw}")
        return None
    if not path.exists():
        fail(f"{label} does not exist: {raw}")
        return None
    return path


def require_exact_keys(value: dict[str, Any], required: set[str], label: str) -> None:
    missing = sorted(required - value.keys())
    extra = sorted(value.keys() - required)
    if missing:
        fail(f"{label} is missing fields: {', '.join(missing)}")
    if extra:
        fail(f"{label} has unsupported fields: {', '.join(extra)}")


registry = require_dict(load_json(REGISTRY_PATH), "engineering registry")
load_json(SCHEMA_PATH)
traceability = require_dict(load_json(TRACEABILITY_PATH), "test traceability")
traceability_ids = {
    entry.get("id")
    for entry in require_list(traceability.get("requirements"), "traceability.requirements")
    if isinstance(entry, dict) and isinstance(entry.get("id"), str)
}

require_exact_keys(
    registry,
    {"schemaVersion", "document", "principles", "discoveries"},
    "engineering registry",
)
if registry.get("schemaVersion") != 1:
    fail("engineering registry schemaVersion must equal 1")

document_raw = require_string(registry.get("document"), "engineering registry document")
document_path = repository_path(document_raw, "engineering registry document")
document_text = document_path.read_text() if document_path and document_path.is_file() else ""

principles = require_list(registry.get("principles"), "principles", nonempty=True)
discoveries = require_list(registry.get("discoveries"), "discoveries")
principle_ids: set[str] = set()
principle_numbers: list[int] = []

principle_fields = {
    "id",
    "title",
    "disciplines",
    "status",
    "claim",
    "applicability",
    "invariants",
    "falsifiers",
    "limits",
    "metrics",
    "evidence",
}

for index, raw_principle in enumerate(principles):
    label = f"principles[{index}]"
    principle = require_dict(raw_principle, label)
    require_exact_keys(principle, principle_fields, label)
    identifier = require_string(principle.get("id"), f"{label}.id")
    match = LAW_ID.fullmatch(identifier)
    if not match:
        fail(f"{label}.id must match FOVEA-LAW-NNN")
    else:
        principle_numbers.append(int(match.group(1)))
    if identifier in principle_ids:
        fail(f"duplicate principle id: {identifier}")
    principle_ids.add(identifier)
    if document_text.count(identifier) != 1:
        fail(f"{identifier} must appear exactly once in {document_raw}")

    require_string(principle.get("title"), f"{label}.title")
    disciplines = string_list(principle.get("disciplines"), f"{label}.disciplines", nonempty=True)
    unknown_disciplines = sorted(set(disciplines) - ALLOWED_DISCIPLINES)
    if unknown_disciplines:
        fail(f"{label}.disciplines contains unsupported values: {', '.join(unknown_disciplines)}")
    status = require_string(principle.get("status"), f"{label}.status")
    if status not in PRINCIPLE_STATUSES:
        fail(f"{label}.status must be one of {sorted(PRINCIPLE_STATUSES)}")
    require_string(principle.get("claim"), f"{label}.claim")
    string_list(principle.get("applicability"), f"{label}.applicability", nonempty=True)
    string_list(principle.get("invariants"), f"{label}.invariants", nonempty=True)
    string_list(principle.get("falsifiers"), f"{label}.falsifiers", nonempty=True)
    string_list(principle.get("limits"), f"{label}.limits", nonempty=True)

    metrics = require_list(principle.get("metrics"), f"{label}.metrics", nonempty=True)
    metric_names: set[str] = set()
    for metric_index, raw_metric in enumerate(metrics):
        metric_label = f"{label}.metrics[{metric_index}]"
        metric = require_dict(raw_metric, metric_label)
        require_exact_keys(metric, {"name", "target"}, metric_label)
        name = require_string(metric.get("name"), f"{metric_label}.name")
        require_string(metric.get("target"), f"{metric_label}.target")
        if name in metric_names:
            fail(f"{label}.metrics contains duplicate name: {name}")
        metric_names.add(name)

    evidence = require_dict(principle.get("evidence"), f"{label}.evidence")
    require_exact_keys(evidence, {"testIDs", "paths"}, f"{label}.evidence")
    test_ids = string_list(evidence.get("testIDs"), f"{label}.evidence.testIDs", nonempty=True)
    paths = string_list(evidence.get("paths"), f"{label}.evidence.paths", nonempty=True)
    for test_id in test_ids:
        if test_id not in traceability_ids:
            fail(f"{label} references unknown traceability id: {test_id}")
    for path_index, raw_path in enumerate(paths):
        repository_path(raw_path, f"{label}.evidence.paths[{path_index}]")

if principle_numbers and principle_numbers != list(range(1, len(principle_numbers) + 1)):
    fail("principle IDs must be ordered and contiguous from FOVEA-LAW-001")

discovery_fields = {
    "id",
    "title",
    "status",
    "triggerProblem",
    "observation",
    "extractedAsset",
    "principleIDs",
    "artifactPaths",
    "evidencePaths",
    "evidenceTestIDs",
    "transferBoundary",
    "overgeneralizationRisk",
}
discovery_ids: set[str] = set()
discovery_numbers: list[int] = []

for index, raw_discovery in enumerate(discoveries):
    label = f"discoveries[{index}]"
    discovery = require_dict(raw_discovery, label)
    require_exact_keys(discovery, discovery_fields, label)
    identifier = require_string(discovery.get("id"), f"{label}.id")
    match = EGG_ID.fullmatch(identifier)
    if not match:
        fail(f"{label}.id must match FOVEA-EGG-NNN")
    else:
        discovery_numbers.append(int(match.group(1)))
    if identifier in discovery_ids:
        fail(f"duplicate discovery id: {identifier}")
    discovery_ids.add(identifier)
    if document_text.count(identifier) != 1:
        fail(f"{identifier} must appear exactly once in {document_raw}")

    require_string(discovery.get("title"), f"{label}.title")
    status = require_string(discovery.get("status"), f"{label}.status")
    if status not in DISCOVERY_STATUSES:
        fail(f"{label}.status must be one of {sorted(DISCOVERY_STATUSES)}")
    require_string(discovery.get("triggerProblem"), f"{label}.triggerProblem")
    require_string(discovery.get("observation"), f"{label}.observation")
    require_string(discovery.get("extractedAsset"), f"{label}.extractedAsset")
    principle_references = string_list(
        discovery.get("principleIDs"), f"{label}.principleIDs", nonempty=True
    )
    for principle_id in principle_references:
        if principle_id not in principle_ids:
            fail(f"{label} references unknown principle: {principle_id}")
    artifact_paths = string_list(discovery.get("artifactPaths"), f"{label}.artifactPaths")
    evidence_paths = string_list(discovery.get("evidencePaths"), f"{label}.evidencePaths")
    evidence_test_ids = string_list(
        discovery.get("evidenceTestIDs"), f"{label}.evidenceTestIDs"
    )
    require_string(discovery.get("transferBoundary"), f"{label}.transferBoundary")
    require_string(
        discovery.get("overgeneralizationRisk"), f"{label}.overgeneralizationRisk"
    )

    for path_index, raw_path in enumerate(artifact_paths):
        repository_path(raw_path, f"{label}.artifactPaths[{path_index}]")
    for path_index, raw_path in enumerate(evidence_paths):
        repository_path(raw_path, f"{label}.evidencePaths[{path_index}]")
    for test_id in evidence_test_ids:
        if test_id not in traceability_ids:
            fail(f"{label} references unknown traceability id: {test_id}")

    if status == "promoted":
        if not artifact_paths:
            fail(f"{label} is promoted but has no artifactPaths")
        if not evidence_paths and not evidence_test_ids:
            fail(f"{label} is promoted but has no independent evidence")
    if status in {"deferred", "rejected"} and not discovery.get("overgeneralizationRisk"):
        fail(f"{label} must explain why it was not promoted")

if discovery_numbers and discovery_numbers != list(range(1, len(discovery_numbers) + 1)):
    fail("discovery IDs must be ordered and contiguous from FOVEA-EGG-001")

if errors:
    print("Engineering knowledge checks failed:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "Engineering knowledge checks passed: "
    f"{len(principles)} principles, {len(discoveries)} discoveries, "
    f"{len(ALLOWED_DISCIPLINES)} governed disciplines."
)
