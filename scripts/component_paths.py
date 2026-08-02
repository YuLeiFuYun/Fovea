"""Resolve exact-pinned component evidence references without sibling repositories."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / "docs/project-memory/component-pins.json"
PREFIX = "component://"


class ComponentPathError(ValueError):
    pass


def _components() -> dict[str, dict[str, object]]:
    document = json.loads(PINS.read_text())
    components = document.get("components")
    if not isinstance(components, dict):
        raise ComponentPathError("component pin registry has no components object")
    return components


def is_component_reference(reference: str) -> bool:
    return reference.startswith(PREFIX)


def resolve_reference(reference: str) -> Path:
    if not isinstance(reference, str) or not reference:
        raise ComponentPathError(f"invalid evidence reference: {reference!r}")
    if not is_component_reference(reference):
        path = (ROOT / reference).resolve()
        try:
            path.relative_to(ROOT.resolve())
        except ValueError as error:
            raise ComponentPathError(f"repository path escapes root: {reference}") from error
        return path

    parsed = urlparse(reference)
    name = parsed.netloc
    relative = parsed.path.lstrip("/")
    components = _components()
    component = components.get(name)
    if not isinstance(component, dict):
        raise ComponentPathError(f"unknown component in evidence reference: {name}")
    revision = component.get("revision")
    if not isinstance(revision, str) or len(revision) != 40:
        raise ComponentPathError(f"component {name} has no exact revision")
    checkout = (ROOT / ".build/checkouts" / name).resolve()
    if not (checkout / ".git").exists():
        raise ComponentPathError(
            f"component checkout missing for {name}; run xcrun swift package resolve"
        )
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=checkout,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    observed = completed.stdout.strip()
    if completed.returncode != 0 or observed != revision:
        raise ComponentPathError(
            f"component checkout revision mismatch for {name}: expected={revision} observed={observed}"
        )
    path = (checkout / relative).resolve()
    try:
        path.relative_to(checkout)
    except ValueError as error:
        raise ComponentPathError(f"component path escapes checkout: {reference}") from error
    return path
