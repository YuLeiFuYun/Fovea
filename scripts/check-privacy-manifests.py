#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
WORKBENCH_SOURCES = ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbench"
WORKBENCH_MANIFEST = WORKBENCH_SOURCES / "Resources/PrivacyInfo.xcprivacy"
WORKBENCH_PROJECT_SPEC = ROOT / "Examples/FoveaWorkbenchApp/project.yml"

FILE_TIMESTAMP_CATEGORY = "NSPrivacyAccessedAPICategoryFileTimestamp"
USER_DEFAULTS_CATEGORY = "NSPrivacyAccessedAPICategoryUserDefaults"
APP_CONTAINER_FILE_REASON = "C617.1"
APP_ONLY_DEFAULTS_REASON = "CA92.1"

CATEGORY_PATTERNS: dict[str, tuple[re.Pattern[str], ...]] = {
    FILE_TIMESTAMP_CATEGORY: (
        re.compile(r"\b(?:Darwin\.)?(?:stat|fstat|lstat)\s*\("),
        re.compile(r"\battributesOfItem\s*\("),
        re.compile(r"\bcontentModificationDate(?:Key)?\b"),
        re.compile(r"\bcreationDate(?:Key)?\b"),
        re.compile(r"\bfileSize(?:Key)?\b"),
    ),
    USER_DEFAULTS_CATEGORY: (
        re.compile(r"\bUserDefaults\b"),
    ),
}

APPROVED_REASONS = {
    FILE_TIMESTAMP_CATEGORY: [APP_CONTAINER_FILE_REASON],
    USER_DEFAULTS_CATEGORY: [APP_ONLY_DEFAULTS_REASON],
}


def required_categories(root: Path) -> set[str]:
    categories: set[str] = set()
    for path in root.rglob("*.swift"):
        text = path.read_text(errors="replace")
        for category, patterns in CATEGORY_PATTERNS.items():
            if any(pattern.search(text) for pattern in patterns):
                categories.add(category)
    return categories


def package_target_requirements() -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for directory in SOURCES.iterdir():
        if directory.is_dir():
            categories = required_categories(directory)
            if categories:
                result[directory.name] = categories
    return result


def package_resources() -> dict[str, set[str]]:
    env = os.environ.copy()
    selected = subprocess.run(
        [str(ROOT / "scripts/select-xcode.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if selected.returncode != 0:
        raise RuntimeError(selected.stderr.strip() or selected.stdout.strip() or "Xcode selection failed")
    env["DEVELOPER_DIR"] = selected.stdout.strip()
    completed = subprocess.run(
        ["xcrun", "swift", "package", "dump-package"],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "swift package dump-package failed")
    package = json.loads(completed.stdout)
    result: dict[str, set[str]] = {}
    for target in package.get("targets", []):
        result[target["name"]] = {
            resource.get("path", "") for resource in target.get("resources", [])
        }
    return result


def validate_manifest(
    label: str,
    path: Path,
    required: set[str],
    errors: list[str],
) -> None:
    if not path.is_file():
        errors.append(f"{label}: missing PrivacyInfo.xcprivacy")
        return
    try:
        manifest = plistlib.loads(path.read_bytes())
    except Exception as error:  # noqa: BLE001
        errors.append(f"{label}: invalid privacy manifest: {error}")
        return

    if manifest.get("NSPrivacyTracking") is not False:
        errors.append(f"{label}: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        errors.append(f"{label}: local-only code expects an empty collected-data array")
    if "NSPrivacyTrackingDomains" in manifest:
        errors.append(f"{label}: tracking domains are forbidden")

    declarations = manifest.get("NSPrivacyAccessedAPITypes")
    if not isinstance(declarations, list):
        errors.append(f"{label}: NSPrivacyAccessedAPITypes must be an array")
        return

    observed: dict[str, list[str]] = {}
    for declaration in declarations:
        if not isinstance(declaration, dict):
            errors.append(f"{label}: accessed API declaration must be a dictionary")
            continue
        category = declaration.get("NSPrivacyAccessedAPIType")
        reasons = declaration.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(category, str) or not isinstance(reasons, list):
            errors.append(f"{label}: accessed API declaration is incomplete")
            continue
        if category in observed:
            errors.append(f"{label}: duplicate declaration for {category}")
        observed[category] = reasons

    if set(observed) != required:
        errors.append(
            f"{label}: manifest categories {sorted(observed)} do not match source use "
            f"{sorted(required)}"
        )
    for category in sorted(required):
        expected = APPROVED_REASONS.get(category)
        if expected is None:
            errors.append(f"{label}: no reviewed reason mapping for {category}")
        elif observed.get(category) != expected:
            errors.append(
                f"{label}: {category} reasons must be exactly {expected!r}, "
                f"observed={observed.get(category)!r}"
            )


def validate_workbench(errors: list[str]) -> set[str]:
    required = required_categories(WORKBENCH_SOURCES)
    validate_manifest("FoveaWorkbench", WORKBENCH_MANIFEST, required, errors)
    project = WORKBENCH_PROJECT_SPEC.read_text(errors="replace")
    if "FoveaWorkbench/Resources" not in project or "buildPhase: resources" not in project:
        errors.append("FoveaWorkbench: project.yml does not bundle the Resources directory")
    return required


def main() -> int:
    errors: list[str] = []
    try:
        resources = package_resources()
    except (RuntimeError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1

    package_requirements = package_target_requirements()
    for target, required in sorted(package_requirements.items()):
        validate_manifest(
            target,
            SOURCES / target / "PrivacyInfo.xcprivacy",
            required,
            errors,
        )
        if "PrivacyInfo.xcprivacy" not in resources.get(target, set()):
            errors.append(f"{target}: Package.swift does not process PrivacyInfo.xcprivacy")

    workbench_required = validate_workbench(errors)
    if errors:
        for error in errors:
            print(f"privacy-manifest: {error}", file=sys.stderr)
        return 1

    package_summary = ", ".join(
        f"{target}={'+'.join(sorted(categories))}"
        for target, categories in sorted(package_requirements.items())
    )
    print(
        "Privacy manifest gate passed: "
        f"packages[{package_summary}] "
        f"workbench[{'+'.join(sorted(workbench_required))}]"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
