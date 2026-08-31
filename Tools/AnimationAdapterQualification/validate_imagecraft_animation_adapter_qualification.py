#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
QUALIFICATION = pathlib.Path(__file__).resolve().parent
RUNNER = QUALIFICATION / "qualify_imagecraft_animation_adapter.py"


def load_runner():
    spec = importlib.util.spec_from_file_location("imagecraft_adapter_qualification_runner", RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load qualification runner")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


runner = load_runner()


def fail(message: str) -> None:
    raise SystemExit(message)


def file_identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"byteCount": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_directory", type=pathlib.Path)
    args = parser.parse_args()
    root = args.capture_directory.resolve()
    report_path = root / "report.json"
    format_log = root / "format.log"
    qualification_log = root / "qualification.log"
    for path in (report_path, format_log, qualification_log):
        if not path.is_file():
            fail(f"missing adapter qualification artifact: {path.name}")
    extra = {p.name for p in root.iterdir()} - {"report.json", "format.log", "qualification.log"}
    if extra:
        fail(f"unexpected adapter qualification artifacts: {sorted(extra)}")

    report = json.loads(report_path.read_text())
    if report.get("schemaVersion") != 1 or report.get("studyID") != (
        "FOVEA-W5-IMAGECRAFT-ANIMATION-ADAPTER-OVERLAY-QUALIFICATION-V2"
    ):
        fail("adapter qualification identity mismatch")
    if report.get("formalClaimEligible") is not False:
        fail("adapter overlay qualification must remain non-formal")
    if report.get("sourcesUnchangedDuringRun") is not True:
        fail("adapter qualification source identity changed during run")
    if report.get("sourcesBefore") != report.get("sourcesAfter"):
        fail("adapter qualification source before/after mismatch")
    if report.get("foveaImplementationUnchangedDuringRun") is not True:
        fail("adapter Fovea implementation identity changed during run")
    if report.get("foveaImplementationBefore") != report.get("foveaImplementationAfter"):
        fail("adapter Fovea implementation before/after mismatch")

    overlay = report.get("overlay") or {}
    if overlay != {
        "productionImageCraftPinChanged": False,
        "productionPackageModified": False,
        "usesCopiedAkashicSource": True,
        "usesCopiedFoveaSource": True,
        "usesCopiedImageCraftSource": True,
    }:
        fail("adapter qualification overlay boundary changed")

    if (report.get("format") or {}).get("returnCode") != 0:
        fail("adapter fixture strict format did not pass")
    if (report.get("qualification") or {}).get("returnCode") != 0:
        fail("adapter executable qualification did not pass")
    if (report.get("qualification") or {}).get("command") != [
        "xcrun", "swift", "run", "-Xswiftc", "-warnings-as-errors",
        "ImageCraftAnimationAdapterQualification",
    ]:
        fail("adapter qualification command changed")
    if (report["format"].get("sha256") != file_identity(format_log)["sha256"]):
        fail("adapter format log digest mismatch")
    if report["qualification"].get("sha256") != file_identity(qualification_log)["sha256"]:
        fail("adapter qualification log digest mismatch")
    qualification_text = qualification_log.read_text()
    for test_id in (
        "W5_ADAPTER_PT_001",
        "W5_ADAPTER_PT_002",
        "W5_ADAPTER_PT_003",
        "W5_ADAPTER_PT_004",
        "W5_ADAPTER_PT_005",
        "W5_ADAPTER_PT_006",
        "W5_ADAPTER_PT_007",
        "W5_ADAPTER_PT_008",
    ):
        if f"{test_id} passed" not in qualification_text:
            fail(f"adapter qualification success marker missing: {test_id}")

    expected_fixtures = {
        "adapter": QUALIFICATION / "ImageCraftAnimationPlaybackPreparer.swift.fixture",
        "test": QUALIFICATION / "ImageCraftAnimationPlaybackQualificationMain.swift.fixture",
    }
    fixture_identity = report.get("fixtureIdentity") or {}
    if set(fixture_identity) != set(expected_fixtures):
        fail("adapter qualification fixture set changed")
    for name, path in expected_fixtures.items():
        if fixture_identity[name] != file_identity(path):
            fail(f"adapter fixture identity mismatch: {name}")

    expected_governing = {
        "runner": QUALIFICATION / "qualify_imagecraft_animation_adapter.py",
        "validator": QUALIFICATION / "validate_imagecraft_animation_adapter_qualification.py",
        "tamperContract": QUALIFICATION / "test_imagecraft_animation_adapter_qualification.py",
        "formatterConfig": ROOT / ".swift-format",
    }
    governing = report.get("governingFiles") or {}
    if set(governing) != set(expected_governing):
        fail("adapter governing file set changed")
    for name, path in expected_governing.items():
        if governing[name] != file_identity(path):
            fail(f"adapter governing file identity mismatch: {name}")

    captured_sources = report.get("sourcesBefore") or {}
    current_external_sources = {
        "ImageCraft": runner.snapshot(ROOT.parent / "ImageCraft"),
        "Akashic": runner.snapshot(ROOT.parent / "Akashic"),
    }
    for name, current in current_external_sources.items():
        if current != captured_sources.get(name):
            fail(f"adapter qualification no longer binds current {name} source")
    current_fovea_head = runner.run(["git", "rev-parse", "HEAD"], ROOT).stdout.strip()
    if current_fovea_head != (captured_sources.get("Fovea") or {}).get("headCommit"):
        fail("adapter qualification Fovea HEAD changed")
    if runner.fovea_implementation_identity() != report.get("foveaImplementationBefore"):
        fail("adapter qualification Fovea implementation files changed")
    print(report_path)


if __name__ == "__main__":
    main()
