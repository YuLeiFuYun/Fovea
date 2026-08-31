#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


capture = load_module(
    "w5_apng_compressed_validator_capture",
    PERFORMANCE / "capture_w5_apng_compressed_checkpoint_model.py",
)
model = capture.model
reference = capture.reference
support = capture.support


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def contained(root: pathlib.Path, value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str):
        fail(f"{label}: path must be a string")
    path = pathlib.Path(value).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        fail(f"{label}: path escapes capture root")
        raise AssertionError from error
    if not path.is_file():
        fail(f"{label}: file is missing")
    return path


def identity_matches(record: object, path: pathlib.Path, label: str) -> None:
    if not isinstance(record, dict):
        fail(f"{label}: identity is invalid")
    if pathlib.Path(str(record.get("path"))).resolve() != path.resolve():
        fail(f"{label}: identity path mismatch")
    if record.get("byteCount") != path.stat().st_size or record.get("sha256") != sha256(path):
        fail(f"{label}: identity mismatch")


def validate_snapshot(name: str, snapshot: object) -> None:
    if not isinstance(snapshot, dict):
        fail(f"{name}: snapshot missing")
    for key in ("headCommit", "headTree", "workingTree"):
        value = snapshot.get(key)
        if not isinstance(value, str) or len(value) != 40 or any(c not in "0123456789abcdef" for c in value):
            fail(f"{name}: invalid {key}")
    if snapshot.get("dirty") != (snapshot.get("headTree") != snapshot.get("workingTree")):
        fail(f"{name}: dirty state mismatch")
    if snapshot.get("identityAlgorithm") != "git-temporary-index-add-all-write-tree-v1":
        fail(f"{name}: identity algorithm mismatch")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_directory", type=pathlib.Path)
    args = parser.parse_args()
    root = args.capture_directory.resolve()
    report_path = root / "report.json"
    manifest_path = root / "capture-manifest.json"
    identity_path = root / "source-identity.json"
    base_plan_path = root / "base-plan.json"
    compressed_plan_path = root / "compressed-plan.json"
    for path in (report_path, manifest_path, identity_path, base_plan_path, compressed_plan_path):
        if not path.is_file():
            fail(f"missing capture file: {path.name}")

    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    identity = json.loads(identity_path.read_text())
    base_plan = json.loads(base_plan_path.read_text())
    compressed_plan = json.loads(compressed_plan_path.read_text())
    if report.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1 or identity.get("schemaVersion") != 1:
        fail("compressed checkpoint capture schema mismatch")
    if report.get("formalClaimEligible") is not False or manifest.get("formalClaimEligible") is not False:
        fail("compressed checkpoint capture must not activate a formal claim")
    if report.get("studyID") != "FOVEA-W5-APNG-COMPRESSED-CHECKPOINT-MODEL-SOURCE-BOUND-2026-08":
        fail("compressed checkpoint study identity mismatch")
    capture.base.validate_plan(base_plan)
    capture.validate_compressed_plan(compressed_plan)

    for field in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "policySourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if manifest.get(field) is not True:
            fail(f"{field} is false")
    for before, after, label in (
        ("sourceBefore", "sourceAfter", "source"),
        ("inputSourcesBefore", "inputSourcesAfter", "input"),
        ("policySourcesBefore", "policySourcesAfter", "policy"),
        ("governingFilesBefore", "governingFilesAfter", "governing"),
    ):
        if manifest.get(before) != manifest.get(after):
            fail(f"{label} before/after mismatch")
    if identity.get("sources") != manifest.get("sourceBefore"):
        fail("source identity snapshot mismatch")
    if identity.get("policySources") != manifest.get("policySourcesBefore"):
        fail("policy source identity mismatch")
    if identity.get("inputs") is None:
        fail("retained input identity missing")
    for name, snapshot in identity["sources"].items():
        validate_snapshot(name, snapshot)

    identity_matches(manifest.get("sourceIdentity"), identity_path, "manifest source identity")
    identity_matches(manifest.get("basePlan"), base_plan_path, "manifest base plan")
    identity_matches(manifest.get("compressedPlan"), compressed_plan_path, "manifest compressed plan")
    identity_matches(manifest.get("report"), report_path, "manifest report")
    identity_matches(report.get("sourceIdentity"), identity_path, "report source identity")
    identity_matches(report.get("basePlan"), base_plan_path, "report base plan")
    identity_matches(report.get("compressedPlan"), compressed_plan_path, "report compressed plan")
    identity_matches(identity.get("basePlan"), base_plan_path, "identity base plan")
    identity_matches(identity.get("compressedPlan"), compressed_plan_path, "identity compressed plan")

    governing = manifest.get("governingFilesBefore")
    if not isinstance(governing, dict):
        fail("governing file set missing")
    expected_governing = {
        "basePlan",
        "compressedPlan",
        "model",
        "modelTests",
        "referenceParser",
        "captureRunner",
        "validator",
        "captureContract",
        "animationPolicy",
    }
    if set(governing) != expected_governing:
        fail("governing file set mismatch")
    for name, record in governing.items():
        path = pathlib.Path(str(record.get("path"))).resolve()
        if not path.is_file():
            fail(f"governing file missing: {name}")
        identity_matches(record, path, f"governing {name}")

    retained_inputs = identity.get("inputs")
    if not isinstance(retained_inputs, dict):
        fail("retained input set invalid")
    source_inputs = manifest.get("inputSourcesBefore")
    if not isinstance(source_inputs, dict) or set(source_inputs) != set(retained_inputs):
        fail("source input set mismatch")
    images = {}
    expected_artifacts: set[pathlib.Path] = set()
    for fixture_id, record in retained_inputs.items():
        path = root / "inputs" / f"{fixture_id}.apng"
        identity_matches(record, path, f"retained input {fixture_id}")
        expected_artifacts.add(path.resolve())
        images[fixture_id] = reference.parse_apng_file(path)

    anchor = report.get("nativeCheckpointRoundTrip")
    if not isinstance(anchor, dict) or anchor.get("compressionModel") != model.COMPRESSION_MODEL:
        fail("native checkpoint anchor invalid")
    fixtures = anchor.get("fixtures")
    if not isinstance(fixtures, dict) or set(fixtures) != set(images):
        fail("native checkpoint fixture set mismatch")
    all_ratios: list[int] = []
    blob_count = 0
    for fixture_id, image in images.items():
        record = fixtures[fixture_id]
        states = capture.pre_frame_states(image)
        frame_records = record.get("records") if isinstance(record, dict) else None
        if not isinstance(frame_records, list) or len(frame_records) != max(0, len(states) - 1):
            fail(f"native checkpoint record count mismatch: {fixture_id}")
        ratios = []
        for frame_index, state in enumerate(states[1:], start=1):
            item = frame_records[frame_index - 1]
            path = root / "checkpoints" / f"{fixture_id}-pre-frame-{frame_index:03d}.fapc"
            expected_artifacts.add(path.resolve())
            identity_matches(item.get("checkpointBlob"), path, f"checkpoint {fixture_id} {frame_index}")
            expected_blob = model.encode_checkpoint_blob(
                state,
                image.canvas_width,
                image.canvas_height,
                compression_level=9,
            )
            if path.read_bytes() != expected_blob:
                fail(f"checkpoint blob bytes mismatch: {fixture_id} {frame_index}")
            width, height, decoded = model.decode_checkpoint_blob(path.read_bytes())
            if width != image.canvas_width or height != image.canvas_height or decoded != state:
                fail(f"checkpoint round-trip mismatch: {fixture_id} {frame_index}")
            ratio = (len(expected_blob) * 1_000_000 + len(state) - 1) // len(state)
            if item.get("checkpointBlobRatioPPM") != ratio or item.get("roundTripExact") is not True:
                fail(f"checkpoint ratio/round-trip record mismatch: {fixture_id} {frame_index}")
            ratios.append(ratio)
            all_ratios.append(ratio)
            blob_count += 1
        if record.get("minimumRatioPPM") != (min(ratios) if ratios else None):
            fail(f"native minimum ratio mismatch: {fixture_id}")
        if record.get("maximumRatioPPM") != (max(ratios) if ratios else None):
            fail(f"native maximum ratio mismatch: {fixture_id}")
    if anchor.get("checkpointBlobCount") != blob_count:
        fail("native checkpoint blob count mismatch")
    if anchor.get("minimumRatioPPM") != min(all_ratios) or anchor.get("maximumRatioPPM") != max(all_ratios):
        fail("native aggregate ratio bounds mismatch")

    recomputed = capture.analyze(base_plan, compressed_plan, images)
    if report.get("analysis") != recomputed:
        fail("compressed checkpoint analysis mismatch")

    inventory = report.get("artifactInventory")
    if not isinstance(inventory, dict):
        fail("artifact inventory missing")
    actual_artifacts = {
        path.resolve()
        for directory in (root / "inputs", root / "checkpoints")
        for path in directory.iterdir()
        if path.is_file()
    }
    if actual_artifacts != expected_artifacts:
        fail("artifact set mismatch")
    expected_inventory = {
        str(path.relative_to(root)): {
            "path": str(path),
            "byteCount": path.stat().st_size,
            "sha256": sha256(path),
        }
        for path in sorted(expected_artifacts)
    }
    if inventory != expected_inventory:
        fail("artifact inventory mismatch")

    allowed_root_files = {
        report_path.resolve(),
        manifest_path.resolve(),
        identity_path.resolve(),
        base_plan_path.resolve(),
        compressed_plan_path.resolve(),
    }
    unexpected_root = {
        path.resolve() for path in root.iterdir() if path.is_file()
    } - allowed_root_files
    if unexpected_root:
        fail("unexpected root artifact")
    print(report_path)


if __name__ == "__main__":
    main()
