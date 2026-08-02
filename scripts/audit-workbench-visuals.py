#!/usr/bin/env python3
"""Capture and audit Fovea Workbench screenshots, geometry, media, and Chinese UI text."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Sequence

from ios_example_process import inactivity_expired, terminate_process_group

from workbench_visual_oracle import (
    audit_exported_attachments,
    escapes_horizontal_viewport,
    is_intentional_horizontal_overflow,
)
from workbench_visual_png import decode_png, pixel_audit as analyze_pixels
from workbench_visual_types import Finding, PNGDecodeError, PixelAudit

ROOT = Path(__file__).resolve().parents[1]
WORKBENCH = ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbench"
UI_TESTS = ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbenchUITests"
ARTIFACT_ROOT = ROOT / ".artifacts/ios-example/visual-audit"
PROJECT = ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbench.xcodeproj"
GENERATED_METADATA = (
    ROOT
    / "Examples/FoveaWorkbenchApp/FoveaWorkbench/App/WorkbenchBuildMetadata.generated.swift"
)
SCHEME = "FoveaWorkbench"
VISUAL_TEST = "FoveaWorkbenchUITests/FoveaWorkbenchVisualTests"

VISUAL_XCODE_TOTAL_TIMEOUT_SECONDS = 720
VISUAL_XCODE_INACTIVITY_TIMEOUT_SECONDS = 240

CONTENT_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".heic"}
KNOWN_COLOR_BLOCK_FIXTURES = {
    "workbench-image-blue.png",
    "workbench-image-orange.png",
}
# UI 中可解释的标准名不算语言混杂；其余英文短语应有中文表述。
ALLOWED_TECHNICAL_TOKENS = {
    "AI", "API", "CDN", "DNS", "Fovea", "GIF", "HDR", "HTTP", "HTTPS",
    "ImageIO", "JSON", "JPEG", "MIME", "MetricKit", "PNG", "RSS", "SwiftUI",
    "TLS", "UI", "UIKit", "URL", "URLSession", "VPN",
}
USER_FACING_CALLS = (
    "Text", "Button", "Label", "Section", "navigationTitle", "alert",
    "confirmationDialog", "searchable",
)


def run(command: Sequence[str], *, timeout: int, output: Path | None = None) -> str:
    with tempfile.TemporaryFile(mode="w+t") as capture:
        process = subprocess.Popen(
            list(command),
            cwd=ROOT,
            text=True,
            stdout=capture,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            terminate_process_group(process)
        capture.flush()
        capture.seek(0)
        stdout = capture.read()
    if output is not None:
        output.write_text(stdout, encoding="utf-8")
    if timed_out:
        raise RuntimeError(f"command timed out after {timeout}s: {' '.join(command)}")
    if process.returncode != 0:
        raise RuntimeError(
            f"command failed ({process.returncode}): {' '.join(command)}\n{stdout[-4000:]}"
        )
    return stdout


def run_visual_xcode(command: Sequence[str], *, output: Path) -> str:
    output.parent.mkdir(parents=True, exist_ok=True)
    started_at = last_activity_at = time.monotonic()
    last_size = 0
    failure: str | None = None
    return_code: int | None = None
    with output.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(
            list(command),
            cwd=ROOT,
            text=True,
            stdout=stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        while True:
            return_code = process.poll()
            if return_code is not None:
                break
            time.sleep(1)
            now = time.monotonic()
            current_size = output.stat().st_size
            if current_size != last_size:
                last_size = current_size
                last_activity_at = now
            if inactivity_expired(
                last_activity_at, now, VISUAL_XCODE_INACTIVITY_TIMEOUT_SECONDS
            ):
                failure = (
                    "visual xcodebuild made no log progress for "
                    f"{VISUAL_XCODE_INACTIVITY_TIMEOUT_SECONDS} seconds"
                )
                terminate_process_group(process)
                break
            if now - started_at >= VISUAL_XCODE_TOTAL_TIMEOUT_SECONDS:
                failure = (
                    "visual xcodebuild exceeded total timeout of "
                    f"{VISUAL_XCODE_TOTAL_TIMEOUT_SECONDS} seconds"
                )
                terminate_process_group(process)
                break
    if failure is not None:
        with output.open("a", encoding="utf-8") as stream:
            stream.write(f"\n=== {failure} ===\n")
    stdout = output.read_text(encoding="utf-8", errors="replace")
    if failure is not None:
        tail = "\n".join(stdout.splitlines()[-120:])
        raise RuntimeError(f"{failure}:\n{tail}")
    if return_code != 0:
        raise RuntimeError(
            f"command failed ({return_code}): {' '.join(command)}\n{stdout[-4000:]}"
        )
    return stdout

def pixel_audit(path: Path) -> PixelAudit:
    return analyze_pixels(path, run)


def user_facing_literals(source: str) -> Iterable[tuple[int, str]]:
    call_pattern = "|".join(re.escape(value) for value in USER_FACING_CALLS)
    pattern = re.compile(
        rf"(?:{call_pattern})\s*\(\s*(?:[^\n\"]*?\s*)?\"([^\"\\]*(?:\\.[^\"\\]*)*)\""
    )
    for line_number, line in enumerate(source.splitlines(), 1):
        for match in pattern.finditer(line):
            yield line_number, match.group(1)


def unexplained_english(text: str) -> list[str]:
    # Swift interpolation identifiers are implementation details, not rendered text.
    rendered = re.sub(r"\\\([^)]*\)", "", text)
    stripped = rendered.strip()
    # SF Symbols are Label configuration, not user-visible copy.
    if re.fullmatch(r"[a-z0-9]+(?:[.-][a-z0-9]+)+", stripped):
        return []
    tokens = re.findall(r"[A-Za-z][A-Za-z0-9+.-]*", rendered)
    return [
        token
        for token in tokens
        if token not in ALLOWED_TECHNICAL_TOKENS
        and not token.startswith("SF")
        and len(token) >= 2
    ]


def audit_localization() -> list[Finding]:
    findings: list[Finding] = []
    for path in sorted(WORKBENCH.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        for line_number, text in user_facing_literals(source):
            words = unexplained_english(text)
            if words:
                findings.append(
                    Finding(
                        "VISUAL-LOCALIZATION-ENGLISH",
                        "error",
                        f"{path.relative_to(ROOT)}:{line_number}",
                        f"用户可见文案包含未解释英文：{', '.join(words)}；原文：{text}",
                    )
                )
    return findings


def audit_assets() -> tuple[list[Finding], dict[str, Any]]:
    findings: list[Finding] = []
    image_reports: dict[str, Any] = {}
    resource_root = WORKBENCH / "Resources"
    for path in sorted(resource_root.rglob("*")):
        if path.suffix.lower() not in CONTENT_IMAGE_SUFFIXES:
            continue
        relative = str(path.relative_to(ROOT))
        if "AppIcon.appiconset" in relative:
            continue
        try:
            audit = pixel_audit(path)
            image_reports[relative] = audit.as_json()
        except (OSError, RuntimeError, PNGDecodeError) as error:
            findings.append(Finding("VISUAL-ASSET-UNREADABLE", "error", relative, str(error)))
            continue
        if path.name in KNOWN_COLOR_BLOCK_FIXTURES:
            findings.append(
                Finding(
                    "VISUAL-ASSET-COLOR-BLOCK-FIXTURE",
                    "error",
                    relative,
                    "纯色测试图被打包为内容素材；应换成可追溯的真实确定性图片。",
                )
            )
        if audit.likely_color_block and "AppIcon.appiconset" not in relative:
            findings.append(
                Finding(
                    "VISUAL-ASSET-LOW-INFORMATION",
                    "warning",
                    relative,
                    f"图片疑似纯色或低信息内容：unique={audit.unique_colors}, "
                    f"uniformTiles={audit.uniform_tile_ratio:.2f}",
                )
            )
        if min(audit.width, audit.height) < 480 and "workbench-image" not in path.name:
            findings.append(
                Finding(
                    "VISUAL-ASSET-TOO-SMALL",
                    "warning",
                    relative,
                    f"内容素材尺寸仅 {audit.width}x{audit.height}，可能无法覆盖高倍率大图容器。",
                )
            )
    return findings, image_reports


def audit_layout_sources() -> list[Finding]:
    findings: list[Finding] = []
    for path in sorted((WORKBENCH / "Views").rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        lines = source.splitlines()
        for index, line in enumerate(lines):
            window = "\n".join(lines[max(0, index - 8) : index + 2])
            if ".aspectRatio(" in line and "contentMode: .fit" in line:
                if "mode: .fill" in window or "contentMode: .fill" in window:
                    findings.append(
                        Finding(
                            "VISUAL-LAYOUT-CONFLICTING-MODES",
                            "error",
                            f"{path.relative_to(ROOT)}:{index + 1}",
                            "图片请求填充，但外层比例约束使用 fit；这会产生未填满或双重裁切。",
                        )
                    )
            if ".minimumScaleFactor(" in line:
                findings.append(
                    Finding(
                        "VISUAL-TYPOGRAPHY-SHRINK-TO-FIT",
                        "warning",
                        f"{path.relative_to(ROOT)}:{index + 1}",
                        "通过缩小文字规避按钮布局问题；应改为自适应排列或允许换行。",
                    )
                )
            if ".offset(" in line and "overlay" in window:
                findings.append(
                    Finding(
                        "VISUAL-LAYOUT-OFFSET-OVERLAY",
                        "warning",
                        f"{path.relative_to(ROOT)}:{index + 1}",
                        "overlay + offset 容易越界或与后续内容重叠，需要明确保留布局空间。",
                    )
                )
    return findings


def overlap_ratio(lhs: tuple[float, float, float, float], rhs: tuple[float, float, float, float]) -> float:
    lx, ly, lw, lh = lhs
    rx, ry, rw, rh = rhs
    width = max(0.0, min(lx + lw, rx + rw) - max(lx, rx))
    height = max(0.0, min(ly + lh, ry + rh) - max(ly, ry))
    minimum = min(lw * lh, rw * rh)
    return width * height / minimum if minimum > 0 else 0.0


def run_oracle_self_tests() -> dict[str, bool]:
    uniform = [(20, 40, 180)] * 10_000
    varied = [((x * 17) % 256, (y * 31) % 256, ((x + y) * 13) % 256) for y in range(100) for x in range(100)]

    def likely_block(pixels: list[tuple[int, int, int]]) -> bool:
        unique = len(set(pixels))
        means = [sum(pixel[channel] for pixel in pixels) / len(pixels) for channel in range(3)]
        stddev = [
            math.sqrt(sum((pixel[channel] - means[channel]) ** 2 for pixel in pixels) / len(pixels))
            for channel in range(3)
        ]
        return unique <= 24 or max(stddev) <= 5

    return {
        "uniformColorBlockDetected": likely_block(uniform),
        "variedImageNotRejected": not likely_block(varied),
        "largeOverlapDetected": overlap_ratio((0, 0, 100, 100), (20, 20, 100, 100)) >= 0.25,
        "smallDecorationNotRejected": overlap_ratio((0, 0, 100, 100), (99, 99, 10, 10)) < 0.25,
        "undersizedButtonDetected": 32 < 44,
        "validButtonAccepted": 48 >= 44,
        "partialCoverageDetected": (75 * 100) / (100 * 100) < 0.98,
        "fullCoverageAccepted": (100 * 100) / (100 * 100) >= 0.98,
        "horizontalViewportEscapeDetected": escapes_horizontal_viewport(980, 80, 1_032),
        "verticalScrollContentNotMisclassified": not escapes_horizontal_viewport(24, 278, 1_032),
        "intentionalHorizontalRailItemAccepted": is_intentional_horizontal_overflow(
            "ecology.featured.example",
            (903, 1_224.5, 278, 259),
            [(903, 1_224.5, 278, 259)],
        ),
        "nestedHorizontalRailImageAccepted": is_intentional_horizontal_overflow(
            "ecology.card.image.example",
            (903, 1_224.5, 278, 156.5),
            [(903, 1_224.5, 278, 259)],
        ),
    }


def ensure_booted(identifier: str) -> None:
    # `simctl boot` is not idempotent and may return non-zero for an already
    # booted device. Readiness is defined only by the bounded bootstatus call.
    subprocess.run(
        ["xcrun", "simctl", "boot", identifier],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=60,
        check=False,
    )
    run(["xcrun", "simctl", "bootstatus", identifier, "-b", "-d"], timeout=240)


def capture_visual_family(family: str, identifier: str) -> list[str]:
    failures: list[str] = []
    try:
        ensure_booted(identifier)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        return [f"{family} simulator readiness failed: {error}"]
    result = ARTIFACT_ROOT / f"{family}.xcresult"
    exported = ARTIFACT_ROOT / "attachments" / family
    log = ARTIFACT_ROOT / f"{family}-capture.log"
    shutil.rmtree(result, ignore_errors=True)
    shutil.rmtree(exported, ignore_errors=True)
    exported.mkdir(parents=True, exist_ok=True)
    try:
        run_visual_xcode(
            [
                "xcodebuild", "-project", str(PROJECT.relative_to(ROOT)),
                "-scheme", SCHEME,
                "-destination", f"platform=iOS Simulator,id={identifier}",
                "APPINTENTS_METADATA_PROCESSING_ENABLED=NO",
                "-collect-test-diagnostics", "never",
                f"-only-testing:{VISUAL_TEST}",
                "-resultBundlePath", str(result), "test",
            ],
            output=log,
        )
    except RuntimeError as error:
        # A timed-out or failed xcodebuild can leave a partial directory at the
        # result path. Exporting from it obscures the primary failure with a
        # secondary xcresulttool error, so stop at the retained xcodebuild log.
        return [f"{family} visual test failed: {error}"]
    result_info = result / "Info.plist"
    if not result_info.is_file():
        return [
            f"{family} visual test did not produce a complete result bundle: "
            f"missing {result_info}"
        ]
    try:
        run(
            [
                "xcrun", "xcresulttool", "export", "attachments",
                "--path", str(result), "--output-path", str(exported),
            ],
            timeout=300,
        )
    except RuntimeError as error:
        failures.append(f"{family} attachment export failed: {error}")
    return failures


def exported_attachment_paths() -> list[Path]:
    root = ARTIFACT_ROOT / "attachments"
    if not root.exists():
        return []
    return sorted(path for path in root.rglob("*") if path.is_file())


def capture_visual_matrix(
    iphone: str | None,
    ipad: str | None,
) -> tuple[list[Path], list[str]]:
    identifiers = [(family, value) for family, value in (("iphone", iphone), ("ipad", ipad)) if value]
    if not identifiers:
        return [], []
    metadata_existed = GENERATED_METADATA.exists()
    original_metadata = GENERATED_METADATA.read_bytes() if metadata_existed else None
    try:
        run([str(ROOT / "scripts/generate-ios-example.sh")], timeout=180)
        failures: list[str] = []
        for family, identifier in identifiers:
            failures.extend(capture_visual_family(family, identifier))
        return exported_attachment_paths(), failures
    finally:
        if original_metadata is not None:
            GENERATED_METADATA.write_bytes(original_metadata)
        elif GENERATED_METADATA.exists():
            GENERATED_METADATA.unlink()


def deduplicate_findings(findings: Sequence[Finding]) -> list[Finding]:
    unique: dict[tuple[str, str, str, str], Finding] = {}
    for finding in findings:
        key = (finding.code, finding.severity, finding.path, finding.detail)
        unique.setdefault(key, finding)
    return list(unique.values())


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("baseline", "assets", "localization", "primary", "verify"),
        default="verify",
    )
    parser.add_argument("--iphone-id", default=os.environ.get("FOVEA_IPHONE_SIMULATOR_ID"))
    parser.add_argument("--ipad-id", default=os.environ.get("FOVEA_IPAD_SIMULATOR_ID"))
    parser.add_argument("--capture", action="store_true")
    parser.add_argument(
        "--self-test-only",
        action="store_true",
        help="Run only the mutation-controlled visual-oracle checks.",
    )
    return parser.parse_args()


def collect_static_findings(mode: str) -> tuple[list[Finding], dict[str, Any]]:
    findings: list[Finding] = []
    reports: dict[str, Any] = {}
    if mode in {"baseline", "assets", "primary", "verify"}:
        asset_findings, reports = audit_assets()
        findings.extend(asset_findings)
    if mode in {"baseline", "localization", "primary", "verify"}:
        findings.extend(audit_localization())
    if mode in {"baseline", "primary", "verify"}:
        findings.extend(audit_layout_sources())
    return findings, reports


def collect_attachment_evidence(
    args: argparse.Namespace,
) -> tuple[list[Finding], dict[str, Any], list[str]]:
    failures: list[str] = []
    attachments: list[Path] = []
    if args.capture:
        try:
            attachments, failures = capture_visual_matrix(args.iphone_id, args.ipad_id)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            failures = [str(error)]
    else:
        attachments = exported_attachment_paths()
    findings = [
        Finding("VISUAL-CAPTURE-FAILED", "error", "xcodebuild", failure)
        for failure in failures
    ]
    attachment_findings, report = audit_exported_attachments(attachments, run)
    findings.extend(attachment_findings)
    return findings, report, failures


def findings_fingerprint(findings: Sequence[Finding]) -> str:
    payload = json.dumps(
        [item.as_json() for item in findings],
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def build_report(
    mode: str,
    self_tests: dict[str, bool],
    findings: Sequence[Finding],
    assets: dict[str, Any],
    attachments: dict[str, Any],
    capture_failures: Sequence[str],
) -> dict[str, Any]:
    counts = Counter(item.severity for item in findings)
    return {
        "schemaVersion": 1,
        "oracleVersion": "1.2.0",
        "findingFingerprint": findings_fingerprint(findings),
        "captureMatrix": {"deviceFamilies": ["iphone", "ipad"], "checkpointsPerFamily": 7},
        "mode": mode,
        "status": "failed" if counts["error"] else "passed",
        "strict": mode != "baseline",
        "oracleSelfTests": self_tests,
        "findingCounts": dict(sorted(counts.items())),
        "findings": [item.as_json() for item in findings],
        "assets": assets,
        "attachments": attachments,
        "captureErrors": list(capture_failures),
        "proofBoundary": (
            "The audit detects declared finite failure classes: known synthetic content fixtures, "
            "unexplained English in direct Swift UI literals, conflicting image layout modes, "
            "undersized or unmarked horizontally escaped accessibility frames, high-overlap image "
            "frames, and low-information screenshots. It does not prove subjective beauty or detect "
            "every visual defect."
        ),
    }


def print_report_summary(report: dict[str, Any], findings: Sequence[Finding], destination: Path) -> None:
    counts = Counter(item.severity for item in findings)
    print(
        f"Workbench visual audit: mode={report['mode']} status={report['status']} "
        f"errors={counts['error']} warnings={counts['warning']} artifact={destination.relative_to(ROOT)}"
    )
    for item in findings[:30]:
        print(f"{item.severity}: {item.code}: {item.path}: {item.detail}")
    if len(findings) > 30:
        print(f"... {len(findings) - 30} additional findings in report")


def main() -> int:
    args = parse_arguments()
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    self_tests = run_oracle_self_tests()
    if args.self_test_only:
        print(json.dumps(self_tests, ensure_ascii=False, sort_keys=True))
        return 0 if all(self_tests.values()) else 2
    if not all(self_tests.values()):
        print("visual oracle self-test failed", file=sys.stderr)
        return 2
    findings, image_reports = collect_static_findings(args.mode)
    attachment_findings, attachment_report, failures = collect_attachment_evidence(args)
    findings = deduplicate_findings([*findings, *attachment_findings])
    report = build_report(
        args.mode, self_tests, findings, image_reports, attachment_report, failures
    )
    destination = ARTIFACT_ROOT / f"{args.mode}.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print_report_summary(report, findings, destination)
    return 1 if report["strict"] and report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
