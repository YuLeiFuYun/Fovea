#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Tests/FoveaTests/Conformance/WPT/manifest.json"
OUTPUT_DIR = ROOT / ".artifacts/conformance"
LOG_PATH = OUTPUT_DIR / "http-conformance.log"
REPORT_PATH = OUTPUT_DIR / "http-conformance.json"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
CASE_ID = re.compile(r"^HTTP-CONF-WPT-[A-Z0-9-]+$")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_inside(base: Path, relative: str) -> Path:
    path = (base / relative).resolve()
    path.relative_to(base.resolve())
    return path


def validate_manifest(data: dict[str, Any]) -> list[dict[str, Any]]:
    if data.get("schemaVersion") != 1:
        raise ValueError("manifest schemaVersion must be 1")
    upstream = data.get("upstream")
    if not isinstance(upstream, dict):
        raise ValueError("upstream metadata is required")
    if upstream.get("repository") != "https://github.com/web-platform-tests/wpt":
        raise ValueError("manifest must reference the canonical WPT repository")
    if not COMMIT.fullmatch(str(upstream.get("commit", ""))):
        raise ValueError("upstream commit must be a full lowercase Git SHA")
    if upstream.get("license") != "BSD-3-Clause":
        raise ValueError("WPT license must be recorded as BSD-3-Clause")

    source_root = MANIFEST.parent
    sources = data.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ValueError("source provenance list is required")
    seen_sources: set[str] = set()
    for source in sources:
        if not isinstance(source, dict):
            raise ValueError("source entries must be objects")
        relative = source.get("path")
        expected = source.get("sha256")
        if not isinstance(relative, str) or relative in seen_sources:
            raise ValueError(f"invalid or duplicate source path: {relative}")
        seen_sources.add(relative)
        path = resolve_inside(source_root, relative)
        if not path.is_file():
            raise ValueError(f"missing upstream source snapshot: {relative}")
        if sha256(path) != expected:
            raise ValueError(f"upstream source digest mismatch: {relative}")
    license_file = upstream.get("licenseFile")
    if license_file not in seen_sources:
        raise ValueError("license file must be included in the source provenance list")

    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError("conformance cases are required")
    identifiers: set[str] = set()
    required: list[dict[str, Any]] = []
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("case entries must be objects")
        identifier = case.get("id")
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier):
            raise ValueError(f"invalid case id: {identifier}")
        if identifier in identifiers:
            raise ValueError(f"duplicate case id: {identifier}")
        identifiers.add(identifier)
        upstream_file = case.get("upstreamFile")
        if upstream_file not in seen_sources:
            raise ValueError(f"case references unpinned source: {identifier}")
        applicability = case.get("applicability")
        if applicability == "required":
            test_filter = case.get("localTestFilter")
            if not isinstance(test_filter, str) or "/test" not in test_filter:
                raise ValueError(f"required case lacks executable localTestFilter: {identifier}")
            if not case.get("rfc9111Section") or not case.get("adaptationNotes"):
                raise ValueError(f"required case lacks RFC/adaptation metadata: {identifier}")
            required.append(case)
        elif applicability == "notApplicable":
            if not case.get("rationale"):
                raise ValueError(f"notApplicable case lacks rationale: {identifier}")
        else:
            raise ValueError(f"unknown applicability for {identifier}: {applicability}")
    if len(required) < 30:
        raise ValueError("required WPT adaptation set is unexpectedly small")
    return required


def test_method(test_filter: str) -> str:
    return test_filter.rsplit("/", 1)[1]


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        manifest = json.loads(MANIFEST.read_text())
        required = validate_manifest(manifest)
        env = os.environ.copy()
        if not env.get("DEVELOPER_DIR"):
            env["DEVELOPER_DIR"] = subprocess.run(
                [str(ROOT / "scripts/select-xcode.sh")],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            ).stdout.strip()
        completed = subprocess.run(
            ["xcrun", "swift", "test", "--filter", "HTTPConformanceTests"],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        LOG_PATH.write_text(completed.stdout)
        methods = sorted({test_method(case["localTestFilter"]) for case in required})
        method_status: dict[str, str] = {}
        for method in methods:
            started = re.search(rf"Test Case '.*{re.escape(method)}.*' started\.", completed.stdout)
            passed = re.search(rf"Test Case '.*{re.escape(method)}.*' passed", completed.stdout)
            method_status[method] = "pass" if started and passed else "fail"
        cases = [
            {
                "id": case["id"],
                "status": method_status[test_method(case["localTestFilter"])],
                "localTestFilter": case["localTestFilter"],
                "upstreamFile": case["upstreamFile"],
                "upstreamName": case["upstreamName"],
            }
            for case in required
        ]
        verified_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        all_passed = completed.returncode == 0 and all(
            case["status"] == "pass" for case in cases
        )
        report = {
            "schemaVersion": 1,
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "profile": manifest["profile"],
            "verifiedCommit": verified_commit,
            "upstreamCommit": manifest["upstream"]["commit"],
            "manifest": str(MANIFEST.relative_to(ROOT)),
            "manifestSha256": sha256(MANIFEST),
            "log": str(LOG_PATH.relative_to(ROOT)),
            "logSha256": sha256(LOG_PATH),
            "requiredCaseCount": len(cases),
            "notApplicableCaseCount": sum(
                case.get("applicability") == "notApplicable" for case in manifest["cases"]
            ),
            "status": "pass" if all_passed else "fail",
            "cases": cases,
        }
        REPORT_PATH.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        if not all_passed:
            raise ValueError("one or more executable WPT adaptations failed")
        print(
            f"HTTP conformance gate passed: {len(cases)} required cases, "
            f"upstream {manifest['upstream']['commit'][:12]}"
        )
        print(
            f"HTTP conformance report: {REPORT_PATH.relative_to(ROOT)} "
            f"sha256:{sha256(REPORT_PATH)}"
        )
        return 0
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"HTTP conformance gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
