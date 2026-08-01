#!/usr/bin/env python3
"""Verify Fovea's public exact-revision component dependency boundary."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "docs/project-memory/component-pins.json"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
RELEASE_TAG = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+$")
EXPECTED = {
    "ImageCraft": {
        "identity": "imagecraft",
        "products": ["ImageCraftCore", "ImageCraftImageIO"],
        "embedded": ["Sources/ImageCraftCore", "Sources/ImageCraftImageIO"],
    },
    "Akashic": {
        "identity": "akashic",
        "products": ["AkashicCore", "AkashicMemory", "AkashicDisk"],
        "embedded": ["Sources/AkashicCore", "Sources/AkashicMemory", "Sources/AkashicDisk"],
    },
}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def main() -> int:
    errors: list[str] = []
    try:
        lock = load_json(LOCK)
        resolved = load_json(ROOT / "Package.resolved")
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"component pin input unavailable: {error}", file=sys.stderr)
        return 1

    if lock.get("schemaVersion") != 1:
        errors.append("unexpected component pin schema")
    if lock.get("lockID") != "FOVEA-EXTERNAL-COMPONENT-PINS-V1":
        errors.append("unexpected component pin identity")
    if lock.get("mode") != "public-exact-revision-no-embedded-mirrors":
        errors.append("unexpected component integration mode")

    policy = lock.get("policy", {})
    for key in (
        "embeddedComponentSourcesForbidden",
        "exactRevisionRequired",
        "packageResolvedMustMatch",
        "foveaOwnsHTTPAuthorityIdentityRevokeAndCommit",
        "componentsRemainIndependentlyVerifiable",
    ):
        if policy.get(key) is not True:
            errors.append(f"component pin policy must remain true: {key}")

    package_source = (ROOT / "Package.swift").read_text()
    components = lock.get("components")
    if not isinstance(components, dict) or set(components) != set(EXPECTED):
        errors.append("component set must be exactly ImageCraft and Akashic")
        components = {}

    resolved_pins = {
        pin.get("identity"): pin
        for pin in resolved.get("pins", [])
        if isinstance(pin, dict)
    }
    if set(resolved_pins) != {value["identity"] for value in EXPECTED.values()}:
        errors.append(f"Package.resolved component set drifted: {sorted(resolved_pins)}")

    for name, expected in EXPECTED.items():
        component = components.get(name, {})
        url = component.get("repositoryURL")
        revision = component.get("revision")
        release_tag = component.get("releaseTag")
        products = component.get("requiredProducts")
        if not isinstance(url, str) or url != f"https://github.com/YuLeiFuYun/{name}.git":
            errors.append(f"{name} repository URL drifted")
            continue
        if not isinstance(revision, str) or SHA40.fullmatch(revision) is None:
            errors.append(f"{name} revision must be a full lowercase SHA-1")
            continue
        if not isinstance(release_tag, str) or RELEASE_TAG.fullmatch(release_tag) is None:
            errors.append(f"{name} releaseTag must be a prerelease semantic version")
        if products != expected["products"]:
            errors.append(f"{name} required products drifted")
        if package_source.count(f'url: "{url}"') != 1:
            errors.append(f"Package.swift does not contain exactly one {name} URL")
        if package_source.count(f'revision: "{revision}"') != 1:
            errors.append(f"Package.swift does not contain exactly one {name} revision")
        for product in expected["products"]:
            if f'.product(name: "{product}", package: "{name}")' not in package_source:
                errors.append(f"Package.swift does not consume {name} product {product}")
        for relative in expected["embedded"]:
            if (ROOT / relative).exists():
                errors.append(f"embedded component source returned: {relative}")
        pin = resolved_pins.get(expected["identity"], {})
        state = pin.get("state", {}) if isinstance(pin, dict) else {}
        if pin.get("location") != url or state.get("revision") != revision:
            errors.append(f"Package.resolved does not match {name} exact pin")

    integration = lock.get("hostIntegration", {})
    for relative in (
        integration.get("akashicAdapter"),
        integration.get("akashicDomainContractModule"),
    ):
        if not isinstance(relative, str) or not (ROOT / relative).exists():
            errors.append(f"host integration path is missing: {relative}")
    expected_obligations = [f"AKASHIC-CT-{index:03d}" for index in range(22, 27)]
    if integration.get("implementedAkashicObligations") != expected_obligations:
        errors.append("Akashic host obligations drifted")

    if errors:
        print("External component pin violation:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    summary = ", ".join(
        f"{name}@{components[name]['revision'][:12]}" for name in sorted(EXPECTED)
    )
    print(f"External component pins passed: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
