#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent
IMAGECRAFT = ROOT.parent / "ImageCraft"
APNGKIT = ROOT / ".artifacts/research/animation-libs/APNGKit"
APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"

SCENARIOS = {
    "OWNED-PIA-6": {
        "source": APNGKIT / "Tests/APNGKitTests/Resources/General/pia.png",
        "expectedBacking": "ownedAPNG",
        "requireReverseRandomAccessExact": True,
        "canvasWidth": 220,
        "canvasHeight": 220,
        "frameCount": 6,
        "targetWidth": 220,
        "targetHeight": 220,
        "selectedFrameIndex": 3,
    },
    "ALIGNED-FALLBACK-PEOPLE-24": {
        "source": IMAGECRAFT
        / ".artifacts/performance/animation-initial/fixtures/people-motion-24f.apng",
        "expectedBacking": "imageIOEncoded",
        "requireReverseRandomAccessExact": True,
        "canvasWidth": 256,
        "canvasHeight": 256,
        "frameCount": 24,
        "targetWidth": 256,
        "targetHeight": 256,
        "selectedFrameIndex": 12,
    },
}
TIMING_FIELDS = (
    "imageCraftPrepare",
    "directImageIOPrepareLowerBound",
    "imageCraftSelectedFrame",
    "directImageIOColdSelectedFrame",
    "directImageIORetainedSourceSelectedFrame",
    "imageCraftSequentialAllFrames",
    "directImageIORetainedSourceAllFrames",
    "directImageIOUnboundedCachedAllFrames",
)


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


support = load_module(
    "w5_apng_public_mac_performance_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)


def run(
    command: list[str], cwd: pathlib.Path = ROOT, check: bool = True
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(command)}"
        )
    return completed


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def selected_scenarios(value: str | None) -> dict[str, dict[str, object]]:
    if value is None:
        return dict(SCENARIOS)
    identifiers = [item for item in value.split(",") if item]
    if not identifiers or len(identifiers) != len(set(identifiers)):
        raise SystemExit("scenario selection must be unique and nonempty")
    unknown = set(identifiers) - set(SCENARIOS)
    if unknown:
        raise SystemExit(f"unknown performance scenarios: {sorted(unknown)}")
    return {identifier: SCENARIOS[identifier] for identifier in identifiers}


