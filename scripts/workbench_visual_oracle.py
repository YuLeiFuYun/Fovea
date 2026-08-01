"""Accessibility geometry and exported-attachment oracle helpers."""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Callable, Sequence

from workbench_visual_png import pixel_audit
from workbench_visual_types import Finding, PNGDecodeError

CommandRunner = Callable[..., str]
Frame = tuple[float, float, float, float]
APPLICATION_IDENTIFIER_PREFIXES = (
    "auth.", "cache.", "catalog.", "concurrency.", "diagnostics.",
    "discover.", "ecology.", "evidence.", "expectation.", "experiments.",
    "failure.", "feed.", "lab.", "performance.", "product.", "run.",
    "settings.", "studio.", "tab.",
)
NON_ACTION_IDENTIFIER_PREFIXES = ("tab.", "ecology.metric.")
CONTENT_IMAGE_MARKERS = (
    ".avatar.", ".attachment.", ".cover", ".featured-image", ".hero",
    ".image", ".preview.", ".story-image.", ".thumbnail", ".work.",
)
INTENTIONAL_HORIZONTAL_ITEM_PREFIXES = ("ecology.featured.",)


def is_application_identifier(identifier: str) -> bool:
    return identifier.startswith(APPLICATION_IDENTIFIER_PREFIXES)


def is_action_identifier(identifier: str) -> bool:
    return is_application_identifier(identifier) and not identifier.startswith(
        NON_ACTION_IDENTIFIER_PREFIXES
    )


def is_content_image_identifier(identifier: str) -> bool:
    return is_application_identifier(identifier) and any(
        marker in identifier for marker in CONTENT_IMAGE_MARKERS
    )


def escapes_horizontal_viewport(
    x: float, width: float, screen_width: float, *, tolerance: float = 0.5
) -> bool:
    if not all(math.isfinite(value) for value in (x, width, screen_width)):
        return True
    if width < 0 or screen_width <= 0:
        return True
    return x < -tolerance or x + width > screen_width + tolerance


def element_frame(element: dict[str, Any]) -> Frame:
    return (
        float(element.get("x") or 0),
        float(element.get("y") or 0),
        float(element.get("width") or 0),
        float(element.get("height") or 0),
    )


def frame_is_within(child: Frame, parent: Frame, *, tolerance: float = 0.5) -> bool:
    cx, cy, cw, ch = child
    px, py, pw, ph = parent
    if not all(math.isfinite(value) for value in child + parent):
        return False
    if min(cw, ch, pw, ph) < 0:
        return False
    return (
        cx >= px - tolerance
        and cy >= py - tolerance
        and cx + cw <= px + pw + tolerance
        and cy + ch <= py + ph + tolerance
    )


def is_intentional_horizontal_overflow(
    identifier: str, frame: Frame, intentional_frames: Sequence[Frame]
) -> bool:
    if identifier.startswith(INTENTIONAL_HORIZONTAL_ITEM_PREFIXES):
        return True
    return any(frame_is_within(frame, parent) for parent in intentional_frames)


def semantic_attachment_names(paths: Sequence[Path]) -> tuple[dict[Path, str], list[Finding]]:
    names: dict[Path, str] = {}
    findings: list[Finding] = []
    for manifest in (path for path in paths if path.name == "manifest.json"):
        try:
            groups = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeError) as error:
            findings.append(Finding("VISUAL-MANIFEST-INVALID", "error", str(manifest), str(error)))
            continue
        for group in groups:
            for attachment in group.get("attachments", []):
                exported = attachment.get("exportedFileName")
                suggested = attachment.get("suggestedHumanReadableName")
                if exported and suggested:
                    names[manifest.parent / exported] = str(suggested)
    return names, findings


def audit_screenshot(path: Path, semantic_name: str, run: CommandRunner) -> tuple[list[Finding], dict[str, Any] | None]:
    try:
        audit = pixel_audit(path, run)
    except (OSError, RuntimeError, PNGDecodeError) as error:
        return [Finding("VISUAL-SCREENSHOT-UNREADABLE", "error", semantic_name, str(error))], None
    findings: list[Finding] = []
    if audit.likely_color_block:
        findings.append(Finding(
            "VISUAL-SCREENSHOT-LARGE-COLOR-BLOCK", "error", semantic_name,
            "整页截图呈现异常低信息或大面积纯色，可能是内容未加载或占位未消失。",
        ))
    return findings, audit.as_json()


