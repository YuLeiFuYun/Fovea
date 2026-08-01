#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / "docs/research/dependency-allowlist.json"
PACKAGE = ROOT / "Package.swift"
WORKFLOWS = ROOT / ".github/workflows"


def fail(messages: list[str]) -> int:
    print("Supply-chain check failed:", file=sys.stderr)
    for message in messages:
        print(f"- {message}", file=sys.stderr)
    return 1


def main() -> int:
    errors: list[str] = []
    try:
        data = json.loads(ALLOWLIST.read_text())
    except (OSError, json.JSONDecodeError) as error:
        return fail([f"invalid dependency allowlist: {error}"])
    if data.get("schemaVersion") != 2:
        errors.append("dependency allowlist schemaVersion must be 2")
    allowed_packages = data.get("swiftPackages")
    allowed_actions = data.get("githubActions")
    if not isinstance(allowed_packages, list) or not all(isinstance(v, dict) for v in allowed_packages):
        errors.append("swiftPackages must be an object array")
        allowed_packages = []
    if not isinstance(allowed_actions, list) or not all(isinstance(v, str) for v in allowed_actions):
        errors.append("githubActions must be a string array")
        allowed_actions = []

    package_text = PACKAGE.read_text()
    discovered_packages = sorted(set(re.findall(r"\.package\s*\(\s*url:\s*\"([^\"]+)\"", package_text)))
    allowed_package_urls = sorted(
        entry.get("repositoryURL") for entry in allowed_packages if isinstance(entry.get("repositoryURL"), str)
    )
    if discovered_packages != sorted(set(allowed_package_urls)):
        errors.append(
            f"remote Swift packages differ from allowlist: discovered={discovered_packages} allowed={sorted(set(allowed_package_urls))}"
        )

    try:
        component_pins = json.loads((ROOT / "docs/project-memory/component-pins.json").read_text())
        resolved = json.loads((ROOT / "Package.resolved").read_text())
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"component pin inputs are unavailable: {error}")
        component_pins = {"components": {}}
        resolved = {"pins": []}
    pinned_components = component_pins.get("components", {})
    resolved_by_identity = {
        pin.get("identity"): pin for pin in resolved.get("pins", []) if isinstance(pin, dict)
    }
    seen_names: set[str] = set()
    seen_identities: set[str] = set()
    for entry in allowed_packages:
        name = entry.get("name")
        identity = entry.get("identity")
        url = entry.get("repositoryURL")
        revision = entry.get("revision")
        products = entry.get("products")
        if not isinstance(name, str) or name in seen_names:
            errors.append(f"invalid or duplicate Swift package name: {name!r}")
            continue
        seen_names.add(name)
        if not isinstance(identity, str) or identity in seen_identities:
            errors.append(f"invalid or duplicate Swift package identity: {identity!r}")
            continue
        seen_identities.add(identity)
        if not isinstance(url, str) or not url.startswith("https://github.com/") or not url.endswith(".git"):
            errors.append(f"Swift package {name} must use a public HTTPS GitHub URL")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            errors.append(f"Swift package {name} must use a full lowercase exact revision")
        if not isinstance(products, list) or not products or not all(isinstance(v, str) for v in products):
            errors.append(f"Swift package {name} products must be a non-empty string array")
        if entry.get("license") != "MIT":
            errors.append(f"Swift package {name} license declaration must be MIT")
        if not isinstance(entry.get("purpose"), str) or not entry["purpose"].strip():
            errors.append(f"Swift package {name} purpose is missing")
        component = pinned_components.get(name, {})
        if component.get("repositoryURL") != url or component.get("revision") != revision:
            errors.append(f"Swift package {name} differs from component-pins.json")
        if component.get("requiredProducts") != products:
            errors.append(f"Swift package {name} product set differs from component-pins.json")
        pin = resolved_by_identity.get(identity, {})
        state = pin.get("state", {}) if isinstance(pin, dict) else {}
        if pin.get("location") != url or state.get("revision") != revision:
            errors.append(f"Swift package {name} differs from Package.resolved")
        if package_text.count(f'url: "{url}"') != 1 or package_text.count(f'revision: "{revision}"') != 1:
            errors.append(f"Swift package {name} exact URL/revision is not unique in Package.swift")
        for product in products if isinstance(products, list) else []:
            if f'.product(name: "{product}", package: "{name}")' not in package_text:
                errors.append(f"Swift package {name} product is not consumed: {product}")

    discovered_actions: list[str] = []
    if WORKFLOWS.is_dir():
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for line_number, line in enumerate(path.read_text().splitlines(), start=1):
                match = re.match(r"\s*-?\s*uses:\s*([^\s#]+)", line)
                if not match:
                    continue
                action = match.group(1).strip("'\"")
                discovered_actions.append(action)
                if action.startswith("./") or action.startswith("docker://"):
                    continue
                if re.fullmatch(r"[^@\s]+@[0-9a-fA-F]{40}", action) is None:
                    errors.append(
                        f"GitHub Action is not pinned to a full commit SHA: {path.relative_to(ROOT)}:{line_number}"
                    )
    external_actions = sorted(
        set(action for action in discovered_actions if not action.startswith("./") and not action.startswith("docker://"))
    )
    if external_actions != sorted(set(allowed_actions)):
        errors.append(
            f"external GitHub Actions differ from allowlist: discovered={external_actions} allowed={sorted(set(allowed_actions))}"
        )
    for action in allowed_actions:
        if re.fullmatch(r"[^@\s]+@[0-9a-fA-F]{40}", action) is None:
            errors.append(f"allowlisted GitHub Action is not pinned to a full commit SHA: {action}")

    license_path = ROOT / "LICENSE"
    assets_path = ROOT / "THIRD_PARTY_ASSETS.md"
    contributing_path = ROOT / "CONTRIBUTING.md"
    if not license_path.is_file():
        errors.append("root LICENSE is missing")
    else:
        license_text = license_path.read_text()
        required_mit_fragments = (
            "MIT License",
            "Permission is hereby granted, free of charge",
            'THE SOFTWARE IS PROVIDED "AS IS"',
        )
        if not all(fragment in license_text for fragment in required_mit_fragments):
            errors.append("root LICENSE is not the expected MIT License text")
    if not assets_path.is_file() or "not relicensed under MIT" not in assets_path.read_text():
        errors.append("third-party asset licensing boundary is missing or invalid")
    if not contributing_path.is_file() or "MIT License" not in contributing_path.read_text():
        errors.append("CONTRIBUTING.md is missing or does not state MIT contribution licensing")

    pin = ROOT / "Examples/FoveaWorkbenchApp/.xcodegen-version"
    if not pin.is_file() or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\n?", pin.read_text()) is None:
        errors.append("FoveaWorkbench XcodeGen version pin is missing or invalid")

    if errors:
        return fail(errors)
    print(
        "Supply-chain check passed: "
        f"{len(discovered_packages)} remote Swift packages, {len(external_actions)} external Actions"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
