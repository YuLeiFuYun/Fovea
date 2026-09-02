#!/usr/bin/env python3
"""验证负结果注册表，防止选择性报告和被遗忘的反例。"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs/research/negative-results.json"
ARTIFACT = ROOT / ".artifacts/mathematics/negative-results-verification.json"
ROOT_RESOLVED = ROOT.resolve()


def main() -> int:
    document = json.loads(REGISTRY.read_text())
    errors: list[str] = []
    if document.get("schemaVersion") != 1 or document.get("registryID") != "FOVEA-NEGATIVE-RESULTS-V1":
        errors.append("unexpected negative-results registry identity")
    entries = document.get("entries")
    if not isinstance(entries, list) or len(entries) < 4:
        errors.append("negative-results registry must retain at least four entries")
        entries = []
    identifiers: set[str] = set()
    required = {"id", "area", "claimRejected", "counterexample", "evidencePaths", "decision", "exitCondition"}
    for entry in entries:
        if not isinstance(entry, dict):
            errors.append("negative-result entry must be an object")
            continue
        missing = required - entry.keys()
        if missing:
            errors.append(f"{entry.get('id', 'unknown')}: missing fields {sorted(missing)}")
            continue
        identifier = entry["id"]
        if not isinstance(identifier, str) or not identifier.startswith("NEG-"):
            errors.append(f"invalid negative-result id: {identifier}")
        if identifier in identifiers:
            errors.append(f"duplicate negative-result id: {identifier}")
        identifiers.add(identifier)
        for field in ("area", "claimRejected", "counterexample", "decision", "exitCondition"):
            if not isinstance(entry[field], str) or len(entry[field].strip()) < 12:
                errors.append(f"{identifier}: {field} is empty or too short")
        evidence = entry["evidencePaths"]
        if not isinstance(evidence, list) or not evidence:
            errors.append(f"{identifier}: evidencePaths must be nonempty")
            continue
        for relative in evidence:
            if not isinstance(relative, str):
                errors.append(f"{identifier}: evidence path must be a string")
                continue
            if relative.startswith(".artifacts/"):
                errors.append(
                    f"{identifier}: evidence path must be tracked and fresh-clone available: {relative}"
                )
                continue
            candidate = (ROOT / relative).resolve()
            try:
                candidate.relative_to(ROOT_RESOLVED)
            except ValueError:
                errors.append(
                    f"{identifier}: evidence path must stay inside the Fovea repository: {relative}"
                )
                continue
            if not candidate.exists():
                errors.append(f"{identifier}: missing evidence path {relative}")
    digest = hashlib.sha256(
        json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps({
        "schemaVersion": 1,
        "registryID": document.get("registryID"),
        "entryCount": len(entries),
        "registrySHA256": digest,
        "status": "failed" if errors else "passed",
        "errors": errors,
    }, indent=2, sort_keys=True) + "\n")
    print(f"Negative results registry: entries={len(entries)} errors={len(errors)} sha256:{digest}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
