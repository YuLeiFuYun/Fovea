#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import sys

PERFORMANCE = pathlib.Path(__file__).resolve().parent
ROOT = PERFORMANCE.parents[1]
APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"


def load_module(name: str, path: pathlib.Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


capture = load_module(
    "w5_apng_checkpoint_capture_validator_support",
    PERFORMANCE / "capture_w5_apng_checkpoint_model.py",
)
reference = load_module(
    "w5_apng_checkpoint_reference_validator",
    PERFORMANCE / "w5_apng_reference.py",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"path": str(path), "byteCount": len(data), "sha256": sha256(data)}


def identity_matches(record: object, path: pathlib.Path, label: str) -> None:
    if not isinstance(record, dict):
        fail(f"{label}: identity must be an object")
    data = path.read_bytes()
    if record.get("byteCount") != len(data) or record.get("sha256") != sha256(data):
        fail(f"{label}: identity mismatch")


def is_git_object_id(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 40
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_snapshot(name: str, snapshot: object) -> dict:
    if not isinstance(snapshot, dict):
        fail(f"{name}: source snapshot missing")
    for field in ("headCommit", "headTree", "workingTree"):
        if not is_git_object_id(snapshot.get(field)):
            fail(f"{name}: invalid {field}")
    if not isinstance(snapshot.get("dirty"), bool):
        fail(f"{name}: invalid dirty state")
    if snapshot["dirty"] != (snapshot["headTree"] != snapshot["workingTree"]):
        fail(f"{name}: dirty state does not match tree identity")
    if snapshot.get("identityAlgorithm") != "git-temporary-index-add-all-write-tree-v1":
        fail(f"{name}: unsupported source identity algorithm")
    if not isinstance(snapshot.get("root"), str) or not snapshot["root"]:
        fail(f"{name}: source root missing")
    return snapshot


def contained_file(root: pathlib.Path, value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str):
        fail(f"{label}: path must be a string")
    path = pathlib.Path(value).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        fail(f"{label}: path escapes capture root: {path}")
        raise AssertionError from error
    if not path.is_file():
        fail(f"{label}: missing file: {path}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_directory", type=pathlib.Path)
    args = parser.parse_args()
    root = args.capture_directory.resolve()

    source_identity_path = root / "source-identity.json"
    plan_path = root / "plan.json"
    report_path = root / "report.json"
    manifest_path = root / "capture-manifest.json"
    for path in (source_identity_path, plan_path, report_path, manifest_path):
        if not path.is_file():
            fail(f"missing APNG checkpoint evidence file: {path.name}")

    source_identity = json.loads(source_identity_path.read_text())
    plan = json.loads(plan_path.read_text())
    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    if source_identity.get("schemaVersion") != 1:
        fail("APNG checkpoint source identity schema mismatch")
    if report.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1:
        fail("APNG checkpoint report or manifest schema mismatch")
    if report.get("studyID") != "FOVEA-W5-APNG-CHECKPOINT-MODEL-SOURCE-BOUND-2026-08":
        fail("APNG checkpoint study identity mismatch")
    if any(
        payload.get("formalClaimEligible") is not False
        for payload in (source_identity, report, manifest)
    ):
        fail("APNG checkpoint evidence must not activate a formal claim")

    capture.validate_plan(plan)
    identity_matches(manifest.get("sourceIdentity"), source_identity_path, "manifest source identity")
    identity_matches(manifest.get("plan"), plan_path, "manifest plan")
    identity_matches(manifest.get("report"), report_path, "manifest report")
    identity_matches(source_identity.get("plan"), plan_path, "source identity plan")
    identity_matches(report.get("sourceIdentity"), source_identity_path, "report source identity")
    identity_matches(report.get("plan"), plan_path, "report plan")

    for flag in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "policySourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if manifest.get(flag) is not True:
            fail(f"capture did not preserve {flag}")
    for before, after, label in (
        ("sourceBefore", "sourceAfter", "source"),
        ("inputSourcesBefore", "inputSourcesAfter", "input source"),
        ("policySourcesBefore", "policySourcesAfter", "policy source"),
        ("governingFilesBefore", "governingFilesAfter", "governing file"),
    ):
        if manifest.get(before) != manifest.get(after):
            fail(f"{label} before/after mismatch")

    sources = source_identity.get("sources")
    if not isinstance(sources, dict) or sources != manifest.get("sourceBefore"):
        fail("source identity does not match capture source")
    fovea = validate_snapshot("Fovea", sources.get("Fovea"))
    imagecraft = validate_snapshot("ImageCraft", sources.get("ImageCraft"))
    apngkit = validate_snapshot("APNGKit", sources.get("APNGKit"))
    if apngkit.get("headCommit") != APNGKIT_COMMIT or apngkit.get("dirty") is not False:
        fail("APNGKit source identity is not the clean exact fixture commit")
    current_fovea = capture.support.git_snapshot(ROOT)
    if fovea != current_fovea:
        fail("Fovea capture no longer binds the current exact source tree")
    if not isinstance(imagecraft.get("dirty"), bool):
        fail("ImageCraft dirty state missing")

    policy_sources = source_identity.get("policySources")
    if not isinstance(policy_sources, dict) or policy_sources != manifest.get(
        "policySourcesBefore"
    ):
        fail("policy source identity mismatch")
    observations = policy_sources.get("observations")
    if not isinstance(observations, dict) or not observations or not all(
        value is True for value in observations.values()
    ):
        fail("bound implementation policy observation failed")

    inputs = source_identity.get("inputs")
    fixture_contracts = plan.get("sourceFixtures")
    if not isinstance(inputs, dict) or not isinstance(fixture_contracts, list):
        fail("APNG checkpoint input contract is invalid")
    expected_ids = {str(item["id"]) for item in fixture_contracts}
    if set(inputs) != expected_ids:
        fail("APNG checkpoint retained input set mismatch")
    native_images = {}
    expected_artifacts = {
        source_identity_path,
        plan_path,
        report_path,
        manifest_path,
    }
    retained_inputs: dict[str, dict] = {}
    for identifier in sorted(expected_ids):
        record = inputs[identifier]
        if not isinstance(record, dict):
            fail(f"{identifier}: input identity is invalid")
        path = contained_file(root, record.get("path"), f"{identifier} input")
        if path.parent != root / "inputs" or path.name != f"{identifier}.apng":
            fail(f"{identifier}: retained input path contract mismatch")
        identity_matches(record, path, f"{identifier} input")
        native_images[identifier] = reference.parse_apng_file(path)
        retained_inputs[identifier] = record
        expected_artifacts.add(path)

    actual_artifacts = {path for path in root.rglob("*") if path.is_file()}
    if actual_artifacts != expected_artifacts:
        fail(
            "APNG checkpoint artifact set mismatch: "
            f"unexpected={sorted(str(path) for path in actual_artifacts - expected_artifacts)} "
            f"missing={sorted(str(path) for path in expected_artifacts - actual_artifacts)}"
        )

    computed_analysis = capture.analyze(plan, native_images, retained_inputs)
    if report.get("analysis") != computed_analysis:
        fail("APNG checkpoint analysis does not match independent recomputation")
    summary = computed_analysis.get("summary")
    if not isinstance(summary, dict):
        fail("APNG checkpoint summary missing")
    matrix = computed_analysis.get("matrix")
    if not isinstance(matrix, list) or summary.get("matrixCaseCount") != len(matrix):
        fail("APNG checkpoint matrix count mismatch")
    feasible = sum(row.get("status") == "feasible" for row in matrix)
    if summary.get("feasibleCaseCount") != feasible:
        fail("APNG checkpoint feasible count mismatch")
    if summary.get("infeasibleCaseCount") != len(matrix) - feasible:
        fail("APNG checkpoint infeasible count mismatch")

    print(report_path)
    print(
        "APNG checkpoint model: "
        f"cases={summary['matrixCaseCount']} feasible={summary['feasibleCaseCount']} "
        f"referenceFeasible={summary['referencePolicyFeasibleCaseCount']}/"
        f"{summary['referencePolicyCaseCount']}"
    )
    print(
        "reference scenarios with any feasible case: "
        + ", ".join(summary["referencePolicyScenariosWithAnyFeasibleCase"])
    )


if __name__ == "__main__":
    main()
