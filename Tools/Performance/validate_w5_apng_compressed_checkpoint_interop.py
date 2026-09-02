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
    "w5_apng_interop_validator_capture",
    PERFORMANCE / "capture_w5_apng_compressed_checkpoint_interop.py",
)
support = capture.support
model = capture.model


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity_matches(record: object, path: pathlib.Path, label: str) -> None:
    if not isinstance(record, dict):
        fail(f"{label}: identity must be an object")
    if pathlib.Path(str(record.get("path"))).resolve() != path.resolve():
        fail(f"{label}: identity path mismatch")
    if record.get("byteCount") != path.stat().st_size or record.get("sha256") != sha256(path):
        fail(f"{label}: identity mismatch")


def validate_snapshot(name: str, snapshot: object) -> None:
    if not isinstance(snapshot, dict):
        fail(f"{name}: source snapshot missing")
    for key in ("headCommit", "headTree", "workingTree"):
        value = snapshot.get(key)
        if (
            not isinstance(value, str)
            or len(value) != 40
            or any(character not in "0123456789abcdef" for character in value)
        ):
            fail(f"{name}: invalid {key}")
    if snapshot.get("dirty") != (snapshot.get("headTree") != snapshot.get("workingTree")):
        fail(f"{name}: dirty state mismatch")
    if snapshot.get("identityAlgorithm") != "git-temporary-index-add-all-write-tree-v1":
        fail(f"{name}: source identity algorithm mismatch")


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
    retained_binary = root / "bin/ImageCraftEvidence"
    for path in (report_path, manifest_path, identity_path, retained_binary):
        if not path.is_file():
            fail(f"missing interop capture file: {path}")

    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    identity = json.loads(identity_path.read_text())
    if report.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1 or identity.get("schemaVersion") != 1:
        fail("compressed checkpoint interop schema mismatch")
    if report.get("formalClaimEligible") is not False or manifest.get("formalClaimEligible") is not False or identity.get("formalClaimEligible") is not False:
        fail("compressed checkpoint interop must not activate a formal claim")
    if report.get("studyID") != "FOVEA-W5-APNG-COMPRESSED-CHECKPOINT-SWIFT-PYTHON-INTEROP-2026-08":
        fail("compressed checkpoint interop study identity mismatch")
    if manifest.get("sourceUnchangedDuringCapture") is not True:
        fail("source changed during compressed checkpoint interop capture")
    if manifest.get("governingFilesUnchangedDuringCapture") is not True:
        fail("governing files changed during compressed checkpoint interop capture")
    if manifest.get("sourceBefore") != manifest.get("sourceAfter"):
        fail("source before/after mismatch")
    if manifest.get("governingFilesBefore") != manifest.get("governingFilesAfter"):
        fail("governing file before/after mismatch")
    if identity.get("sources") != manifest.get("sourceBefore"):
        fail("source identity snapshot mismatch")
    if identity.get("governingFiles") != manifest.get("governingFilesBefore"):
        fail("source identity governing files mismatch")
    for name, snapshot in identity.get("sources", {}).items():
        validate_snapshot(name, snapshot)

    identity_matches(manifest.get("sourceIdentity"), identity_path, "manifest source identity")
    identity_matches(manifest.get("binary"), retained_binary, "manifest binary")
    identity_matches(manifest.get("report"), report_path, "manifest report")
    identity_matches(report.get("sourceIdentity"), identity_path, "report source identity")
    identity_matches(report.get("binary"), retained_binary, "report binary")
    identity_matches(identity.get("binary"), retained_binary, "identity binary")
    if not stat.S_IMODE(retained_binary.stat().st_mode) & stat.S_IXUSR:
        fail("retained ImageCraftEvidence binary is not executable")

    governing = manifest.get("governingFilesBefore")
    expected_governing = {
        "pythonCodec",
        "captureRunner",
        "validator",
        "captureContract",
        "swiftCodec",
        "swiftZlib",
        "swiftEvidenceCommand",
        "swiftEvidenceMain",
        "swiftTests",
    }
    if not isinstance(governing, dict) or set(governing) != expected_governing:
        fail("interop governing file set mismatch")
    for name, record in governing.items():
        path = pathlib.Path(str(record.get("path"))).resolve()
        if not path.is_file():
            fail(f"interop governing file missing: {name}")
        identity_matches(record, path, f"governing {name}")

    fixture_results = report.get("fixtureResults")
    fixtures = capture.fixture_bytes()
    if not isinstance(fixture_results, dict) or set(fixture_results) != set(fixtures):
        fail("interop fixture result set mismatch")
    expected_artifacts = {retained_binary.resolve()}
    all_python_to_swift = True
    all_swift_to_python = True
    all_blob_exact = True

    with tempfile.TemporaryDirectory(prefix="w5-apng-interop-validate-") as temporary:
        temporary_root = pathlib.Path(temporary)
        for fixture_id, (width, height, raw) in fixtures.items():
            fixture_root = root / "fixtures" / fixture_id
            raw_path = fixture_root / "source.rgba"
            python_blob_path = fixture_root / "python.fapc"
            swift_decoded_python_path = fixture_root / "swift-decoded-python.rgba"
            swift_blob_path = fixture_root / "swift.fapc"
            python_decoded_swift_path = fixture_root / "python-decoded-swift.rgba"
            paths = (
                raw_path,
                python_blob_path,
                swift_decoded_python_path,
                swift_blob_path,
                python_decoded_swift_path,
            )
            for path in paths:
                if not path.is_file():
                    fail(f"missing interop fixture artifact: {path}")
                expected_artifacts.add(path.resolve())
            if raw_path.read_bytes() != raw:
                fail(f"raw fixture mismatch: {fixture_id}")
            python_blob = model.encode_checkpoint_blob(raw, width, height)
            if python_blob_path.read_bytes() != python_blob:
                fail(f"Python blob mismatch: {fixture_id}")

            temporary_swift_decoded = temporary_root / f"{fixture_id}-swift-decoded.rgba"
            decode_stdout, decode_stderr = run_checked(
                [
                    str(retained_binary),
                    "--apng-checkpoint-decode",
                    str(python_blob_path),
                    "--output",
                    str(temporary_swift_decoded),
                ]
            )
            if temporary_swift_decoded.read_bytes() != raw:
                fail(f"Python-to-Swift decode mismatch: {fixture_id}")
            try:
                metadata = json.loads(decode_stderr)
            except json.JSONDecodeError as error:
                fail(f"Swift decode metadata invalid: {fixture_id}: {error}")
            if metadata != {"width": width, "height": height, "byteCount": len(raw)}:
                fail(f"Swift decode metadata mismatch: {fixture_id}")
            if decode_stdout != str(temporary_swift_decoded):
                fail(f"Swift decode stdout mismatch: {fixture_id}")

            temporary_swift_blob = temporary_root / f"{fixture_id}-swift.fapc"
            encode_stdout, encode_stderr = run_checked(
                [
                    str(retained_binary),
                    "--apng-checkpoint-encode",
                    str(raw_path),
                    "--width",
                    str(width),
                    "--height",
                    str(height),
                    "--output",
                    str(temporary_swift_blob),
                ]
            )
            if encode_stdout != str(temporary_swift_blob) or encode_stderr:
                fail(f"Swift encode command output mismatch: {fixture_id}")
            swift_blob = temporary_swift_blob.read_bytes()
            if swift_blob_path.read_bytes() != swift_blob:
                fail(f"retained Swift blob is not reproducible: {fixture_id}")
            decoded_width, decoded_height, python_decoded = model.decode_checkpoint_blob(swift_blob)
            if (decoded_width, decoded_height, python_decoded) != (width, height, raw):
                fail(f"Swift-to-Python decode mismatch: {fixture_id}")
            if swift_decoded_python_path.read_bytes() != raw:
                fail(f"retained Swift-decoded Python bytes mismatch: {fixture_id}")
            if python_decoded_swift_path.read_bytes() != raw:
                fail(f"retained Python-decoded Swift bytes mismatch: {fixture_id}")

            record = fixture_results[fixture_id]
            if not isinstance(record, dict):
                fail(f"fixture report invalid: {fixture_id}")
            for field, path in (
                ("pythonBlob", python_blob_path),
                ("swiftBlob", swift_blob_path),
                ("swiftDecodedPythonBlob", swift_decoded_python_path),
                ("pythonDecodedSwiftBlob", python_decoded_swift_path),
            ):
                identity_matches(record.get(field), path, f"{fixture_id} {field}")
            python_to_swift = temporary_swift_decoded.read_bytes() == raw
            swift_to_python = python_decoded == raw
            blob_exact = python_blob == swift_blob
            expected_difference = capture.difference(python_blob, swift_blob)
            expected_record = {
                "width": width,
                "height": height,
                "rawByteCount": len(raw),
                "rawSHA256": capture.sha256(raw),
                "pythonBlob": record["pythonBlob"],
                "swiftBlob": record["swiftBlob"],
                "pythonBlobVersusSwiftBlob": expected_difference,
                "pythonAndSwiftBlobByteExact": blob_exact,
                "swiftDecodedPythonBlob": record["swiftDecodedPythonBlob"],
                "pythonDecodedSwiftBlob": record["pythonDecodedSwiftBlob"],
                "pythonToSwiftDecodedExact": python_to_swift,
                "swiftToPythonDecodedExact": swift_to_python,
                "swiftBlobDecodedGeometry": {"width": width, "height": height},
                "swiftDecodeStdout": str(swift_decoded_python_path),
                "swiftDecodeStderr": json.dumps(
                    {"byteCount": len(raw), "height": height, "width": width},
                    separators=(",", ":"),
                    sort_keys=True,
                ),
                "swiftEncodeStdout": str(swift_blob_path),
                "swiftEncodeStderr": "",
            }
            if record != expected_record:
                fail(f"fixture report content mismatch: {fixture_id}")
            all_python_to_swift = all_python_to_swift and python_to_swift
            all_swift_to_python = all_swift_to_python and swift_to_python
            all_blob_exact = all_blob_exact and blob_exact

    if report.get("fixtureCount") != len(fixtures):
        fail("interop fixture count mismatch")
    if report.get("allPythonToSwiftDecodedExact") != all_python_to_swift:
        fail("interop Python-to-Swift aggregate mismatch")
    if report.get("allSwiftToPythonDecodedExact") != all_swift_to_python:
        fail("interop Swift-to-Python aggregate mismatch")
    if report.get("allObservedBlobBytesExact") != all_blob_exact:
        fail("interop blob exact aggregate mismatch")

    inventory = report.get("artifactInventory")
    if not isinstance(inventory, dict):
        fail("interop artifact inventory missing")
    actual_artifacts = {
        path.resolve()
        for directory in (root / "bin", root / "fixtures")
        for path in directory.rglob("*")
        if path.is_file()
    }
    if actual_artifacts != expected_artifacts:
        fail("interop artifact set mismatch")
    expected_inventory = {
        str(path.relative_to(root)): {
            "path": str(path),
            "byteCount": path.stat().st_size,
            "sha256": sha256(path),
        }
        for path in sorted(expected_artifacts)
    }
    if inventory != expected_inventory:
        fail("interop artifact inventory mismatch")

    allowed_root_files = {
        report_path.resolve(),
        manifest_path.resolve(),
        identity_path.resolve(),
    }
    unexpected_root = {
        path.resolve() for path in root.iterdir() if path.is_file()
    } - allowed_root_files
    if unexpected_root:
        fail("unexpected interop root artifact")
    print(report_path)


if __name__ == "__main__":
    main()
