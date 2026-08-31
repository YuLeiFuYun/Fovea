#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import sys

PERFORMANCE = pathlib.Path(__file__).resolve().parent
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
    "w5_apng_tile_capture_validator_support",
    PERFORMANCE / "capture_w5_apng_tile_checkpoint_model.py",
)
reference = load_module(
    "w5_apng_tile_reference_validator",
    PERFORMANCE / "w5_apng_reference.py",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
    return snapshot


def contained_file(root: pathlib.Path, value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str):
        fail(f"{label}: path must be a string")
    path = pathlib.Path(value).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        fail(f"{label}: path escapes capture root")
        raise AssertionError from error
    if not path.is_file():
        fail(f"{label}: missing file")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_directory", type=pathlib.Path)
    args = parser.parse_args()
    root = args.capture_directory.resolve()

    paths = {
        "sourceIdentity": root / "source-identity.json",
        "tilePlan": root / "tile-plan.json",
        "basePlan": root / "base-plan.json",
        "report": root / "report.json",
        "manifest": root / "capture-manifest.json",
    }
    for label, path in paths.items():
        if not path.is_file():
            fail(f"missing APNG tile checkpoint evidence: {label}")
    source_identity = json.loads(paths["sourceIdentity"].read_text())
    tile_plan = json.loads(paths["tilePlan"].read_text())
    base_plan = json.loads(paths["basePlan"].read_text())
    report = json.loads(paths["report"].read_text())
    manifest = json.loads(paths["manifest"].read_text())

    if source_identity.get("schemaVersion") != 1:
        fail("APNG tile source identity schema mismatch")
    if report.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1:
        fail("APNG tile report or manifest schema mismatch")
    if report.get("studyID") != (
        "FOVEA-W5-APNG-TILE-CHECKPOINT-CANDIDATE-SOURCE-BOUND-2026-08"
    ):
        fail("APNG tile study identity mismatch")
    if any(
        payload.get("formalClaimEligible") is not False
        for payload in (source_identity, report, manifest)
    ):
        fail("APNG tile evidence must not activate a formal claim")
    capture.validate_tile_plan(tile_plan)
    capture.base_capture.validate_plan(base_plan)

    for label in ("sourceIdentity", "tilePlan", "basePlan", "report"):
        identity_matches(manifest.get(label), paths[label], f"manifest {label}")
    identity_matches(
        source_identity.get("tilePlan"), paths["tilePlan"], "source identity tile plan"
    )
    identity_matches(
        source_identity.get("basePlan"), paths["basePlan"], "source identity base plan"
    )
    identity_matches(
        report.get("sourceIdentity"),
        paths["sourceIdentity"],
        "report source identity",
    )
    identity_matches(report.get("tilePlan"), paths["tilePlan"], "report tile plan")
    identity_matches(report.get("basePlan"), paths["basePlan"], "report base plan")

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
    validate_snapshot("ImageCraft", sources.get("ImageCraft"))
    apngkit = validate_snapshot("APNGKit", sources.get("APNGKit"))
    if apngkit.get("headCommit") != APNGKIT_COMMIT or apngkit.get("dirty") is not False:
        fail("APNGKit source identity is not the clean exact fixture commit")
    if fovea.get("dirty") is not True:
        fail("Fovea tile capture must bind the current dirty research tree")

    policy_sources = source_identity.get("policySources")
    if not isinstance(policy_sources, dict) or policy_sources != manifest.get(
        "policySourcesBefore"
    ):
        fail("APNG tile policy source identity mismatch")
    observations = policy_sources.get("observations")
    if not isinstance(observations, dict) or not observations or not all(
        value is True for value in observations.values()
    ):
        fail("APNG tile bound policy observations failed")

    inputs = source_identity.get("inputs")
    fixture_contracts = base_plan.get("sourceFixtures")
    if not isinstance(inputs, dict) or not isinstance(fixture_contracts, list):
        fail("APNG tile retained input contract is invalid")
    expected_ids = {str(item["id"]) for item in fixture_contracts}
    if set(inputs) != expected_ids:
        fail("APNG tile retained input set mismatch")
    expected_artifacts = set(paths.values())
    native_images = {}
    for identifier in sorted(expected_ids):
        record = inputs[identifier]
        if not isinstance(record, dict):
            fail(f"{identifier}: input identity is invalid")
        path = contained_file(root, record.get("path"), f"{identifier} input")
        if path.parent != root / "inputs" or path.name != f"{identifier}.apng":
            fail(f"{identifier}: retained input path contract mismatch")
        identity_matches(record, path, f"{identifier} input")
        native_images[identifier] = reference.parse_apng_file(path)
        expected_artifacts.add(path)

    actual_artifacts = {path for path in root.rglob("*") if path.is_file()}
    if actual_artifacts != expected_artifacts:
        fail(
            "APNG tile artifact set mismatch: "
            f"unexpected={sorted(str(path) for path in actual_artifacts - expected_artifacts)} "
            f"missing={sorted(str(path) for path in expected_artifacts - actual_artifacts)}"
        )

    computed = capture.analyze(tile_plan, base_plan, native_images)
    if report.get("analysis") != computed:
        fail("APNG tile analysis does not match independent recomputation")
    summary = computed.get("summary")
    matrix = computed.get("matrix")
    if not isinstance(summary, dict) or not isinstance(matrix, list):
        fail("APNG tile summary or matrix missing")
    if summary.get("matrixCaseCount") != len(matrix):
        fail("APNG tile matrix count mismatch")
    feasible = sum(row.get("status") == "feasible-candidate" for row in matrix)
    if summary.get("feasibleCandidateCaseCount") != feasible:
        fail("APNG tile feasible candidate count mismatch")
    if summary.get("noFeasibleCandidateCaseCount") != len(matrix) - feasible:
        fail("APNG tile infeasible candidate count mismatch")
    if summary.get("candidateFamilyGlobalOptimalityClaim") is not False:
        fail("APNG tile candidate family must not claim global optimality")

    print(paths["report"])
    print(
        "APNG tile checkpoint candidates: "
        f"cases={summary['matrixCaseCount']} "
        f"feasible={summary['feasibleCandidateCaseCount']} "
        f"reference={summary['referencePolicyFeasibleCandidateCaseCount']}/"
        f"{summary['referencePolicyCaseCount']} "
        f"referencePeakWithinHardCap="
        f"{summary['referencePolicyPeakWithinFoveaHardCapCount']}"
    )
    print(
        "reference scenarios with candidates: "
        + ", ".join(summary["referencePolicyScenariosWithAnyFeasibleCandidate"])
    )


if __name__ == "__main__":
    main()
