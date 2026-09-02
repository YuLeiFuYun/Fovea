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
DEFAULT_INPUT = IMAGECRAFT / ".artifacts/performance/animation-initial/fixtures/people-motion-24f.apng"
SOURCE_FILES = {
    "decoder": IMAGECRAFT / "Sources/ImageCraftImageIO/ImageIOAnimatedImageDecoder.swift",
    "provider": IMAGECRAFT / "Sources/ImageCraftImageIO/ImageIOAnimationFrameProvider.swift",
    "renderer": IMAGECRAFT / "Sources/ImageCraftImageIO/ImageIOAnimationFrameRenderer.swift",
    "evidence": IMAGECRAFT / "Sources/ImageCraftEvidence/AnimationDecoderPlaybackEvidence.swift",
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
    "w5_apng_cache_divergence_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)


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
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"{completed.stdout}{completed.stderr}"
        )
    return completed.stdout.strip(), completed.stderr.strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--input", type=pathlib.Path, default=DEFAULT_INPUT)
    args = parser.parse_args()
    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    binary_source = args.binary.resolve()
    input_source = args.input.resolve()
    if not binary_source.is_file() or not input_source.is_file():
        raise SystemExit("cache divergence binary/input missing")

    source_before = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(IMAGECRAFT),
    }
    governing_paths = {
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_imageio_cache_divergence.py",
        "captureContract": PERFORMANCE / "test_w5_apng_imageio_cache_divergence.py",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    input_before = support.file_identity(input_source)

    bin_directory = output / "bin"
    source_directory = output / "sources"
    playback_directory = output / "playback"
    input_directory = output / "inputs"
    for directory in (bin_directory, source_directory, input_directory):
        directory.mkdir()
    binary = bin_directory / "ImageCraftEvidence"
    retained_input = input_directory / "people-motion-24f.apng"
    shutil.copy2(binary_source, binary)
    binary.chmod(0o755)
    shutil.copy2(input_source, retained_input)
    retained_sources: dict[str, object] = {}
    for name, source in SOURCE_FILES.items():
        retained = source_directory / source.name
        shutil.copy2(source, retained)
        retained_sources[name] = support.file_identity(retained)

    command = [
        str(binary),
        "--animation-decoder-playback",
        str(retained_input),
        "--output-directory",
        str(playback_directory),
    ]
    stdout, stderr = run_checked(command)
    if stderr or stdout != str(playback_directory / "report.json"):
        raise SystemExit("unexpected cache divergence playback output")
    playback_report_path = playback_directory / "report.json"
    playback_report = json.loads(playback_report_path.read_text())
    mismatches = [
        frame["index"]
        for frame in playback_report.get("frames", [])
        if frame.get("reverseRandomAccessExact") is not True
    ]
    if (
        playback_report.get("frameCount") != 24
        or playback_report.get("allReverseRandomAccessExact") is not False
        or playback_report.get("cancellationFenced") is not True
        or (playback_report.get("preparationDiagnostics") or {}).get("backingKind")
        != "imageIOEncoded"
        or len(mismatches) != 23
    ):
        raise SystemExit("cache divergence endpoint changed before capture")

    artifacts = {binary, retained_input, playback_report_path}
    artifacts.update(path for path in source_directory.iterdir() if path.is_file())
    artifacts.update(playback_directory.glob("frame-*.rgba"))
    source_identity = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "sources": source_before,
        "governingFiles": governing_before,
        "retainedSourceFiles": retained_sources,
        "inputSource": input_before,
        "binary": support.file_identity(binary),
        "claimBoundary": [
            "historical retained-binary correctness counterexample",
            "aligned imageIOEncoded APNG fallback only",
            "sequential windows use no-cache while frame(at:) used cached full-image materialization",
            "no timing, product, device, or ownedAPNG claim",
        ],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(
        json.dumps(source_identity, indent=2, sort_keys=True) + "\n"
    )
    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-IMAGEIO-FALLBACK-CACHE-DIVERGENCE-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "binary": support.file_identity(binary),
        "input": support.file_identity(retained_input),
        "playbackReport": support.file_identity(playback_report_path),
        "frameCount": 24,
        "reverseRandomAccessMismatchCount": len(mismatches),
        "reverseRandomAccessMismatchIndices": mismatches,
        "backingKind": "imageIOEncoded",
        "imageIOSourceIndicesMatchTimeline": True,
        "cancellationFenced": True,
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
    }
    governing_after = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    input_after = support.file_identity(input_source)
    manifest = {
        "schemaVersion": 1,
        "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_before == source_after,
        "governingFilesBefore": governing_before,
        "governingFilesAfter": governing_after,
        "governingFilesUnchangedDuringCapture": governing_before == governing_after,
        "inputSourceBefore": input_before,
        "inputSourceAfter": input_after,
        "inputSourceUnchangedDuringCapture": input_before == input_after,
        "sourceIdentity": support.file_identity(source_identity_path),
        "report": support.file_identity(report_path),
        "binary": support.file_identity(binary),
        "command": command,
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_imageio_cache_divergence.py"),
            str(output),
        ],
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    for field in (
        "sourceUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
        "inputSourceUnchangedDuringCapture",
    ):
        if manifest[field] is not True:
            raise SystemExit(f"cache divergence capture identity changed: {field}")
    run_checked(manifest["validatorCommand"])
    print(report_path)


if __name__ == "__main__":
    main()
