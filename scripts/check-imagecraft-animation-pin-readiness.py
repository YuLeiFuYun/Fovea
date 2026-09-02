#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
STUDY = ROOT / "docs/research/w5-imagecraft-animation-adapter-qualification-2026-08.json"
PINS = ROOT / "docs/project-memory/component-pins.json"
PACKAGE = ROOT / "Package.swift"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
PACKAGE_PATTERN = re.compile(
    r'url:\s*"https://github\.com/YuLeiFuYun/ImageCraft\.git"\s*,\s*revision:\s*"([0-9a-f]{40})"',
    re.MULTILINE,
)


def package_revision(source: str) -> str | None:
    matches = PACKAGE_PATTERN.findall(source)
    return matches[0] if len(matches) == 1 else None


def validate_state(package_pin: str | None, component_pin: str | None, study: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    readiness = study.get("productionPinReadiness")
    identity = study.get("sourceIdentity")
    discovery = study.get("pinUpgradeDiscovery")
    if not isinstance(readiness, dict) or not isinstance(identity, dict) or not isinstance(discovery, dict):
        return ["qualification pin-readiness/source records are missing"]

    current = readiness.get("currentProductionRevision")
    candidate = readiness.get("qualifiedCandidateHeadCommit")
    tree = readiness.get("qualifiedCandidateWorkingTree")
    published = readiness.get("publishedImmutableCandidateRevision")
    authorized = readiness.get("pinUpgradeAuthorized")

    for label, value in (("currentProductionRevision", current), ("qualifiedCandidateHeadCommit", candidate)):
        if not isinstance(value, str) or SHA40.fullmatch(value) is None:
            errors.append(f"{label} must be a full lowercase Git SHA")
    if not isinstance(tree, str) or not tree:
        errors.append("qualifiedCandidateWorkingTree must be non-empty")
    if package_pin is None or component_pin is None:
        errors.append("exact ImageCraft package/component revision is missing")
    elif package_pin != component_pin:
        errors.append("Package.swift and component-pins ImageCraft revisions differ")
    if discovery.get("productionPinStill") != current:
        errors.append("pinUpgradeDiscovery production revision differs from readiness")
    if identity.get("imageCraftHeadCommit") != candidate or identity.get("imageCraftWorkingTree") != tree:
        errors.append("qualified candidate differs from adapter qualification source identity")
    if identity.get("sourcesUnchangedDuringRun") is not True:
        errors.append("adapter qualification must bind unchanged sources")

    if authorized is False:
        if readiness.get("status") != "blocked-unpublished-working-tree-candidate":
            errors.append("unauthorized candidate must remain blocked")
        if readiness.get("qualifiedCandidateIncludesWorkingTreeChanges") is not True:
            errors.append("blocked candidate must record working-tree changes")
        if readiness.get("qualificationSourceIsClean") is not False:
            errors.append("blocked candidate must record qualificationSourceIsClean=false")
        if published is not None:
            errors.append("blocked candidate must not declare a published revision")
        if package_pin != current or component_pin != current:
            errors.append("production ImageCraft pin changed before publication authorization")
    elif authorized is True:
        if readiness.get("status") != "ready-published-clean-qualified":
            errors.append("authorized pin must use ready-published-clean-qualified status")
        if not isinstance(published, str) or SHA40.fullmatch(published) is None:
            errors.append("authorized pin requires a published immutable revision")
        elif package_pin != published or component_pin != published or candidate != published:
            errors.append("authorized pin and qualification must equal the published revision")
        if readiness.get("qualifiedCandidateIncludesWorkingTreeChanges") is not False:
            errors.append("authorized qualification must have no working-tree changes")
        if readiness.get("qualificationSourceIsClean") is not True:
            errors.append("authorized qualification must record qualificationSourceIsClean=true")
    else:
        errors.append("pinUpgradeAuthorized must be boolean")
    return errors


def main() -> int:
    try:
        study = json.loads(STUDY.read_text())
        pins = json.loads(PINS.read_text())
        package_pin = package_revision(PACKAGE.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f"ImageCraft animation pin readiness input unavailable: {error}", file=sys.stderr)
        return 1
    component_pin = ((pins.get("components") or {}).get("ImageCraft") or {}).get("revision")
    errors = validate_state(package_pin, component_pin, study)
    if errors:
        print("ImageCraft animation pin readiness violation:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    r = study["productionPinReadiness"]
    print(f"ImageCraft animation pin readiness: status={r['status']} authorized={r['pinUpgradeAuthorized']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
