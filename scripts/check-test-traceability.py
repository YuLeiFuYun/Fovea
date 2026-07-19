#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/test-traceability.json"
WPT_MANIFEST = ROOT / "Tests/FoveaTests/Conformance/WPT/manifest.json"
REPORT = ROOT / ".artifacts/traceability/test-traceability.json"
ID = re.compile(r"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+$")
METHOD = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve(relative: str) -> Path:
    path = (ROOT / relative).resolve()
    path.relative_to(ROOT.resolve())
    return path


def methods(path: Path) -> set[str]:
    return set(METHOD.findall(path.read_text()))


def validate_evidence(requirement: str, evidence: dict[str, Any], wpt_ids: set[str]) -> None:
    kind = evidence.get("kind")
    relative = evidence.get("file")
    if not isinstance(relative, str):
        raise ValueError(f"{requirement}: evidence file is required")
    path = resolve(relative)
    if not path.is_file():
        raise ValueError(f"{requirement}: evidence file does not exist: {relative}")
    if kind == "swiftTest":
        method = evidence.get("method")
        if not isinstance(method, str) or method not in methods(path):
            raise ValueError(f"{requirement}: XCTest method not found: {method}")
    elif kind == "httpConformance":
        method = evidence.get("method")
        case = evidence.get("manifestCase")
        if case != requirement or case not in wpt_ids:
            raise ValueError(f"{requirement}: WPT manifest case mismatch")
        if not isinstance(method, str) or method not in methods(path):
            raise ValueError(f"{requirement}: conformance test method not found: {method}")
    elif kind == "script":
        if path.suffix not in {".py", ".sh"}:
            raise ValueError(f"{requirement}: script evidence must be executable source")
        if requirement.startswith("AIQA-MUT-") and requirement not in path.read_text():
            raise ValueError(f"{requirement}: mutation runner does not define this mutant")
    else:
        raise ValueError(f"{requirement}: unsupported evidence kind: {kind}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Fovea requirement-to-test traceability.")
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    try:
        data = json.loads(MANIFEST.read_text())
        if data.get("schemaVersion") != 1 or data.get("assuranceStage") != "0b":
            raise ValueError("traceability manifest schema/stage mismatch")
        requirements = data.get("requirements")
        if not isinstance(requirements, list) or not requirements:
            raise ValueError("requirements must be a non-empty array")
        wpt = json.loads(WPT_MANIFEST.read_text())
        wpt_ids = {
            case["id"] for case in wpt["cases"] if case.get("applicability") == "required"
        }
        seen: set[str] = set()
        missing: list[str] = []
        implemented = 0
        for entry in requirements:
            if not isinstance(entry, dict):
                raise ValueError("requirement entries must be objects")
            identifier = entry.get("id")
            if not isinstance(identifier, str) or not ID.fullmatch(identifier):
                raise ValueError(f"invalid requirement id: {identifier}")
            if identifier in seen:
                raise ValueError(f"duplicate requirement id: {identifier}")
            seen.add(identifier)
            status = entry.get("status")
            evidence = entry.get("evidence")
            if status == "implemented":
                if not isinstance(evidence, list) or not evidence:
                    raise ValueError(f"{identifier}: implemented requirement lacks evidence")
                for item in evidence:
                    if not isinstance(item, dict):
                        raise ValueError(f"{identifier}: evidence entries must be objects")
                    validate_evidence(identifier, item, wpt_ids)
                implemented += 1
            elif status == "missing":
                if evidence != []:
                    raise ValueError(f"{identifier}: missing requirement must not claim evidence")
                missing.append(identifier)
            else:
                raise ValueError(f"{identifier}: invalid status {status}")
        if not wpt_ids.issubset(seen):
            raise ValueError("traceability manifest omits required WPT cases")
        report = {
            "schemaVersion": 1,
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "verifiedCommit": __import__("subprocess").run(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
                stdout=__import__("subprocess").PIPE, check=True
            ).stdout.strip(),
            "manifest": str(MANIFEST.relative_to(ROOT)),
            "manifestSha256": sha256(MANIFEST),
            "required": len(requirements),
            "implemented": implemented,
            "missing": len(missing),
            "missingIDs": missing,
            "status": "complete" if not missing else "incomplete",
        }
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            f"Traceability valid: {implemented}/{len(requirements)} implemented, "
            f"{len(missing)} missing"
        )
        print(f"Traceability report: {REPORT.relative_to(ROOT)} sha256:{sha256(REPORT)}")
        if args.require_complete and missing:
            print("0b completeness gate failed; missing requirements:", file=sys.stderr)
            for identifier in missing:
                print(f"  {identifier}", file=sys.stderr)
            return 1
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Traceability validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
