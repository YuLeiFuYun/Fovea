#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SUITE = ROOT / "Benchmarks/ComparativeLab/challenge-suite.json"
COMPARATOR_LOCK = ROOT / "docs/research/comparator-lock.json"
RESEARCH_LOCK = ROOT / "docs/research/network-image-loader-test-sources.json"
CACHE_LOCK = ROOT / "docs/research/cache-comparator-lock.json"
ARTIFACT = ROOT / ".artifacts/comparators/challenge-suite-verification.json"

SOURCE_ROOTS = {
    "Fovea": ROOT,
    "Nuke": ROOT / ".artifacts/comparators/sources/Nuke",
    "Kingfisher": ROOT / ".artifacts/comparators/sources/Kingfisher",
    "SDWebImage": ROOT / ".artifacts/comparators/sources/SDWebImage",
    "AlamofireImage": ROOT / ".artifacts/comparators/sources/AlamofireImage",
    "Glide": ROOT / ".artifacts/comparators/research-sources/Glide",
    "Coil": ROOT / ".artifacts/comparators/research-sources/Coil",
    "Picasso": ROOT / ".artifacts/comparators/research-sources/Picasso",
    "Fresco": ROOT / ".artifacts/comparators/research-sources/Fresco",
    "LRUCache": ROOT / ".artifacts/cache-comparators/sources/LRUCache",
    "PINCache": ROOT / ".artifacts/cache-comparators/sources/PINCache",
}


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(ROOT)} must contain an object")
    return value


def git_head(path: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"missing exact checkout: {path.relative_to(ROOT)}")
    return result.stdout.strip()


def verify_checkout(name: str, expected: str) -> None:
    path = SOURCE_ROOTS[name]
    if name == "Fovea":
        return
    if git_head(path) != expected:
        fail(f"{name} checkout differs from its locked source commit")
    dirty = subprocess.run(
        ["git", "-C", str(path), "status", "--porcelain"],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
    if dirty:
        fail(f"{name} source checkout is dirty")


def main() -> int:
    suite = load(SUITE)
    if suite.get("schemaVersion") != 1 or suite.get("suiteID") != "FOVEA-CROSS-LIBRARY-CHALLENGE-V1":
        fail("unexpected challenge-suite identity")
    claim = suite.get("claimPolicy")
    if not isinstance(claim, dict):
        fail("challenge suite lacks claim policy")
    required_claim_keys = {"correctness", "performance", "unsupported", "upstreamTests"}
    if set(claim) != required_claim_keys:
        fail("challenge-suite claim policy is incomplete")
    if "statistically tied for first" not in str(claim["performance"]):
        fail("performance claim policy must require first or statistically tied first")
    if "not replaced" not in str(claim["upstreamTests"]):
        fail("semantic ports must not replace original upstream tests")

    locks: dict[str, str] = {}
    for item in load(COMPARATOR_LOCK).get("comparators", []):
        locks[item["name"]] = item["exactCommit"]
    for item in load(RESEARCH_LOCK).get("sources", []):
        locks[item["name"]] = item["exactCommit"]
    for item in load(CACHE_LOCK).get("comparators", []):
        locks[item["name"]] = item["exactCommit"]
    if set(SOURCE_ROOTS) - {"Fovea"} - set(locks):
        fail("one or more challenge source projects are not commit locked")
    for name, exact_commit in locks.items():
        if name in SOURCE_ROOTS:
            verify_checkout(name, exact_commit)

    challenges = suite.get("challenges")
    if not isinstance(challenges, list) or len(challenges) < 20:
        fail("challenge suite is unexpectedly small")
    identifiers: list[str] = []
    allowed_statuses = {"implemented-and-required", "capability-gap", "platform-not-applicable"}
    source_projects: set[str] = set()
    implemented = 0
    gaps = 0
    for challenge in challenges:
        if not isinstance(challenge, dict):
            fail("challenge entry must be an object")
        identifier = challenge.get("id")
        if not isinstance(identifier, str) or not identifier.startswith("CH-"):
            fail("invalid challenge identifier")
        identifiers.append(identifier)
        status = challenge.get("status")
        if status not in allowed_statuses:
            fail(f"{identifier} has unsupported status {status}")
        evidence = challenge.get("foveaEvidence")
        if not isinstance(evidence, list):
            fail(f"{identifier} foveaEvidence must be a list")
        if status == "implemented-and-required":
            implemented += 1
            if not evidence:
                fail(f"{identifier} is implemented but has no Fovea evidence")
        elif status == "capability-gap":
            gaps += 1
            if evidence:
                fail(f"{identifier} is a capability gap but claims Fovea evidence")
        for relative in evidence:
            path = ROOT / relative
            if not path.exists():
                fail(f"{identifier} references missing Fovea evidence: {relative}")
        sources = challenge.get("sources")
        if not isinstance(sources, list) or not sources:
            fail(f"{identifier} has no upstream sources")
        seen_sources: set[tuple[str, str]] = set()
        for source in sources:
            if not isinstance(source, dict):
                fail(f"{identifier} contains invalid source metadata")
            project = source.get("project")
            relative = source.get("path")
            if project not in SOURCE_ROOTS or not isinstance(relative, str) or not relative:
                fail(f"{identifier} contains an unknown source")
            key = (project, relative)
            if key in seen_sources:
                fail(f"{identifier} repeats source {project}:{relative}")
            seen_sources.add(key)
            source_projects.add(project)
            if not (SOURCE_ROOTS[project] / relative).is_file():
                fail(f"{identifier} source path is missing: {project}:{relative}")
    if len(set(identifiers)) != len(identifiers):
        fail("challenge identifiers must be unique")
    required_source_projects = {
        "Nuke", "Kingfisher", "SDWebImage", "AlamofireImage",
        "Glide", "Coil", "Picasso", "Fresco", "LRUCache", "PINCache",
    }
    if not required_source_projects.issubset(source_projects):
        missing = sorted(required_source_projects - source_projects)
        fail(f"challenge suite omits required source projects: {missing}")

    digest = hashlib.sha256(
        json.dumps(suite, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "suiteID": suite["suiteID"],
                "suiteSHA256": digest,
                "challengeCount": len(challenges),
                "implementedRequiredCount": implemented,
                "capabilityGapCount": gaps,
                "sourceProjects": sorted(source_projects),
                "status": "passed",
            },
            indent=2,
            sort_keys=True,
        ) + "\n"
    )
    print(
        "Comparative challenge suite valid: "
        f"challenges={len(challenges)} implemented={implemented} gaps={gaps} sha256:{digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
