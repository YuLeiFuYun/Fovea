#!/usr/bin/env python3
from __future__ import annotations

import argparse
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
    "w5_apng_cache_divergence_validator_capture",
    PERFORMANCE / "capture_w5_apng_imageio_cache_divergence.py",
)
support = capture.support


def fail(message: str) -> None:
    raise SystemExit(message)


def identity_matches(record: object, path: pathlib.Path, label: str) -> None:
    if not isinstance(record, dict) or support.file_identity(path) != record:
        fail(f"{label}: identity mismatch")


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
            f"retained cache divergence command failed ({completed.returncode})\n"
            f"{completed.stdout}{completed.stderr}"
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
    input_path = root / "inputs/people-motion-24f.apng"
    playback_path = root / "playback/report.json"
    for path in (report_path, manifest_path, identity_path, binary, input_path, playback_path):
        if not path.is_file():
            fail(f"missing cache divergence artifact: {path}")
    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    identity = json.loads(identity_path.read_text())
    if report.get("studyID") != "FOVEA-W5-APNG-IMAGEIO-FALLBACK-CACHE-DIVERGENCE-2026-08":
        fail("cache divergence study identity mismatch")
    if any(item.get("formalClaimEligible") is not False for item in (report, manifest, identity)):
        fail("cache divergence must remain non-formal")
    if manifest.get("sourceBefore") != manifest.get("sourceAfter"):
        fail("source before/after mismatch")
    if manifest.get("governingFilesBefore") != manifest.get("governingFilesAfter"):
        fail("governing files before/after mismatch")
    if manifest.get("inputSourceBefore") != manifest.get("inputSourceAfter"):
        fail("input source before/after mismatch")
    for field in (
        "sourceUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
        "inputSourceUnchangedDuringCapture",
    ):
        if manifest.get(field) is not True:
            fail(f"cache divergence identity flag failed: {field}")
    identity_matches(manifest.get("sourceIdentity"), identity_path, "manifest source identity")
    identity_matches(manifest.get("report"), report_path, "manifest report")
    identity_matches(manifest.get("binary"), binary, "manifest binary")
    identity_matches(report.get("sourceIdentity"), identity_path, "report source identity")
    identity_matches(report.get("binary"), binary, "report binary")
    identity_matches(report.get("input"), input_path, "report input")
    identity_matches(report.get("playbackReport"), playback_path, "report playback")
    if not stat.S_IMODE(binary.stat().st_mode) & stat.S_IXUSR:
        fail("cache divergence binary is not executable")
    for name, record in (identity.get("governingFiles") or {}).items():
        identity_matches(record, pathlib.Path(record["path"]), f"governing {name}")
    retained_sources = identity.get("retainedSourceFiles") or {}
    if set(retained_sources) != set(capture.SOURCE_FILES):
        fail("retained source file set mismatch")
    for name, record in retained_sources.items():
        path = root / "sources" / pathlib.Path(record["path"]).name
        identity_matches(record, path, f"retained source {name}")

    playback = json.loads(playback_path.read_text())
    mismatches = [
        frame["index"]
        for frame in playback.get("frames", [])
        if frame.get("reverseRandomAccessExact") is not True
    ]
    if (
        playback.get("frameCount") != 24
        or playback.get("allReverseRandomAccessExact") is not False
        or playback.get("cancellationFenced") is not True
        or (playback.get("preparationDiagnostics") or {}).get("backingKind")
        != "imageIOEncoded"
        or mismatches != report.get("reverseRandomAccessMismatchIndices")
        or len(mismatches) != report.get("reverseRandomAccessMismatchCount")
        or len(mismatches) != 23
    ):
        fail("cache divergence result mismatch")

    with tempfile.TemporaryDirectory(prefix="w5-apng-cache-divergence-") as temporary:
        rerun = pathlib.Path(temporary) / "playback"
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
            fail("cache divergence rerun output mismatch")
        if json.loads((rerun / "report.json").read_text()) != playback:
            fail("cache divergence playback is not reproducible")
        for retained in sorted((root / "playback").glob("frame-*.rgba")):
            repeated = rerun / retained.name
            if repeated.read_bytes() != retained.read_bytes():
                fail("cache divergence sequential frame is not reproducible")

    expected_artifacts = {binary.resolve(), input_path.resolve(), playback_path.resolve()}
    expected_artifacts.update(path.resolve() for path in (root / "sources").iterdir() if path.is_file())
    expected_artifacts.update(path.resolve() for path in (root / "playback").glob("frame-*.rgba"))
    actual_artifacts = {
        path.resolve()
        for directory in ("bin", "inputs", "sources", "playback")
        for path in (root / directory).rglob("*")
        if path.is_file()
    }
    if actual_artifacts != expected_artifacts:
        fail("cache divergence artifact set mismatch")
    inventory = report.get("artifactInventory")
    expected_inventory = {
        str(path.relative_to(root)): support.file_identity(path)
        for path in sorted(expected_artifacts)
    }
    if inventory != expected_inventory:
        fail("cache divergence artifact inventory mismatch")
    allowed_root = {report_path.resolve(), manifest_path.resolve(), identity_path.resolve()}
    if {path.resolve() for path in root.iterdir() if path.is_file()} - allowed_root:
        fail("unexpected cache divergence root artifact")
    print(report_path)


if __name__ == "__main__":
    main()
