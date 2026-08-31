#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import stat
import subprocess
import sys
import tempfile

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
    "w5_apng_public_decoder_validator_capture",
    PERFORMANCE / "capture_w5_apng_public_decoder_playback.py",
)
support = capture.support
reference = capture.reference


def fail(message: str) -> None:
    raise SystemExit(message)


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity_matches(record: object, path: pathlib.Path, label: str) -> None:
    if not isinstance(record, dict):
        fail(f"{label}: identity missing")
    if pathlib.Path(str(record.get("path"))).resolve() != path.resolve():
        fail(f"{label}: identity path mismatch")
    if record.get("byteCount") != path.stat().st_size or record.get("sha256") != digest(path):
        fail(f"{label}: identity mismatch")


def validate_snapshot(name: str, snapshot: object) -> None:
    if not isinstance(snapshot, dict):
        fail(f"{name}: source snapshot missing")
    for field in ("headCommit", "headTree", "workingTree"):
        value = snapshot.get(field)
        if not isinstance(value, str) or len(value) != 40:
            fail(f"{name}: invalid {field}")
    if snapshot.get("dirty") != (snapshot.get("headTree") != snapshot.get("workingTree")):
        fail(f"{name}: dirty state mismatch")
    if snapshot.get("identityAlgorithm") != "git-temporary-index-add-all-write-tree-v1":
        fail(f"{name}: identity algorithm mismatch")


