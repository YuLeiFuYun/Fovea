#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent
IMAGECRAFT = ROOT.parent / "ImageCraft"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


support = load_module(
    "w5_apng_interop_capture_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)
model = load_module(
    "w5_apng_interop_compressed_model",
    PERFORMANCE / "w5_apng_compressed_checkpoint_model.py",
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fixture_bytes() -> dict[str, tuple[int, int, bytes]]:
    tiny = bytes(
        (
            255, 0, 0, 255,
            0, 255, 0, 128,
            0, 0, 255, 64,
            0, 0, 0, 0,
        )
    )
    structured = bytearray()
    for index in range(16 * 16):
        structured.extend(
            (
                index & 0xFF,
                (index * 3) & 0xFF,
                127,
                255 if index % 3 else 128,
            )
        )
    sparse = bytearray(64 * 32 * 4)
    for y in range(6, 18):
        for x in range(9, 41):
            offset = (y * 64 + x) * 4
            sparse[offset : offset + 4] = bytes((220, 40, 10, 192))
    for y in range(20, 28):
        for x in range(44, 58):
            offset = (y * 64 + x) * 4
            sparse[offset : offset + 4] = bytes((0, 120, 255, 255))
    gradient = bytearray()
    for y in range(64):
        for x in range(128):
            gradient.extend(
                (
                    (x * 2) & 0xFF,
                    (y * 4) & 0xFF,
                    (x + y) & 0xFF,
                    255 if (x + y) % 5 else 96,
                )
            )
    return {
        "TINY-2X2": (2, 2, tiny),
        "STRUCTURED-16X16": (16, 16, bytes(structured)),
        "SPARSE-64X32": (64, 32, bytes(sparse)),
        "GRADIENT-128X64": (128, 64, bytes(gradient)),
    }


def run_checked(command: list[str], cwd: pathlib.Path) -> tuple[str, str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(command)}"
        )
    return completed.stdout.strip(), completed.stderr.strip()


def difference(lhs: bytes, rhs: bytes) -> dict[str, object]:
    if len(lhs) != len(rhs):
        return {"sameLength": False, "differentByteCount": None}
    count = sum(left != right for left, right in zip(lhs, rhs))
    return {"sameLength": True, "differentByteCount": count}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--binary", type=pathlib.Path)
    args = parser.parse_args()
    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)

    source_before = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(IMAGECRAFT),
    }
    governing_paths = {
        "pythonCodec": PERFORMANCE / "w5_apng_compressed_checkpoint_model.py",
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_compressed_checkpoint_interop.py",
        "captureContract": PERFORMANCE / "test_w5_apng_compressed_checkpoint_interop.py",
        "swiftCodec": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGCompressedCheckpoint.swift",
        "swiftZlib": IMAGECRAFT / "Sources/ImageCraftImageIO/RFC1950Zlib.swift",
        "swiftEvidenceCommand": IMAGECRAFT / "Sources/ImageCraftEvidence/APNGCheckpointInteropEvidence.swift",
        "swiftEvidenceMain": IMAGECRAFT / "Sources/ImageCraftEvidence/main.swift",
        "swiftTests": IMAGECRAFT / "Tests/ImageCraftImageIOTests/APNGCompressedCheckpointTests.swift",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }

    build_command: list[str] | None = None
    if args.binary is not None:
        source_binary = args.binary.resolve()
        if not source_binary.is_file():
            raise SystemExit(f"missing supplied ImageCraftEvidence binary: {source_binary}")
    else:
        build_command = [
            "xcrun",
            "swift",
            "build",
            "--package-path",
            str(IMAGECRAFT),
            "-c",
            "release",
            "-Xswiftc",
            "-warnings-as-errors",
        ]
        run_checked(build_command, ROOT)
        bin_path_stdout, _ = run_checked(
            [
                "xcrun",
                "swift",
                "build",
                "--package-path",
                str(IMAGECRAFT),
                "-c",
                "release",
                "--show-bin-path",
            ],
            ROOT,
        )
        source_binary = pathlib.Path(bin_path_stdout) / "ImageCraftEvidence"
        if not source_binary.is_file():
            raise SystemExit(f"missing ImageCraftEvidence binary: {source_binary}")
    binary_directory = output / "bin"
    binary_directory.mkdir()
    retained_binary = binary_directory / "ImageCraftEvidence"
    shutil.copy2(source_binary, retained_binary)
    retained_binary.chmod(0o755)

    artifact_inventory: dict[str, dict[str, object]] = {
        str(retained_binary.relative_to(output)): support.file_identity(retained_binary)
    }
    fixtures_directory = output / "fixtures"
    fixtures_directory.mkdir()
    fixture_results: dict[str, object] = {}
    commands: list[list[str]] = []

    for fixture_id, (width, height, raw) in fixture_bytes().items():
        fixture_directory = fixtures_directory / fixture_id
        fixture_directory.mkdir()
        raw_path = fixture_directory / "source.rgba"
        python_blob_path = fixture_directory / "python.fapc"
        swift_decoded_python_path = fixture_directory / "swift-decoded-python.rgba"
        swift_blob_path = fixture_directory / "swift.fapc"
        python_decoded_swift_path = fixture_directory / "python-decoded-swift.rgba"
        raw_path.write_bytes(raw)
        python_blob = model.encode_checkpoint_blob(raw, width, height)
        python_blob_path.write_bytes(python_blob)

        decode_command = [
            str(retained_binary),
            "--apng-checkpoint-decode",
            str(python_blob_path),
            "--output",
            str(swift_decoded_python_path),
        ]
        decode_stdout, decode_stderr = run_checked(decode_command, ROOT)
        commands.append(decode_command)
        encode_command = [
            str(retained_binary),
            "--apng-checkpoint-encode",
            str(raw_path),
            "--width",
            str(width),
            "--height",
            str(height),
            "--output",
            str(swift_blob_path),
        ]
        encode_stdout, encode_stderr = run_checked(encode_command, ROOT)
        commands.append(encode_command)

        swift_blob = swift_blob_path.read_bytes()
        decoded_width, decoded_height, python_decoded_swift = model.decode_checkpoint_blob(
            swift_blob
        )
        python_decoded_swift_path.write_bytes(python_decoded_swift)
        swift_decoded_python = swift_decoded_python_path.read_bytes()
        for path in (
            raw_path,
            python_blob_path,
            swift_decoded_python_path,
            swift_blob_path,
            python_decoded_swift_path,
        ):
            artifact_inventory[str(path.relative_to(output))] = support.file_identity(path)
        fixture_results[fixture_id] = {
            "width": width,
            "height": height,
            "rawByteCount": len(raw),
            "rawSHA256": sha256(raw),
            "pythonBlob": support.file_identity(python_blob_path),
            "swiftBlob": support.file_identity(swift_blob_path),
            "pythonBlobVersusSwiftBlob": difference(python_blob, swift_blob),
            "pythonAndSwiftBlobByteExact": python_blob == swift_blob,
            "swiftDecodedPythonBlob": support.file_identity(swift_decoded_python_path),
            "pythonDecodedSwiftBlob": support.file_identity(python_decoded_swift_path),
            "pythonToSwiftDecodedExact": swift_decoded_python == raw,
            "swiftToPythonDecodedExact": python_decoded_swift == raw,
            "swiftBlobDecodedGeometry": {
                "width": decoded_width,
                "height": decoded_height,
            },
            "swiftDecodeStdout": decode_stdout,
            "swiftDecodeStderr": decode_stderr,
            "swiftEncodeStdout": encode_stdout,
            "swiftEncodeStderr": encode_stderr,
        }

    source_identity = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        "sources": source_before,
        "governingFiles": governing_before,
        "binary": support.file_identity(retained_binary),
        "claimBoundary": [
            "package-internal checkpoint format interoperability route only",
            "public decoder integration is validated separately; this command adds no public API and Fovea dependency pin remains unchanged",
            "four deterministic local straight-alpha fixtures",
            "binary compatibility is bound to the retained release executable and current system toolchain",
            "byte-identical compressed payloads are observed, not required as a portable contract",
        ],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(json.dumps(source_identity, indent=2, sort_keys=True) + "\n")

    all_decode_exact = all(
        record["pythonToSwiftDecodedExact"] and record["swiftToPythonDecodedExact"]
        for record in fixture_results.values()
    )
    all_blob_exact = all(
        record["pythonAndSwiftBlobByteExact"] for record in fixture_results.values()
    )
    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-COMPRESSED-CHECKPOINT-SWIFT-PYTHON-INTEROP-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(retained_binary),
        "fixtureCount": len(fixture_results),
        "allPythonToSwiftDecodedExact": all_decode_exact,
        "allSwiftToPythonDecodedExact": all_decode_exact,
        "allObservedBlobBytesExact": all_blob_exact,
        "fixtureResults": fixture_results,
        "artifactInventory": dict(sorted(artifact_inventory.items())),
        "claimBoundary": source_identity["claimBoundary"],
    }
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    source_after = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(IMAGECRAFT),
    }
    governing_after = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    manifest = {
        "schemaVersion": 1,
        "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "buildCommand": build_command,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_before == source_after,
        "governingFilesBefore": governing_before,
        "governingFilesAfter": governing_after,
        "governingFilesUnchangedDuringCapture": governing_before == governing_after,
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(retained_binary),
        "report": support.file_identity(report_path),
        "commands": commands,
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_compressed_checkpoint_interop.py"),
            str(output),
        ],
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    if not manifest["sourceUnchangedDuringCapture"]:
        raise SystemExit("source changed during compressed checkpoint interop capture")
    if not manifest["governingFilesUnchangedDuringCapture"]:
        raise SystemExit("governing file changed during compressed checkpoint interop capture")
    run_checked(manifest["validatorCommand"], ROOT)
    print(report_path)


if __name__ == "__main__":
    main()
