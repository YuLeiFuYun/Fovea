#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent
IMAGECRAFT = ROOT.parent / "ImageCraft"
APNGKIT = ROOT / ".artifacts/research/animation-libs/APNGKit"
FIXTURE_ROOT = APNGKIT / "Tests/APNGKitTests/Resources"
APPLE_ORACLE = ROOT / ".artifacts/performance/w5-apng-composition-oracle-v5"
APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"

FIXTURES = {
    "APNG-OVER-NONE": ("General/over_none.apng", 150, 150, 3, True),
    "APNG-OVER-BACKGROUND": ("General/over_background.apng", 150, 150, 3, True),
    "APNG-OVER-PREVIOUS": ("General/over_previous.apng", 150, 150, 3, True),
    "APNG-SUBRECT-NONE": ("SpecTesting/013.png", 128, 64, 3, True),
    "APNG-SUBRECT-BACKGROUND": ("SpecTesting/015.png", 128, 64, 3, True),
    "APNG-SUBRECT-PREVIOUS-SOURCE": ("General/pia.png", 220, 220, 6, True),
    "APNG-SEPARATE-DEFAULT": ("SpecTesting/016.png", 128, 64, 3, False),
}


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


support = load_module(
    "w5_apng_owned_swift_capture_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)
reference = load_module(
    "w5_apng_owned_swift_reference",
    PERFORMANCE / "w5_apng_reference.py",
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_checked(command: list[str], cwd: pathlib.Path = ROOT) -> tuple[str, str]:
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


def select_fixtures(value: str | None) -> dict[str, tuple[str, int, int, int, bool]]:
    if value is None:
        return dict(FIXTURES)
    requested = [item for item in value.split(",") if item]
    if not requested or len(requested) != len(set(requested)):
        raise SystemExit("fixture selection must be unique and nonempty")
    unknown = set(requested) - set(FIXTURES)
    if unknown:
        raise SystemExit(f"unknown fixtures: {sorted(unknown)}")
    return {identifier: FIXTURES[identifier] for identifier in requested}


def build_or_resolve_binary(binary: pathlib.Path | None) -> pathlib.Path:
    if binary is not None:
        resolved = binary.resolve()
        if not resolved.is_file():
            raise SystemExit(f"missing supplied ImageCraftEvidence binary: {resolved}")
        return resolved
    run_checked(
        [
            "xcrun",
            "swift",
            "build",
            "--package-path",
            str(IMAGECRAFT),
            "-c",
            "release",
            "--product",
            "ImageCraftEvidence",
            "-Xswiftc",
            "-warnings-as-errors",
        ]
    )
    bin_path, _ = run_checked(
        [
            "xcrun",
            "swift",
            "build",
            "--package-path",
            str(IMAGECRAFT),
            "-c",
            "release",
            "--show-bin-path",
        ]
    )
    result = pathlib.Path(bin_path) / "ImageCraftEvidence"
    if not result.is_file():
        raise SystemExit(f"missing ImageCraftEvidence binary: {result}")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--binary", type=pathlib.Path)
    parser.add_argument("--fixtures")
    args = parser.parse_args()
    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    fixtures = select_fixtures(args.fixtures)

    source_before = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(IMAGECRAFT),
        "APNGKit": support.git_snapshot(APNGKIT),
    }
    if (
        source_before["APNGKit"]["headCommit"] != APNGKIT_COMMIT
        or source_before["APNGKit"]["dirty"] is not False
    ):
        raise SystemExit("APNGKit fixture checkout must match the clean exact commit")

    governing_paths = {
        "pythonReference": PERFORMANCE / "w5_apng_reference.py",
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_owned_swift_playback.py",
        "captureContract": PERFORMANCE / "test_w5_apng_owned_swift_playback.py",
        "swiftCheckpoint": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGCompressedCheckpoint.swift",
        "swiftPlayback": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGOwnedStraightAlphaPlayback.swift",
        "swiftRawDecoder": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGRawSubrectDecoder.swift",
        "swiftZlib": IMAGECRAFT / "Sources/ImageCraftImageIO/RFC1950Zlib.swift",
        "swiftEvidence": IMAGECRAFT / "Sources/ImageCraftEvidence/APNGOwnedPlaybackEvidence.swift",
        "swiftEvidenceMain": IMAGECRAFT / "Sources/ImageCraftEvidence/main.swift",
        "swiftTests": IMAGECRAFT / "Tests/ImageCraftImageIOTests/APNGRawSubrectDecoderTests.swift",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    oracle_inputs = {
        "aggregate": support.file_identity(APPLE_ORACLE / "aggregate.json"),
        "manifest": support.file_identity(APPLE_ORACLE / "capture-manifest.json"),
        "sourceIdentity": support.file_identity(APPLE_ORACLE / "source-identity.json"),
    }
    aggregate = json.loads((APPLE_ORACLE / "aggregate.json").read_text())
    oracle_inventory = aggregate.get("artifactInventory") or {}

    source_binary = build_or_resolve_binary(args.binary)
    binary_directory = output / "bin"
    binary_directory.mkdir()
    retained_binary = binary_directory / "ImageCraftEvidence"
    shutil.copy2(source_binary, retained_binary)
    retained_binary.chmod(0o755)

    inputs_directory = output / "inputs"
    swift_directory = output / "swift"
    python_directory = output / "python"
    apple_directory = output / "apple"
    for directory in (inputs_directory, swift_directory, python_directory, apple_directory):
        directory.mkdir()

    input_sources_before: dict[str, object] = {}
    fixture_results: dict[str, object] = {}
    commands: list[list[str]] = []
    expected_artifacts: set[pathlib.Path] = {retained_binary}

    for identifier, (relative, width, height, frame_count, has_apple) in fixtures.items():
        source_input = FIXTURE_ROOT / relative
        input_sources_before[identifier] = support.file_identity(source_input)
        retained_input = inputs_directory / f"{identifier}.apng"
        shutil.copy2(source_input, retained_input)
        expected_artifacts.add(retained_input)

        swift_output = swift_directory / identifier
        command = [
            str(retained_binary),
            "--apng-owned-playback",
            str(retained_input),
            "--output-directory",
            str(swift_output),
        ]
        stdout, stderr = run_checked(command)
        commands.append(command)
        if stderr or stdout != str(swift_output / "report.json"):
            raise SystemExit(f"unexpected Swift command output: {identifier}")
        swift_report_path = swift_output / "report.json"
        swift_report = json.loads(swift_report_path.read_text())
        if (
            swift_report.get("canvasWidth") != width
            or swift_report.get("canvasHeight") != height
            or swift_report.get("frameCount") != frame_count
        ):
            raise SystemExit(f"Swift metadata mismatch: {identifier}")

        image = reference.parse_apng_file(retained_input)
        composed = reference.compose_frames(image)
        if (image.canvas_width, image.canvas_height, len(composed)) != (
            width,
            height,
            frame_count,
        ):
            raise SystemExit(f"Python reference metadata mismatch: {identifier}")
        python_fixture = python_directory / identifier
        python_fixture.mkdir()
        swift_exact: list[bool] = []
        apple_exact: list[bool] = []
        frame_records: list[dict[str, object]] = []
        expected_artifacts.add(swift_report_path)
        for index, frame in enumerate(composed):
            python_path = python_fixture / f"frame-{index:03d}.rgba"
            python_path.write_bytes(frame.premultiplied_rgba)
            expected_artifacts.add(python_path)
            swift_path = swift_output / f"frame-{index:03d}.rgba"
            if not swift_path.is_file():
                raise SystemExit(f"missing Swift frame: {identifier}/{index}")
            expected_artifacts.add(swift_path)
            swift_bytes = swift_path.read_bytes()
            python_bytes = python_path.read_bytes()
            swift_exact.append(swift_bytes == python_bytes)
            record: dict[str, object] = {
                "index": index,
                "swift": support.file_identity(swift_path),
                "python": support.file_identity(python_path),
                "swiftPythonExact": swift_bytes == python_bytes,
            }
            if has_apple:
                oracle_name = f"{identifier}-frame-{index:02d}-AppleImageIO.rgba"
                oracle_path = APPLE_ORACLE / oracle_name
                oracle_record = oracle_inventory.get(oracle_name)
                if not isinstance(oracle_record, dict):
                    raise SystemExit(f"missing Apple oracle inventory entry: {oracle_name}")
                if (
                    oracle_record.get("byteCount") != oracle_path.stat().st_size
                    or oracle_record.get("sha256") != sha256(oracle_path.read_bytes())
                ):
                    raise SystemExit(f"Apple oracle identity mismatch: {oracle_name}")
                apple_fixture = apple_directory / identifier
                apple_fixture.mkdir(exist_ok=True)
                apple_path = apple_fixture / f"frame-{index:03d}.rgba"
                shutil.copy2(oracle_path, apple_path)
                expected_artifacts.add(apple_path)
                apple_bytes = apple_path.read_bytes()
                apple_exact.append(swift_bytes == apple_bytes)
                record["apple"] = support.file_identity(apple_path)
                record["swiftAppleExact"] = swift_bytes == apple_bytes
            frame_records.append(record)

        fixture_results[identifier] = {
            "relativePath": relative,
            "input": support.file_identity(retained_input),
            "canvasWidth": width,
            "canvasHeight": height,
            "frameCount": frame_count,
            "hasAppleOracle": has_apple,
            "firstAnimationFrameUsesIDAT": swift_report.get(
                "firstAnimationFrameUsesIDAT"
            ),
            "allSwiftPythonExact": all(swift_exact),
            "allSwiftAppleExact": all(apple_exact) if has_apple else None,
            "swiftReport": support.file_identity(swift_report_path),
            "diagnostics": swift_report.get("diagnostics"),
            "frames": frame_records,
        }

    source_identity = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        "sources": source_before,
        "governingFiles": governing_before,
        "appleOracleInputs": oracle_inputs,
        "binary": support.file_identity(retained_binary),
        "fixtureContract": {
            key: {
                "relativePath": value[0],
                "canvasWidth": value[1],
                "canvasHeight": value[2],
                "frameCount": value[3],
                "hasAppleOracle": value[4],
            }
            for key, value in fixtures.items()
        },
        "claimBoundary": [
            "package-only evidence route for the owned APNG mechanism; public decoder integration is validated separately",
            "RGBA8 non-interlaced APNG subset only",
            "correctness and modeled byte accounting only",
            "this command does not itself establish the public decoder route and Fovea dependency pin remains unchanged",
            "Apple sidecars are retained inputs from the bound prior oracle capture",
            "no latency, energy, thermal, or physical-device claim",
        ],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(
        json.dumps(source_identity, indent=2, sort_keys=True) + "\n"
    )

    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-OWNED-SWIFT-PLAYBACK-ORACLE-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(retained_binary),
        "fixtureCount": len(fixtures),
        "frameCount": sum(record[3] for record in fixtures.values()),
        "allSwiftPythonExact": all(
            result["allSwiftPythonExact"] for result in fixture_results.values()
        ),
        "allSwiftAppleExactWhereAvailable": all(
            result["allSwiftAppleExact"]
            for result in fixture_results.values()
            if result["hasAppleOracle"]
        ),
        "separateDefaultTimelineExact": fixture_results.get(
            "APNG-SEPARATE-DEFAULT", {}
        ).get("allSwiftPythonExact"),
        "fixtureResults": fixture_results,
        "artifactInventory": {
            str(path.relative_to(output)): support.file_identity(path)
            for path in sorted(expected_artifacts)
        },
    }
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    source_after = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(IMAGECRAFT),
        "APNGKit": support.git_snapshot(APNGKIT),
    }
    input_sources_after = {
        identifier: support.file_identity(FIXTURE_ROOT / record[0])
        for identifier, record in fixtures.items()
    }
    governing_after = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    manifest = {
        "schemaVersion": 1,
        "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_before == source_after,
        "inputSourcesBefore": input_sources_before,
        "inputSourcesAfter": input_sources_after,
        "inputSourcesUnchangedDuringCapture": input_sources_before
        == input_sources_after,
        "governingFilesBefore": governing_before,
        "governingFilesAfter": governing_after,
        "governingFilesUnchangedDuringCapture": governing_before == governing_after,
        "appleOracleInputs": oracle_inputs,
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(retained_binary),
        "report": support.file_identity(report_path),
        "commands": commands,
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_owned_swift_playback.py"),
            str(output),
        ],
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    for key in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if not manifest[key]:
            raise SystemExit(f"capture identity changed: {key}")
    run_checked(manifest["validatorCommand"])
    print(report_path)


if __name__ == "__main__":
    main()
