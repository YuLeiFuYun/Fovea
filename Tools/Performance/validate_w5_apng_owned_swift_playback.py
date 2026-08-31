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
    "w5_apng_owned_swift_validator_capture",
    PERFORMANCE / "capture_w5_apng_owned_swift_playback.py",
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
            f"retained binary command failed ({completed.returncode}): "
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
    identity_path = root / "source-identity.json"
    binary = root / "bin/ImageCraftEvidence"
    for path in (report_path, manifest_path, identity_path, binary):
        if not path.is_file():
            fail(f"missing owned Swift playback capture file: {path}")

    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    identity = json.loads(identity_path.read_text())
    if report.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1 or identity.get("schemaVersion") != 1:
        fail("owned Swift playback schema mismatch")
    if report.get("studyID") != "FOVEA-W5-APNG-OWNED-SWIFT-PLAYBACK-ORACLE-2026-08":
        fail("owned Swift playback study identity mismatch")
    if any(item.get("formalClaimEligible") is not False for item in (report, manifest, identity)):
        fail("owned Swift playback must not activate a formal claim")
    for field in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if manifest.get(field) is not True:
            fail(f"owned Swift playback identity flag failed: {field}")
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

    identity_matches(manifest.get("sourceIdentity"), identity_path, "manifest source identity")
    identity_matches(manifest.get("binary"), binary, "manifest binary")
    identity_matches(manifest.get("report"), report_path, "manifest report")
    identity_matches(report.get("sourceIdentity"), identity_path, "report source identity")
    identity_matches(report.get("binary"), binary, "report binary")
    identity_matches(identity.get("binary"), binary, "identity binary")
    if not stat.S_IMODE(binary.stat().st_mode) & stat.S_IXUSR:
        fail("retained ImageCraftEvidence binary is not executable")

    governing = identity.get("governingFiles")
    if not isinstance(governing, dict) or not governing:
        fail("owned Swift playback governing files missing")
    for name, record in governing.items():
        path = pathlib.Path(str(record.get("path"))).resolve()
        if not path.is_file():
            fail(f"governing file missing: {name}")
        identity_matches(record, path, f"governing {name}")
    for name, record in identity.get("appleOracleInputs", {}).items():
        path = pathlib.Path(str(record.get("path"))).resolve()
        identity_matches(record, path, f"Apple oracle {name}")

    fixture_contract = identity.get("fixtureContract")
    fixture_results = report.get("fixtureResults")
    if not isinstance(fixture_contract, dict) or not isinstance(fixture_results, dict):
        fail("owned Swift playback fixture records missing")
    if set(fixture_contract) != set(fixture_results):
        fail("owned Swift playback fixture set mismatch")
    aggregate = json.loads(
        pathlib.Path(identity["appleOracleInputs"]["aggregate"]["path"]).read_text()
    )
    oracle_inventory = aggregate.get("artifactInventory") or {}
    expected_artifacts: set[pathlib.Path] = {binary.resolve()}
    total_frames = 0
    all_python = True
    all_apple = True

    with tempfile.TemporaryDirectory(prefix="w5-apng-owned-swift-validate-") as temporary:
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
            identity_matches(
                fixture_results[identifier].get("input"),
                input_path,
                f"{identifier} input",
            )
            image = reference.parse_apng_file(input_path)
            composed = reference.compose_frames(image)
            if (image.canvas_width, image.canvas_height, len(composed)) != (
                width,
                height,
                frame_count,
            ):
                fail(f"Python metadata mismatch: {identifier}")

            temporary_output = temporary_root / identifier
            stdout, stderr = run_checked(
                [
                    str(binary),
                    "--apng-owned-playback",
                    str(input_path),
                    "--output-directory",
                    str(temporary_output),
                ]
            )
            if stderr or stdout != str(temporary_output / "report.json"):
                fail(f"retained binary output mismatch: {identifier}")
            retained_swift_root = root / "swift" / identifier
            retained_swift_report = retained_swift_root / "report.json"
            expected_artifacts.add(retained_swift_report.resolve())
            identity_matches(
                fixture_results[identifier].get("swiftReport"),
                retained_swift_report,
                f"{identifier} Swift report",
            )
            if json.loads(retained_swift_report.read_text()) != json.loads(
                (temporary_output / "report.json").read_text()
            ):
                fail(f"retained Swift report is not reproducible: {identifier}")

            record = fixture_results[identifier]
            frames = record.get("frames")
            if not isinstance(frames, list) or len(frames) != frame_count:
                fail(f"fixture frame record mismatch: {identifier}")
            fixture_python = True
            fixture_apple = True
            for index, expected_frame in enumerate(composed):
                swift_path = retained_swift_root / f"frame-{index:03d}.rgba"
                rerun_path = temporary_output / f"frame-{index:03d}.rgba"
                python_path = root / "python" / identifier / f"frame-{index:03d}.rgba"
                for path in (swift_path, python_path):
                    expected_artifacts.add(path.resolve())
                if not swift_path.is_file() or not python_path.is_file():
                    fail(f"missing retained frame: {identifier}/{index}")
                if rerun_path.read_bytes() != swift_path.read_bytes():
                    fail(f"retained Swift frame is not reproducible: {identifier}/{index}")
                if python_path.read_bytes() != expected_frame.premultiplied_rgba:
                    fail(f"retained Python frame mismatch: {identifier}/{index}")
                swift_python = swift_path.read_bytes() == python_path.read_bytes()
                fixture_python = fixture_python and swift_python
                frame_record = frames[index]
                identity_matches(frame_record.get("swift"), swift_path, f"{identifier} Swift {index}")
                identity_matches(frame_record.get("python"), python_path, f"{identifier} Python {index}")
                if frame_record.get("swiftPythonExact") != swift_python:
                    fail(f"Swift/Python report mismatch: {identifier}/{index}")
                if has_apple:
                    apple_path = root / "apple" / identifier / f"frame-{index:03d}.rgba"
                    expected_artifacts.add(apple_path.resolve())
                    identity_matches(frame_record.get("apple"), apple_path, f"{identifier} Apple {index}")
                    oracle_name = f"{identifier}-frame-{index:02d}-AppleImageIO.rgba"
                    oracle_record = oracle_inventory.get(oracle_name)
                    if not isinstance(oracle_record, dict):
                        fail(f"Apple oracle inventory missing: {oracle_name}")
                    if (
                        apple_path.stat().st_size != oracle_record.get("byteCount")
                        or digest(apple_path) != oracle_record.get("sha256")
                    ):
                        fail(f"Apple oracle retained frame mismatch: {identifier}/{index}")
                    swift_apple = swift_path.read_bytes() == apple_path.read_bytes()
                    fixture_apple = fixture_apple and swift_apple
                    if frame_record.get("swiftAppleExact") != swift_apple:
                        fail(f"Swift/Apple report mismatch: {identifier}/{index}")
            total_frames += frame_count
            all_python = all_python and fixture_python
            all_apple = all_apple and (fixture_apple if has_apple else True)
            if record.get("allSwiftPythonExact") != fixture_python:
                fail(f"fixture Swift/Python aggregate mismatch: {identifier}")
            expected_apple = fixture_apple if has_apple else None
            if record.get("allSwiftAppleExact") != expected_apple:
                fail(f"fixture Swift/Apple aggregate mismatch: {identifier}")
            if identifier == "APNG-SEPARATE-DEFAULT" and record.get(
                "firstAnimationFrameUsesIDAT"
            ) is not False:
                fail("separate-default timeline guard mismatch")

    if report.get("fixtureCount") != len(fixture_contract):
        fail("owned Swift playback fixture count mismatch")
    if report.get("frameCount") != total_frames:
        fail("owned Swift playback frame count mismatch")
    if report.get("allSwiftPythonExact") != all_python:
        fail("owned Swift playback Python aggregate mismatch")
    if report.get("allSwiftAppleExactWhereAvailable") != all_apple:
        fail("owned Swift playback Apple aggregate mismatch")
    separate_expected = (
        fixture_results.get("APNG-SEPARATE-DEFAULT", {}).get("allSwiftPythonExact")
        if "APNG-SEPARATE-DEFAULT" in fixture_contract
        else None
    )
    if report.get("separateDefaultTimelineExact") != separate_expected:
        fail("owned Swift playback separate-default aggregate mismatch")

    inventory = report.get("artifactInventory")
    if not isinstance(inventory, dict):
        fail("owned Swift playback artifact inventory missing")
    actual_artifacts = {
        path.resolve()
        for directory_name in ("bin", "inputs", "swift", "python", "apple")
        for path in (root / directory_name).rglob("*")
        if path.is_file()
    }
    if actual_artifacts != expected_artifacts:
        fail("owned Swift playback artifact set mismatch")
    expected_inventory = {
        str(path.relative_to(root)): support.file_identity(path)
        for path in sorted(expected_artifacts)
    }
    if inventory != expected_inventory:
        fail("owned Swift playback artifact inventory mismatch")
    allowed_root = {
        report_path.resolve(),
        manifest_path.resolve(),
        identity_path.resolve(),
    }
    unexpected = {path.resolve() for path in root.iterdir() if path.is_file()} - allowed_root
    if unexpected:
        fail("unexpected owned Swift playback root artifact")
    print(report_path)


if __name__ == "__main__":
    main()