def read_geometry(path: Path, semantic_name: str) -> tuple[dict[str, Any] | None, list[Finding]]:
    try:
        return json.loads(path.read_text(encoding="utf-8")), []
    except (OSError, json.JSONDecodeError, UnicodeError) as error:
        return None, [Finding("VISUAL-GEOMETRY-INVALID", "error", semantic_name, str(error))]


def intentional_horizontal_frames(elements: Sequence[dict[str, Any]]) -> list[Frame]:
    return [
        element_frame(element)
        for element in elements
        if str(element.get("identifier") or "").startswith(
            INTENTIONAL_HORIZONTAL_ITEM_PREFIXES
        )
    ]


def audit_geometry_element(
    element: dict[str, Any], semantic_name: str, screen_width: float, intentional: Sequence[Frame]
) -> list[Finding]:
    identifier = str(element.get("identifier") or "")
    if not is_application_identifier(identifier):
        return []
    frame = element_frame(element)
    x, _, width, height = frame
    findings: list[Finding] = []
    if element.get("kind") == "button" and is_action_identifier(identifier) and (width < 44 or height < 44):
        findings.append(Finding("VISUAL-BUTTON-UNDERSIZED", "error", semantic_name, identifier))
    if escapes_horizontal_viewport(x, width, screen_width) and not is_intentional_horizontal_overflow(
        identifier, frame, intentional
    ):
        findings.append(Finding(
            "VISUAL-ELEMENT-HORIZONTAL-OFFSCREEN", "warning", semantic_name, identifier
        ))
    return findings


def audit_geometry_elements(payload: dict[str, Any], semantic_name: str) -> list[Finding]:
    elements = payload.get("elements", [])
    intentional = intentional_horizontal_frames(elements)
    screen_width = float(payload.get("screenWidth") or 0)
    findings: list[Finding] = []
    for element in elements:
        findings.extend(audit_geometry_element(element, semantic_name, screen_width, intentional))
    return findings


def audit_geometry_overlaps(payload: dict[str, Any], semantic_name: str) -> list[Finding]:
    findings: list[Finding] = []
    for overlap in payload.get("suspiciousOverlaps", []):
        lhs = str(overlap.get("lhs") or "")
        rhs = str(overlap.get("rhs") or "")
        if is_content_image_identifier(lhs) and is_content_image_identifier(rhs):
            findings.append(Finding(
                "VISUAL-IMAGE-OVERLAP", "error", semantic_name,
                json.dumps(overlap, ensure_ascii=False, sort_keys=True),
            ))
    return findings


def missing_artifact_findings(
    has_paths: bool, screenshot_count: int, geometry_count: int, tree_count: int
) -> list[Finding]:
    if not has_paths:
        return []
    findings: list[Finding] = []
    if geometry_count == 0:
        findings.append(Finding("VISUAL-MISSING-GEOMETRY", "error", "attachments", "未导出几何 JSON"))
    if tree_count == 0:
        findings.append(Finding("VISUAL-MISSING-ACCESSIBILITY-TREE", "error", "attachments", "未导出辅助功能树"))
    if screenshot_count == 0:
        findings.append(Finding("VISUAL-MISSING-SCREENSHOT", "error", "attachments", "未导出屏幕截图"))
    return findings


def audit_exported_attachments(
    paths: Sequence[Path], run: CommandRunner
) -> tuple[list[Finding], dict[str, Any]]:
    semantic_names, findings = semantic_attachment_names(paths)
    screenshots: dict[str, Any] = {}
    geometry_count = tree_count = 0
    for path in paths:
        name = semantic_names.get(path, path.name)
        if path.suffix.lower() == ".png":
            image_findings, report = audit_screenshot(path, name, run)
            findings.extend(image_findings)
            if report is not None:
                screenshots[name] = report
        elif "几何-" in name and path.suffix.lower() == ".json":
            geometry_count += 1
            payload, geometry_findings = read_geometry(path, name)
            findings.extend(geometry_findings)
            if payload is not None:
                findings.extend(audit_geometry_elements(payload, name))
                findings.extend(audit_geometry_overlaps(payload, name))
        elif "辅助功能树-" in name:
            tree_count += 1
    findings.extend(missing_artifact_findings(bool(paths), len(screenshots), geometry_count, tree_count))
    report = {
        "attachmentCount": len(paths),
        "geometryCount": geometry_count,
        "accessibilityTreeCount": tree_count,
        "screenshotCount": len(screenshots),
        "screenshots": screenshots,
    }
    return findings, report