def resolve_binary(value: pathlib.Path | None) -> pathlib.Path:
    if value is not None:
        result = value.resolve()
        if not result.is_file():
            raise SystemExit(f"missing supplied ImageCraftEvidence binary: {result}")
        return result
    run(
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
    result = pathlib.Path(
        run(
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
        ).stdout.strip()
    ) / "ImageCraftEvidence"
    if not result.is_file():
        raise SystemExit(f"missing ImageCraftEvidence binary: {result}")
    return result


def command_text(command: list[str]) -> str:
    completed = run(command)
    if completed.stderr.strip():
        raise SystemExit(f"unexpected stderr from {' '.join(command)}")
    return completed.stdout.strip()


def median(samples: list[int]) -> int:
    ordered = sorted(samples)
    return ordered[len(ordered) // 2]


def p95(samples: list[int]) -> int:
    ordered = sorted(samples)
    index = min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)
    return ordered[index]


def expected_orders(iterations: int) -> dict[str, list[str]]:
    preparation = [
        "imagecraft>direct-imageio"
        if index % 2 == 0
        else "direct-imageio>imagecraft"
        for index in range(iterations)
    ]
    selected_cycle = (
        "imagecraft>direct-cold>direct-retained",
        "direct-cold>direct-retained>imagecraft",
        "direct-retained>imagecraft>direct-cold",
    )
    selected = [selected_cycle[index % 3] for index in range(iterations)]
    sequential = [
        "imagecraft-windowed>direct-retained"
        if index % 2 == 0
        else "direct-retained>imagecraft-windowed"
        for index in range(iterations)
    ]
    return {
        "preparation": preparation,
        "selectedFrame": selected,
        "sequentialFrames": sequential,
    }


def validate_timing_report(
    report: dict[str, object],
    scenario: dict[str, object],
    retained_input: pathlib.Path,
    iterations: int,
) -> None:
    expected = {
        "schemaVersion": 3,
        "container": "apng",
        "frameCount": scenario["frameCount"],
        "canvasWidth": scenario["canvasWidth"],
        "canvasHeight": scenario["canvasHeight"],
        "targetWidth": scenario["targetWidth"],
        "targetHeight": scenario["targetHeight"],
        "selectedFrameIndex": scenario["selectedFrameIndex"],
        "frameDecodeWindowSize": min(8, int(scenario["frameCount"])),
        "inputByteCount": retained_input.stat().st_size,
        "inputSHA256": sha256(retained_input.read_bytes()),
        "inputPath": str(retained_input),
    }
    for key, value in expected.items():
        if report.get(key) != value:
            raise SystemExit(f"timing report field mismatch: {key}")
    if report.get("selectedFramePixelSHA256") != report.get("directFramePixelSHA256"):
        raise SystemExit("timing selected frame pixels differ")
    if report.get("measurementOrders") != expected_orders(iterations):
        raise SystemExit("timing measurement order mismatch")
    for field in TIMING_FIELDS:
        timing = report.get(field)
        if not isinstance(timing, dict):
            raise SystemExit(f"timing report missing: {field}")
        samples = timing.get("samplesNanoseconds")
        if (
            not isinstance(samples, list)
            or len(samples) != iterations
            or any(not isinstance(item, int) or item <= 0 for item in samples)
        ):
            raise SystemExit(f"timing samples invalid: {field}")
        if timing.get("medianNanoseconds") != median(samples):
            raise SystemExit(f"timing median mismatch: {field}")
        if timing.get("p95Nanoseconds") != p95(samples):
            raise SystemExit(f"timing p95 mismatch: {field}")


def version_text(command: list[str]) -> list[str]:
    completed = run(command)
    combined = "\n".join(
        item.strip()
        for item in (completed.stdout, completed.stderr)
        if item.strip()
    )
    if not combined:
        raise SystemExit(f"version command produced no output: {' '.join(command)}")
    return combined.splitlines()


def system_identity() -> dict[str, object]:
    xctrace = run(["xcrun", "xctrace", "list", "devices"], check=False)
    physical_section = xctrace.stdout.split("== Simulators ==", 1)[0]
    online_section = physical_section.split("== Devices Offline ==", 1)[0]
    offline_section = (
        physical_section.split("== Devices Offline ==", 1)[1]
        if "== Devices Offline ==" in physical_section
        else ""
    )
    online = sum("iPhone" in line for line in online_section.splitlines())
    offline = sum("iPhone" in line for line in offline_section.splitlines())
    return {
        "macOSProductVersion": command_text(["sw_vers", "-productVersion"]),
        "macOSBuildVersion": command_text(["sw_vers", "-buildVersion"]),
        "architecture": command_text(["uname", "-m"]),
        "logicalCPUCount": os.cpu_count(),
        "xcodeVersion": version_text(["xcodebuild", "-version"]),
        "swiftVersion": version_text(["xcrun", "swift", "--version"]),
        "physicalIOSDeviceOnlineCount": online,
        "physicalIOSDeviceOfflineCount": offline,
        "physicalIOSDeviceUsed": False,
        "hostRole": "physical-mac-directional-mechanism-endpoint",
    }


def compact_result(
    timing: dict[str, object], playback: dict[str, object]
) -> dict[str, object]:
    def metric(name: str) -> dict[str, int]:
        value = timing[name]
        return {
            "medianNanoseconds": value["medianNanoseconds"],
            "p95Nanoseconds": value["p95Nanoseconds"],
        }

    prepare_ratio = (
        timing["imageCraftPrepare"]["medianNanoseconds"]
        / timing["directImageIOPrepareLowerBound"]["medianNanoseconds"]
    )
    selected_ratio = (
        timing["imageCraftSelectedFrame"]["medianNanoseconds"]
        / timing["directImageIORetainedSourceSelectedFrame"]["medianNanoseconds"]
    )
    sequential_ratio = (
        timing["imageCraftSequentialAllFrames"]["medianNanoseconds"]
        / timing["directImageIORetainedSourceAllFrames"]["medianNanoseconds"]
    )
    return {
        "backingDiagnostics": playback["preparationDiagnostics"],
        "codecFingerprint": playback["codecFingerprint"],
        "frameCount": playback["frameCount"],
        "allReverseRandomAccessExact": playback["allReverseRandomAccessExact"],
        "reverseRandomAccessMismatchCount": sum(
            frame.get("reverseRandomAccessExact") is not True
            for frame in playback.get("frames", [])
        ),
        "cancellationFenced": playback["cancellationFenced"],
        "selectedFramePixelsExact": timing["selectedFramePixelSHA256"]
        == timing["directFramePixelSHA256"],
        "metrics": {field: metric(field) for field in TIMING_FIELDS},
        "medianRatios": {
            "imageCraftPrepareOverDirectLowerBound": prepare_ratio,
            "imageCraftSelectedFrameOverDirectRetained": selected_ratio,
            "imageCraftSequentialAllFramesOverDirectRetained": sequential_ratio,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--binary", type=pathlib.Path)
    parser.add_argument("--scenarios")
    parser.add_argument("--iterations", type=int, default=18)
    parser.add_argument("--warmups", type=int, default=3)
    args = parser.parse_args()
    if args.iterations <= 0 or args.warmups < 0:
        raise SystemExit("iterations must be positive and warmups nonnegative")
    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    scenarios = selected_scenarios(args.scenarios)

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
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_public_decoder_mac_performance.py",
        "captureContract": PERFORMANCE / "test_w5_apng_public_decoder_mac_performance.py",
        "swiftPerformanceCommand": IMAGECRAFT
        / "Sources/ImageCraftEvidence/AnimationPerformanceEvidence.swift",
        "swiftPlaybackCommand": IMAGECRAFT
        / "Sources/ImageCraftEvidence/AnimationDecoderPlaybackEvidence.swift",
        "swiftEvidenceMain": IMAGECRAFT / "Sources/ImageCraftEvidence/main.swift",
        "swiftPublicDecoder": IMAGECRAFT
        / "Sources/ImageCraftImageIO/ImageIOAnimatedImageDecoder.swift",
        "swiftPreparationDiagnostics": IMAGECRAFT
        / "Sources/ImageCraftImageIO/ImageIOAnimationPreparationDiagnostics.swift",
        "swiftProvider": IMAGECRAFT
        / "Sources/ImageCraftImageIO/ImageIOAnimationFrameProvider.swift",
        "swiftOwnedPlayback": IMAGECRAFT
        / "Sources/ImageCraftImageIO/APNGOwnedStraightAlphaPlayback.swift",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    input_sources_before = {
        identifier: support.file_identity(pathlib.Path(config["source"]))
        for identifier, config in scenarios.items()
    }
    binary_source = resolve_binary(args.binary)
    bin_directory = output / "bin"
    inputs_directory = output / "inputs"
    reports_directory = output / "reports"
    playback_directory = output / "playback"
    for directory in (
        bin_directory,
        inputs_directory,
        reports_directory,
        playback_directory,
    ):
        directory.mkdir()
    binary = bin_directory / "ImageCraftEvidence"
    shutil.copy2(binary_source, binary)
    binary.chmod(0o755)

    artifacts: set[pathlib.Path] = {binary}
    scenario_results: dict[str, object] = {}
    commands: list[list[str]] = []
    for identifier, config in scenarios.items():
        source = pathlib.Path(config["source"])
        if not source.is_file():
            raise SystemExit(f"missing performance fixture: {source}")
        retained_input = inputs_directory / f"{identifier}.apng"
        shutil.copy2(source, retained_input)
        artifacts.add(retained_input)
        playback_output = playback_directory / identifier
        playback_command = [
            str(binary),
            "--animation-decoder-playback",
            str(retained_input),
            "--output-directory",
            str(playback_output),
        ]
        playback_stdout = command_text(playback_command)
        commands.append(playback_command)
        if playback_stdout != str(playback_output / "report.json"):
            raise SystemExit(f"unexpected playback output: {identifier}")
        playback_report_path = playback_output / "report.json"
        playback_report = json.loads(playback_report_path.read_text())
        if (
            playback_report.get("frameCount") != config["frameCount"]
            or playback_report.get("canvasWidth") != config["canvasWidth"]
            or playback_report.get("canvasHeight") != config["canvasHeight"]
            or (
                config["requireReverseRandomAccessExact"]
                and playback_report.get("allReverseRandomAccessExact") is not True
            )
            or playback_report.get("cancellationFenced") is not True
            or (playback_report.get("preparationDiagnostics") or {}).get("backingKind")
            != config["expectedBacking"]
        ):
            raise SystemExit(f"playback mechanism mismatch: {identifier}")
        for path in playback_output.rglob("*"):
            if path.is_file():
                artifacts.add(path)

        timing_path = reports_directory / f"{identifier}.json"
        timing_command = [
            str(binary),
            "--animation-performance",
            "--input",
            str(retained_input),
            "--output",
            str(timing_path),
            "--target-width",
            str(config["targetWidth"]),
            "--target-height",
            str(config["targetHeight"]),
            "--frame-index",
            str(config["selectedFrameIndex"]),
            "--iterations",
            str(args.iterations),
            "--warmups",
            str(args.warmups),
        ]
        timing_stdout = command_text(timing_command)
        commands.append(timing_command)
        if timing_stdout != str(timing_path):
            raise SystemExit(f"unexpected performance output: {identifier}")
        timing_report = json.loads(timing_path.read_text())
        validate_timing_report(
            timing_report, config, retained_input, args.iterations
        )
        artifacts.add(timing_path)
        scenario_results[identifier] = {
            "contract": {
                key: value
                for key, value in config.items()
                if key != "source"
            },
            "input": support.file_identity(retained_input),
            "playbackReport": support.file_identity(playback_report_path),
            "timingReport": support.file_identity(timing_path),
            "result": compact_result(timing_report, playback_report),
        }

    system = system_identity()
    source_identity = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        "sources": source_before,
        "governingFiles": governing_before,
        "inputSources": input_sources_before,
        "binary": support.file_identity(binary),
        "system": system,
        "iterations": args.iterations,
        "warmups": args.warmups,
        "scenarioContract": {
            identifier: {
                key: value
                for key, value in config.items()
                if key != "source"
            }
            for identifier, config in scenarios.items()
        },
        "claimBoundary": [
            "physical Mac host directional mechanism evidence only",
            "no online physical iOS device was used",
            "owned and aligned fallback scenarios are separate roles and are not aggregate-ranked",
            "direct ImageIO prepare is a lower bound and cached-all-frames is an unbounded comparator",
            "wall-clock results do not establish energy, thermal, allocator, or Fovea product behavior",
        ],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(
        json.dumps(source_identity, indent=2, sort_keys=True) + "\n"
    )
    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-PUBLIC-DECODER-MAC-MECHANISM-PERFORMANCE-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(binary),
        "system": system,
        "iterations": args.iterations,
        "warmups": args.warmups,
        "scenarioCount": len(scenarios),
        "scenarios": scenario_results,
        "artifactInventory": {
            str(path.relative_to(output)): support.file_identity(path)
            for path in sorted(artifacts)
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
        identifier: support.file_identity(pathlib.Path(config["source"]))
        for identifier, config in scenarios.items()
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
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(binary),
        "report": support.file_identity(report_path),
        "commands": commands,
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_public_decoder_mac_performance.py"),
            str(output),
        ],
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    for field in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if manifest[field] is not True:
            raise SystemExit(f"capture identity changed: {field}")
    run(manifest["validatorCommand"])
    print(report_path)


if __name__ == "__main__":
    main()
