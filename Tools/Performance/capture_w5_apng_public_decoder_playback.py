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
CODEC_FINGERPRINT = "dev.fovea.imageio.animation#impl=2#contract=2"

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
    "w5_apng_public_decoder_capture_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)
reference = load_module(
    "w5_apng_public_decoder_reference",
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


def selected_fixtures(value: str | None) -> dict[str, tuple[str, int, int, int, bool]]:
    if value is None:
        return dict(FIXTURES)
    identifiers = [item for item in value.split(",") if item]
    if not identifiers or len(identifiers) != len(set(identifiers)):
        raise SystemExit("fixture selection must be unique and nonempty")
    unknown = set(identifiers) - set(FIXTURES)
    if unknown:
        raise SystemExit(f"unknown fixture identifiers: {sorted(unknown)}")
    return {identifier: FIXTURES[identifier] for identifier in identifiers}


def resolve_binary(value: pathlib.Path | None) -> pathlib.Path:
    if value is not None:
        result = value.resolve()
        if not result.is_file():
            raise SystemExit(f"missing supplied ImageCraftEvidence binary: {result}")
        return result
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


def descriptor(control) -> dict[str, object]:
    import math

    denominator = control.delay_den or 100
    divisor = math.gcd(control.delay_num, denominator)
    numerator = control.delay_num // divisor
    canonical_denominator = denominator // divisor
    return {
        "rect": {
            "x": control.x_offset,
            "y": control.y_offset,
            "width": control.width,
            "height": control.height,
        },
        "durationNumerator": numerator,
        "durationDenominator": canonical_denominator,
        "disposal": {0: "none", 1: "background", 2: "previous"}[
            control.dispose_op
        ],
        "blend": {0: "source", 1: "over"}[control.blend_op],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--binary", type=pathlib.Path)
    parser.add_argument("--fixtures")
    args = parser.parse_args()
    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    fixtures = selected_fixtures(args.fixtures)

    source_before = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(IMAGECRAFT),
        "APNGKit": support.git_snapshot(APNGKIT),
    }
    if (
        source_before["APNGKit"]["headCommit"] != APNGKIT_COMMIT
        or source_before["APNGKit"]["dirty"] is not False
    ):
        raise SystemExit("APNGKit checkout must match the clean exact commit")

    governing_paths = {
        "pythonReference": PERFORMANCE / "w5_apng_reference.py",
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_public_decoder_playback.py",
        "captureContract": PERFORMANCE / "test_w5_apng_public_decoder_playback.py",
        "swiftPublicDecoder": IMAGECRAFT / "Sources/ImageCraftImageIO/ImageIOAnimatedImageDecoder.swift",
        "swiftPreparationDiagnostics": IMAGECRAFT / "Sources/ImageCraftImageIO/ImageIOAnimationPreparationDiagnostics.swift",
        "swiftProvider": IMAGECRAFT / "Sources/ImageCraftImageIO/ImageIOAnimationFrameProvider.swift",
        "swiftRenderer": IMAGECRAFT / "Sources/ImageCraftImageIO/ImageIOAnimationFrameRenderer.swift",
        "swiftOwnedIntegration": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGOwnedAnimationIntegration.swift",
        "swiftOwnedPlayback": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGOwnedStraightAlphaPlayback.swift",
        "swiftRawDecoder": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGRawSubrectDecoder.swift",
        "swiftCheckpoint": IMAGECRAFT / "Sources/ImageCraftImageIO/APNGCompressedCheckpoint.swift",
        "swiftRFC1950": IMAGECRAFT / "Sources/ImageCraftImageIO/RFC1950Zlib.swift",
        "swiftEvidence": IMAGECRAFT / "Sources/ImageCraftEvidence/AnimationDecoderPlaybackEvidence.swift",
        "swiftEvidenceMain": IMAGECRAFT / "Sources/ImageCraftEvidence/main.swift",
        "swiftPublicTests": IMAGECRAFT / "Tests/ImageCraftImageIOTests/AnimatedImageDecoderTests.swift",
        "swiftOwnedTests": IMAGECRAFT / "Tests/ImageCraftImageIOTests/APNGRawSubrectDecoderTests.swift",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    oracle_inputs = {
        "aggregate": support.file_identity(APPLE_ORACLE / "aggregate.json"),
        "manifest": support.file_identity(APPLE_ORACLE / "capture-manifest.json"),
        "sourceIdentity": support.file_identity(APPLE_ORACLE / "source-identity.json"),
    }
    oracle_inventory = json.loads((APPLE_ORACLE / "aggregate.json").read_text()).get(
        "artifactInventory", {}
    )

    binary_source = resolve_binary(args.binary)
    bin_directory = output / "bin"
    input_directory = output / "inputs"
    public_directory = output / "public"
    python_directory = output / "python"
    apple_directory = output / "apple"
    for directory in (
        bin_directory,
        input_directory,
        public_directory,
        python_directory,
        apple_directory,
    ):
        directory.mkdir()
    binary = bin_directory / "ImageCraftEvidence"
    shutil.copy2(binary_source, binary)
    binary.chmod(0o755)

    input_sources_before: dict[str, object] = {}
    results: dict[str, object] = {}
    expected_artifacts: set[pathlib.Path] = {binary}
    commands: list[list[str]] = []

    for identifier, (relative, width, height, frame_count, has_apple) in fixtures.items():
        source_input = FIXTURE_ROOT / relative
        input_sources_before[identifier] = support.file_identity(source_input)
        retained_input = input_directory / f"{identifier}.apng"
        shutil.copy2(source_input, retained_input)
        expected_artifacts.add(retained_input)

        public_output = public_directory / identifier
        command = [
            str(binary),
            "--animation-decoder-playback",
            str(retained_input),
            "--output-directory",
            str(public_output),
        ]
        stdout, stderr = run_checked(command)
        commands.append(command)
        if stderr or stdout != str(public_output / "report.json"):
            raise SystemExit(f"unexpected public decoder command output: {identifier}")
        public_report_path = public_output / "report.json"
        public_report = json.loads(public_report_path.read_text())
        diagnostics = public_report.get("preparationDiagnostics")
        expected_alignment = identifier != "APNG-SEPARATE-DEFAULT"
        canvas_bytes = width * height * 4
        if (
            public_report.get("codecFingerprint") != CODEC_FINGERPRINT
            or public_report.get("container") != "apng"
            or public_report.get("canvasWidth") != width
            or public_report.get("canvasHeight") != height
            or public_report.get("frameCount") != frame_count
            or public_report.get("allReverseRandomAccessExact") is not True
            or public_report.get("cancellationFenced") is not True
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
            or not isinstance(diagnostics.get("ownedEncodedFramePayloadBytes"), int)
            or diagnostics["ownedEncodedFramePayloadBytes"] <= 0
            or not isinstance(diagnostics.get("ownedRetainedBytes"), int)
            or diagnostics["ownedRetainedBytes"] <= 0
            or diagnostics["ownedRetainedBytes"] > 32 * 1024 * 1024
            or not isinstance(diagnostics.get("ownedMaximumRawSubrectRGBABytes"), int)
            or diagnostics["ownedMaximumRawSubrectRGBABytes"] <= 0
            or diagnostics["ownedMaximumRawSubrectRGBABytes"] > canvas_bytes
            or not isinstance(diagnostics.get("ownedMaximumPreviousSaveRGBABytes"), int)
            or diagnostics["ownedMaximumPreviousSaveRGBABytes"] < 0
            or not isinstance(diagnostics.get("ownedModeledPeakBytesUpperBound"), int)
            or diagnostics["ownedModeledPeakBytesUpperBound"]
            <= diagnostics["ownedRetainedBytes"]
        ):
            raise SystemExit(f"public decoder report contract mismatch: {identifier}")
        expected_artifacts.add(public_report_path)

        image = reference.parse_apng_file(retained_input)
        composed = reference.compose_frames(image)
        if (image.canvas_width, image.canvas_height, len(composed)) != (
            width,
            height,
            frame_count,
        ):
            raise SystemExit(f"Python reference metadata mismatch: {identifier}")
        public_frames = public_report.get("frames")
        if not isinstance(public_frames, list) or len(public_frames) != frame_count:
            raise SystemExit(f"public decoder frame records mismatch: {identifier}")
        python_fixture = python_directory / identifier
        python_fixture.mkdir()
        public_python_exact: list[bool] = []
        public_apple_exact: list[bool] = []
        frame_results: list[dict[str, object]] = []
        for index, (raw_frame, composed_frame, public_record) in enumerate(
            zip(image.frames, composed, public_frames)
        ):
            expected_descriptor = descriptor(raw_frame.control)
            observed_descriptor = {
                key: public_record.get(key)
                for key in (
                    "rect",
                    "durationNumerator",
                    "durationDenominator",
                    "disposal",
                    "blend",
                )
            }
            if observed_descriptor != expected_descriptor:
                raise SystemExit(f"public descriptor mismatch: {identifier}/{index}")
            if (
                public_record.get("index") != index
                or public_record.get("reverseRandomAccessExact") is not True
            ):
                raise SystemExit(f"public random access record mismatch: {identifier}/{index}")
            public_path = public_output / f"frame-{index:03d}.rgba"
            python_path = python_fixture / f"frame-{index:03d}.rgba"
            python_path.write_bytes(composed_frame.premultiplied_rgba)
            for path in (public_path, python_path):
                if not path.is_file():
                    raise SystemExit(f"missing frame artifact: {path}")
                expected_artifacts.add(path)
            public_bytes = public_path.read_bytes()
            python_bytes = python_path.read_bytes()
            public_python_exact.append(public_bytes == python_bytes)
            record: dict[str, object] = {
                "index": index,
                "public": support.file_identity(public_path),
                "python": support.file_identity(python_path),
                "publicPythonExact": public_bytes == python_bytes,
                "descriptor": expected_descriptor,
            }
            if has_apple:
                oracle_name = f"{identifier}-frame-{index:02d}-AppleImageIO.rgba"
                oracle_path = APPLE_ORACLE / oracle_name
                oracle_record = oracle_inventory.get(oracle_name)
                if not isinstance(oracle_record, dict):
                    raise SystemExit(f"missing Apple oracle entry: {oracle_name}")
                if (
                    oracle_path.stat().st_size != oracle_record.get("byteCount")
                    or sha256(oracle_path.read_bytes()) != oracle_record.get("sha256")
                ):
                    raise SystemExit(f"Apple oracle identity mismatch: {oracle_name}")
                apple_fixture = apple_directory / identifier
                apple_fixture.mkdir(exist_ok=True)
                apple_path = apple_fixture / f"frame-{index:03d}.rgba"
                shutil.copy2(oracle_path, apple_path)
                expected_artifacts.add(apple_path)
                apple_bytes = apple_path.read_bytes()
                public_apple_exact.append(public_bytes == apple_bytes)
                record["apple"] = support.file_identity(apple_path)
                record["publicAppleExact"] = public_bytes == apple_bytes
            frame_results.append(record)

        results[identifier] = {
            "relativePath": relative,
            "input": support.file_identity(retained_input),
            "canvasWidth": width,
            "canvasHeight": height,
            "frameCount": frame_count,
            "hasAppleOracle": has_apple,
            "codecFingerprint": public_report["codecFingerprint"],
            "preparationDiagnostics": diagnostics,
            "allReverseRandomAccessExact": public_report["allReverseRandomAccessExact"],
            "cancellationFenced": public_report["cancellationFenced"],
            "allPublicPythonExact": all(public_python_exact),
            "allPublicAppleExact": all(public_apple_exact) if has_apple else None,
            "publicReport": support.file_identity(public_report_path),
            "frames": frame_results,
        }

    source_identity = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        "sources": source_before,
        "governingFiles": governing_before,
        "appleOracleInputs": oracle_inputs,
        "binary": support.file_identity(binary),
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
            "public ImageIOAnimatedImageDecoder and AnimatedImageAsset provider route",
            "owned APNG admission remains RGBA8 non-interlaced and maximum dimension 1024",
            "unsupported aligned APNG may use ImageIO; unsupported unaligned timelines fail closed",
            "full-canvas convertToSRGB correctness, reverse access and cancellation only",
            "no Fovea dependency pin, latency, energy, thermal, or physical-device claim",
        ],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(
        json.dumps(source_identity, indent=2, sort_keys=True) + "\n"
    )

    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-PUBLIC-IMAGECRAFT-DECODER-PLAYBACK-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(binary),
        "codecFingerprint": CODEC_FINGERPRINT,
        "fixtureCount": len(fixtures),
        "frameCount": sum(item[3] for item in fixtures.values()),
        "allPublicPythonExact": all(
            result["allPublicPythonExact"] for result in results.values()
        ),
        "allPublicAppleExactWhereAvailable": all(
            result["allPublicAppleExact"]
            for result in results.values()
            if result["hasAppleOracle"]
        ),
        "allReverseRandomAccessExact": all(
            result["allReverseRandomAccessExact"] for result in results.values()
        ),
        "allCancellationFenced": all(
            result["cancellationFenced"] for result in results.values()
        ),
        "allBackingsOwnedAPNG": all(
            result["preparationDiagnostics"]["backingKind"] == "ownedAPNG"
            for result in results.values()
        ),
        "allRealFixtureCheckpointCountsZero": all(
            result["preparationDiagnostics"]["ownedRetainedCheckpointCount"] == 0
            for result in results.values()
        ),
        "allOwnedRetainedWithin32MiB": all(
            result["preparationDiagnostics"]["ownedRetainedBytes"]
            <= 32 * 1024 * 1024
            for result in results.values()
        ),
        "separateDefaultTimelineExact": results.get(
            "APNG-SEPARATE-DEFAULT", {}
        ).get("allPublicPythonExact"),
        "fixtureResults": results,
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
        identifier: support.file_identity(FIXTURE_ROOT / values[0])
        for identifier, values in fixtures.items()
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
        "binary": support.file_identity(binary),
        "report": support.file_identity(report_path),
        "commands": commands,
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_public_decoder_playback.py"),
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
        if manifest[key] is not True:
            raise SystemExit(f"capture identity changed: {key}")
    run_checked(manifest["validatorCommand"])
    print(report_path)


if __name__ == "__main__":
    main()