def run_checked(command: list[str]) -> tuple[str, str]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        fail(
            f"retained public decoder command failed ({completed.returncode}): "
            f"{' '.join(command)}\n{completed.stdout}{completed.stderr}"
        )
    return completed.stdout.strip(), completed.stderr.strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_directory", type=pathlib.Path)
    args = parser.parse_args()
    root = args.capture_directory.resolve()
    report_path = root / "report.json"
    manifest_path = root / "capture-manifest.json"
    source_identity_path = root / "source-identity.json"
    binary = root / "bin/ImageCraftEvidence"
    for path in (report_path, manifest_path, source_identity_path, binary):
        if not path.is_file():
            fail(f"missing public decoder capture file: {path}")

    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    identity = json.loads(source_identity_path.read_text())
    if report.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1 or identity.get("schemaVersion") != 1:
        fail("public decoder schema mismatch")
    if report.get("studyID") != "FOVEA-W5-APNG-PUBLIC-IMAGECRAFT-DECODER-PLAYBACK-2026-08":
        fail("public decoder study identity mismatch")
    if report.get("codecFingerprint") != capture.CODEC_FINGERPRINT:
        fail("public decoder codec fingerprint mismatch")
    if any(item.get("formalClaimEligible") is not False for item in (report, manifest, identity)):
        fail("public decoder evidence must not activate a formal claim")
    for field in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if manifest.get(field) is not True:
            fail(f"public decoder identity flag failed: {field}")
    if manifest.get("sourceBefore") != manifest.get("sourceAfter"):
        fail("source before/after mismatch")
    if manifest.get("inputSourcesBefore") != manifest.get("inputSourcesAfter"):
        fail("input sources before/after mismatch")
    if manifest.get("governingFilesBefore") != manifest.get("governingFilesAfter"):
        fail("governing files before/after mismatch")
    if identity.get("sources") != manifest.get("sourceBefore"):
        fail("source identity snapshot mismatch")
    if identity.get("governingFiles") != manifest.get("governingFilesBefore"):
        fail("source identity governing mismatch")
    if identity.get("appleOracleInputs") != manifest.get("appleOracleInputs"):
        fail("Apple oracle identity mismatch")
    for name, snapshot in identity.get("sources", {}).items():
        validate_snapshot(name, snapshot)

    identity_matches(manifest.get("sourceIdentity"), source_identity_path, "manifest source identity")
    identity_matches(manifest.get("binary"), binary, "manifest binary")
    identity_matches(manifest.get("report"), report_path, "manifest report")
    identity_matches(report.get("sourceIdentity"), source_identity_path, "report source identity")
    identity_matches(report.get("binary"), binary, "report binary")
    identity_matches(identity.get("binary"), binary, "identity binary")
    if not stat.S_IMODE(binary.stat().st_mode) & stat.S_IXUSR:
        fail("retained ImageCraftEvidence binary is not executable")

    for name, record in (identity.get("governingFiles") or {}).items():
        path = pathlib.Path(str(record.get("path"))).resolve()
        identity_matches(record, path, f"governing {name}")
    for name, record in (identity.get("appleOracleInputs") or {}).items():
        path = pathlib.Path(str(record.get("path"))).resolve()
        identity_matches(record, path, f"Apple oracle {name}")
    aggregate = json.loads(
        pathlib.Path(identity["appleOracleInputs"]["aggregate"]["path"]).read_text()
    )
    oracle_inventory = aggregate.get("artifactInventory") or {}

    fixture_contract = identity.get("fixtureContract")
    fixture_results = report.get("fixtureResults")
    if not isinstance(fixture_contract, dict) or not isinstance(fixture_results, dict):
        fail("public decoder fixture records missing")
    if set(fixture_contract) != set(fixture_results):
        fail("public decoder fixture set mismatch")

    expected_artifacts: set[pathlib.Path] = {binary.resolve()}
    total_frames = 0
    all_python = True
    all_apple = True
    all_reverse = True
    all_cancel = True
    with tempfile.TemporaryDirectory(prefix="w5-apng-public-decoder-validate-") as temporary:
        temporary_root = pathlib.Path(temporary)
        for identifier, contract in fixture_contract.items():
            if not isinstance(contract, dict):
                fail(f"invalid fixture contract: {identifier}")
            width = int(contract["canvasWidth"])
            height = int(contract["canvasHeight"])
            frame_count = int(contract["frameCount"])
            has_apple = bool(contract["hasAppleOracle"])
            input_path = root / "inputs" / f"{identifier}.apng"
            expected_artifacts.add(input_path.resolve())
            identity_matches(fixture_results[identifier].get("input"), input_path, f"{identifier} input")
            image = reference.parse_apng_file(input_path)
            composed = reference.compose_frames(image)
            if (image.canvas_width, image.canvas_height, len(composed)) != (
                width,
                height,
                frame_count,
            ):
                fail(f"Python metadata mismatch: {identifier}")

            rerun = temporary_root / identifier
            stdout, stderr = run_checked(
                [
                    str(binary),
                    "--animation-decoder-playback",
                    str(input_path),
                    "--output-directory",
                    str(rerun),
                ]
            )
            if stderr or stdout != str(rerun / "report.json"):
                fail(f"retained binary output mismatch: {identifier}")
            public_root = root / "public" / identifier
            public_report_path = public_root / "report.json"
            expected_artifacts.add(public_report_path.resolve())
            identity_matches(
                fixture_results[identifier].get("publicReport"),
                public_report_path,
                f"{identifier} public report",
            )
            retained_report = json.loads(public_report_path.read_text())
            rerun_report = json.loads((rerun / "report.json").read_text())
            if retained_report != rerun_report:
                fail(f"public decoder report is not reproducible: {identifier}")
            diagnostics = retained_report.get("preparationDiagnostics")
            expected_alignment = identifier != "APNG-SEPARATE-DEFAULT"
            canvas_bytes = width * height * 4
            if (
                retained_report.get("codecFingerprint") != capture.CODEC_FINGERPRINT
                or retained_report.get("allReverseRandomAccessExact") is not True
                or retained_report.get("cancellationFenced") is not True
                or not isinstance(diagnostics, dict)
                or diagnostics.get("backingKind") != "ownedAPNG"
                or diagnostics.get("imageIOSourceIndicesMatchTimeline")
                is not expected_alignment
                or diagnostics.get("ownedRetainedCheckpointCount") != 0
                or diagnostics.get("ownedRetainedCheckpointBytes") != 0
                or diagnostics.get("ownedMaximumReplayFrames") != 8
                or diagnostics.get("ownedCanvasRGBABytes") != canvas_bytes
                or diagnostics.get("ownedMaterializedOutputRGBABytes") != canvas_bytes
                or diagnostics.get("ownedDecompressorWorkspaceBytes") != 256 * 1024
                or not isinstance(diagnostics.get("ownedRetainedBytes"), int)
                or diagnostics["ownedRetainedBytes"] <= 0
                or diagnostics["ownedRetainedBytes"] > 32 * 1024 * 1024
                or not isinstance(diagnostics.get("ownedModeledPeakBytesUpperBound"), int)
                or diagnostics["ownedModeledPeakBytesUpperBound"]
                <= diagnostics["ownedRetainedBytes"]
            ):
                fail(f"public decoder lifecycle/diagnostics contract mismatch: {identifier}")
            result = fixture_results[identifier]
            if result.get("preparationDiagnostics") != diagnostics:
                fail(f"fixture preparation diagnostics mismatch: {identifier}")

            frames = result.get("frames")
            if not isinstance(frames, list) or len(frames) != frame_count:
                fail(f"public decoder frame record mismatch: {identifier}")
            fixture_python = True
            fixture_apple = True
            for index, (raw_frame, composed_frame, frame_record) in enumerate(
                zip(image.frames, composed, frames)
            ):
                public_path = public_root / f"frame-{index:03d}.rgba"
                rerun_path = rerun / f"frame-{index:03d}.rgba"
                python_path = root / "python" / identifier / f"frame-{index:03d}.rgba"
                for path in (public_path, python_path):
                    expected_artifacts.add(path.resolve())
                if rerun_path.read_bytes() != public_path.read_bytes():
                    fail(f"public decoder frame is not reproducible: {identifier}/{index}")
                if python_path.read_bytes() != composed_frame.premultiplied_rgba:
                    fail(f"retained Python frame mismatch: {identifier}/{index}")
                public_python = public_path.read_bytes() == python_path.read_bytes()
                fixture_python = fixture_python and public_python
                identity_matches(frame_record.get("public"), public_path, f"{identifier} public {index}")
                identity_matches(frame_record.get("python"), python_path, f"{identifier} Python {index}")
                if frame_record.get("publicPythonExact") != public_python:
                    fail(f"public/Python report mismatch: {identifier}/{index}")
                expected_descriptor = capture.descriptor(raw_frame.control)
                if frame_record.get("descriptor") != expected_descriptor:
                    fail(f"descriptor record mismatch: {identifier}/{index}")
                if has_apple:
                    apple_path = root / "apple" / identifier / f"frame-{index:03d}.rgba"
                    expected_artifacts.add(apple_path.resolve())
                    identity_matches(frame_record.get("apple"), apple_path, f"{identifier} Apple {index}")
                    oracle_name = f"{identifier}-frame-{index:02d}-AppleImageIO.rgba"
                    oracle_record = oracle_inventory.get(oracle_name)
                    if not isinstance(oracle_record, dict):
                        fail(f"Apple oracle entry missing: {oracle_name}")
                    if (
                        apple_path.stat().st_size != oracle_record.get("byteCount")
                        or digest(apple_path) != oracle_record.get("sha256")
                    ):
                        fail(f"Apple oracle retained frame mismatch: {identifier}/{index}")
                    public_apple = public_path.read_bytes() == apple_path.read_bytes()
                    fixture_apple = fixture_apple and public_apple
                    if frame_record.get("publicAppleExact") != public_apple:
                        fail(f"public/Apple report mismatch: {identifier}/{index}")
            total_frames += frame_count
            all_python = all_python and fixture_python
            all_apple = all_apple and (fixture_apple if has_apple else True)
            all_reverse = all_reverse and bool(result.get("allReverseRandomAccessExact"))
            all_cancel = all_cancel and bool(result.get("cancellationFenced"))
            if result.get("allPublicPythonExact") != fixture_python:
                fail(f"fixture public/Python aggregate mismatch: {identifier}")
            expected_apple = fixture_apple if has_apple else None
            if result.get("allPublicAppleExact") != expected_apple:
                fail(f"fixture public/Apple aggregate mismatch: {identifier}")

    expected_summary = {
        "fixtureCount": len(fixture_contract),
        "frameCount": total_frames,
        "allPublicPythonExact": all_python,
        "allPublicAppleExactWhereAvailable": all_apple,
        "allReverseRandomAccessExact": all_reverse,
        "allCancellationFenced": all_cancel,
        "allBackingsOwnedAPNG": all(
            result["preparationDiagnostics"]["backingKind"] == "ownedAPNG"
            for result in fixture_results.values()
        ),
        "allRealFixtureCheckpointCountsZero": all(
            result["preparationDiagnostics"]["ownedRetainedCheckpointCount"] == 0
            for result in fixture_results.values()
        ),
        "allOwnedRetainedWithin32MiB": all(
            result["preparationDiagnostics"]["ownedRetainedBytes"]
            <= 32 * 1024 * 1024
            for result in fixture_results.values()
        ),
        "separateDefaultTimelineExact": fixture_results.get(
            "APNG-SEPARATE-DEFAULT", {}
        ).get("allPublicPythonExact")
        if "APNG-SEPARATE-DEFAULT" in fixture_contract
        else None,
    }
    for key, value in expected_summary.items():
        if report.get(key) != value:
            fail(f"public decoder aggregate mismatch: {key}")

    inventory = report.get("artifactInventory")
    if not isinstance(inventory, dict):
        fail("public decoder artifact inventory missing")
    actual_artifacts = {
        path.resolve()
        for directory_name in ("bin", "inputs", "public", "python", "apple")
        for path in (root / directory_name).rglob("*")
        if path.is_file()
    }
    if actual_artifacts != expected_artifacts:
        fail("public decoder artifact set mismatch")
    expected_inventory = {
        str(path.relative_to(root)): support.file_identity(path)
        for path in sorted(expected_artifacts)
    }
    if inventory != expected_inventory:
        fail("public decoder artifact inventory mismatch")
    allowed_root = {
        report_path.resolve(),
        manifest_path.resolve(),
        source_identity_path.resolve(),
    }
    unexpected = {path.resolve() for path in root.iterdir() if path.is_file()} - allowed_root
    if unexpected:
        fail("unexpected public decoder root artifact")
    print(report_path)


if __name__ == "__main__":
    main()
