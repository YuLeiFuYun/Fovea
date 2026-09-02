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
    "w5_apng_public_mac_performance_validator_capture",
    PERFORMANCE / "capture_w5_apng_public_decoder_mac_performance.py",
)
support = capture.support


def fail(message: str) -> None:
    raise SystemExit(message)


def identity_matches(record: object, path: pathlib.Path, label: str) -> None:
    if not isinstance(record, dict):
        fail(f"{label}: identity missing")
    if pathlib.Path(str(record.get("path"))).resolve() != path.resolve():
        fail(f"{label}: identity path mismatch")
    actual = support.file_identity(path)
    if actual != record:
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
            f"retained playback command failed ({completed.returncode}): "
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
            fail(f"missing Mac performance capture file: {path}")
    report = json.loads(report_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    identity = json.loads(identity_path.read_text())
    if report.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1 or identity.get("schemaVersion") != 1:
        fail("Mac performance schema mismatch")
    if report.get("studyID") != "FOVEA-W5-APNG-PUBLIC-DECODER-MAC-MECHANISM-PERFORMANCE-2026-08":
        fail("Mac performance study identity mismatch")
    if any(item.get("formalClaimEligible") is not False for item in (report, manifest, identity)):
        fail("Mac performance evidence must not activate a formal claim")
    for field in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if manifest.get(field) is not True:
            fail(f"Mac performance identity flag failed: {field}")
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
    if identity.get("inputSources") != manifest.get("inputSourcesBefore"):
        fail("source identity input mismatch")
    for name, snapshot in (identity.get("sources") or {}).items():
        validate_snapshot(name, snapshot)

    identity_matches(manifest.get("sourceIdentity"), identity_path, "manifest source identity")
    identity_matches(manifest.get("binary"), binary, "manifest binary")
    identity_matches(manifest.get("report"), report_path, "manifest report")
    identity_matches(report.get("sourceIdentity"), identity_path, "report source identity")
    identity_matches(report.get("binary"), binary, "report binary")
    identity_matches(identity.get("binary"), binary, "identity binary")
    if not stat.S_IMODE(binary.stat().st_mode) & stat.S_IXUSR:
        fail("retained performance binary is not executable")
    for name, record in (identity.get("governingFiles") or {}).items():
        identity_matches(record, pathlib.Path(record["path"]), f"governing {name}")
    for name, record in (identity.get("inputSources") or {}).items():
        identity_matches(record, pathlib.Path(record["path"]), f"source input {name}")

    iterations = identity.get("iterations")
    warmups = identity.get("warmups")
    if (
        not isinstance(iterations, int)
        or iterations <= 0
        or not isinstance(warmups, int)
        or warmups < 0
        or report.get("iterations") != iterations
        or report.get("warmups") != warmups
    ):
        fail("Mac performance iteration contract mismatch")
    system = identity.get("system")
    if report.get("system") != system or not isinstance(system, dict):
        fail("Mac performance system identity mismatch")
    if system.get("hostRole") != "physical-mac-directional-mechanism-endpoint":
        fail("Mac performance host role mismatch")
    if system.get("physicalIOSDeviceUsed") is not False:
        fail("Mac performance capture must not claim physical iOS execution")

    scenarios = report.get("scenarios")
    contracts = identity.get("scenarioContract")
    if not isinstance(scenarios, dict) or not isinstance(contracts, dict):
        fail("Mac performance scenario records missing")
    if set(scenarios) != set(contracts) or report.get("scenarioCount") != len(contracts):
        fail("Mac performance scenario set mismatch")
    expected_artifacts: set[pathlib.Path] = {binary.resolve()}

    with tempfile.TemporaryDirectory(prefix="w5-apng-public-mac-performance-") as temporary:
        temporary_root = pathlib.Path(temporary)
        for identifier, contract in contracts.items():
            if not isinstance(contract, dict):
                fail(f"invalid Mac performance contract: {identifier}")
            record = scenarios[identifier]
            if record.get("contract") != contract:
                fail(f"scenario contract mismatch: {identifier}")
            input_path = root / "inputs" / f"{identifier}.apng"
            playback_path = root / "playback" / identifier / "report.json"
            timing_path = root / "reports" / f"{identifier}.json"
            for path in (input_path, playback_path, timing_path):
                if not path.is_file():
                    fail(f"missing scenario artifact: {path}")
            identity_matches(record.get("input"), input_path, f"{identifier} input")
            identity_matches(record.get("playbackReport"), playback_path, f"{identifier} playback")
            identity_matches(record.get("timingReport"), timing_path, f"{identifier} timing")
            expected_artifacts.add(input_path.resolve())
            expected_artifacts.add(timing_path.resolve())
            playback_root = playback_path.parent
            for path in playback_root.rglob("*"):
                if path.is_file():
                    expected_artifacts.add(path.resolve())

            playback = json.loads(playback_path.read_text())
            timing = json.loads(timing_path.read_text())
            if (
                playback.get("frameCount") != contract.get("frameCount")
                or playback.get("canvasWidth") != contract.get("canvasWidth")
                or playback.get("canvasHeight") != contract.get("canvasHeight")
                or (
                    contract.get("requireReverseRandomAccessExact") is True
                    and playback.get("allReverseRandomAccessExact") is not True
                )
                or playback.get("cancellationFenced") is not True
                or (playback.get("preparationDiagnostics") or {}).get("backingKind")
                != contract.get("expectedBacking")
            ):
                fail(f"playback mechanism mismatch: {identifier}")
            capture.validate_timing_report(timing, contract, input_path, iterations)
            expected_result = capture.compact_result(timing, playback)
            if record.get("result") != expected_result:
                fail(f"scenario result mismatch: {identifier}")

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
                fail(f"retained playback output mismatch: {identifier}")
            if json.loads((rerun / "report.json").read_text()) != playback:
                fail(f"retained playback report is not reproducible: {identifier}")
            retained_frames = sorted(playback_root.glob("frame-*.rgba"))
            rerun_frames = sorted(rerun.glob("frame-*.rgba"))
            if len(retained_frames) != len(rerun_frames):
                fail(f"retained playback frame count changed: {identifier}")
            for retained, repeated in zip(retained_frames, rerun_frames):
                if retained.read_bytes() != repeated.read_bytes():
                    fail(f"retained playback frame is not reproducible: {identifier}")

    inventory = report.get("artifactInventory")
    if not isinstance(inventory, dict):
        fail("Mac performance artifact inventory missing")
    actual_artifacts = {
        path.resolve()
        for directory_name in ("bin", "inputs", "reports", "playback")
        for path in (root / directory_name).rglob("*")
        if path.is_file()
    }
    if actual_artifacts != expected_artifacts:
        fail("Mac performance artifact set mismatch")
    expected_inventory = {
        str(path.relative_to(root)): support.file_identity(path)
        for path in sorted(expected_artifacts)
    }
    if inventory != expected_inventory:
        fail("Mac performance artifact inventory mismatch")
    allowed_root = {
        report_path.resolve(),
        manifest_path.resolve(),
        identity_path.resolve(),
    }
    unexpected = {path.resolve() for path in root.iterdir() if path.is_file()} - allowed_root
    if unexpected:
        fail("unexpected Mac performance root artifact")
    print(report_path)


if __name__ == "__main__":
    main()
