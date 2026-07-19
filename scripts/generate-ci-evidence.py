#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

COMMIT = re.compile(r"^[0-9a-fA-F]{7,64}$")


def git_output(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "git command failed")
    return completed.stdout.strip()


def resolve_commit(root: Path, value: str) -> str:
    if value != "HEAD" and not COMMIT.fullmatch(value):
        raise ValueError(f"invalid commit: {value}")
    resolved = git_output(root, "rev-parse", f"{value}^{{commit}}")
    if not COMMIT.fullmatch(resolved):
        raise ValueError(f"could not resolve commit: {value}")
    return resolved


def digest(path: Path) -> str:
    return f"sha256:{hashlib.sha256(path.read_bytes()).hexdigest()}"


def changed_files(root: Path, base: str, head: str) -> list[str]:
    output = git_output(root, "diff", "--name-only", f"{base}..{head}")
    return [line for line in output.splitlines() if line]


def logical_lines(root: Path, base: str, head: str) -> int:
    output = git_output(root, "diff", "--numstat", f"{base}..{head}")
    total = 0
    for line in output.splitlines():
        added, removed, *_ = line.split("\t")
        if added.isdigit():
            total += int(added)
        if removed.isdigit():
            total += int(removed)
    return total


def trusted_context() -> tuple[bool, str]:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return False, ""
    required = ["GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_SHA"]
    if any(not os.environ.get(name) for name in required):
        raise ValueError("trusted CI mode requires complete GitHub Actions identity")
    locator = (
        f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
        f"/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    )
    return True, locator


def verification_result(
    identifier: str,
    kind: str,
    path: Path,
    producer: str,
    status: str,
    locator: str,
    verified_commit: str,
) -> dict[str, Any]:
    return {
        "id": identifier,
        "kind": kind,
        "status": status,
        "evidenceLocator": locator,
        "producer": producer,
        "evidenceDigest": digest(path),
        "verifiedCommit": verified_commit,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a Fovea CI Evidence Bundle.")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--verify-log", default=".artifacts/logs/verify.log")
    parser.add_argument(
        "--assurance-stage",
        choices=("0a-bootstrap", "0a-complete", "0b", "release"),
        default="0b",
    )
    parser.add_argument("--output", default=".artifacts/evidence/fovea-ci-evidence.json")
    parser.add_argument("--trusted-ci", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    try:
        base = resolve_commit(root, args.base)
        head = resolve_commit(root, args.head)
        current = git_output(root, "rev-parse", "HEAD^{commit}")
        if head != current:
            raise ValueError("evidence head must equal checked-out HEAD")

        is_github, run_locator = trusted_context()
        if args.trusted_ci and not is_github:
            raise ValueError("--trusted-ci is only valid inside an identified GitHub Actions run")
        trusted = args.trusted_ci and is_github
        producer = "trusted-ci" if trusted else "agent-declared"
        status = "pass" if trusted else "unproven"

        verify_log = (root / args.verify_log).resolve()
        rollback = root / ".artifacts/rollback/rollback-report.json"
        mutation = root / ".artifacts/mutation/critical-mutants.json"
        conformance = root / ".artifacts/conformance/http-conformance.json"
        benchmark_paths = sorted((root / ".artifacts/benchmarks").glob("*.json"))
        required_files = [verify_log, rollback, mutation, conformance, *benchmark_paths]
        missing = [str(path.relative_to(root)) for path in required_files if not path.is_file()]
        if missing:
            raise ValueError(f"missing evidence artifacts: {missing}")
        workloads = {json.loads(path.read_text()).get("workloadID"): path for path in benchmark_paths}
        expected_workloads = {
            "W1-Feed-Scroll-Smoke",
            "W2-Detail-Hero-Smoke",
            "W3-Auth-Gallery-Smoke",
        }
        if not expected_workloads.issubset(workloads):
            raise ValueError("W1/W2/W3 artifacts are required")
        mutation_data = json.loads(mutation.read_text())
        if mutation_data.get("verifiedCommit") != head:
            raise ValueError("mutation report is not bound to the evidence head")
        rollback_data = json.loads(rollback.read_text())
        if rollback_data.get("baseCommit") != base or rollback_data.get("headCommit") != head:
            raise ValueError("rollback report commit binding mismatch")
        conformance_data = json.loads(conformance.read_text())
        if conformance_data.get("verifiedCommit") != head or conformance_data.get("status") != "pass":
            raise ValueError("HTTP conformance report is not a passing result bound to the evidence head")

        locator_prefix = run_locator if trusted else "local"
        verification = [
            verification_result(
                "AIQA-GATE-003",
                "test",
                verify_log,
                producer,
                status,
                f"{locator_prefix}#verify",
                head,
            ),
            verification_result(
                "AIQA-GATE-007",
                "mutation",
                mutation,
                producer,
                status,
                f"{locator_prefix}#critical-mutants",
                head,
            ),
            verification_result(
                "AIQA-GATE-009",
                "test",
                rollback,
                producer,
                status,
                f"{locator_prefix}#rollback-gate",
                head,
            ),
            verification_result(
                "HTTP-CONF-PRIVATE-IMAGE-PROFILE",
                "test",
                conformance,
                producer,
                status,
                f"{locator_prefix}#http-conformance",
                head,
            ),
        ]
        for workload, path in sorted(workloads.items()):
            verification.append(
                verification_result(
                    workload,
                    "benchmark",
                    path,
                    producer,
                    status,
                    f"{locator_prefix}#{workload.lower()}",
                    head,
                )
            )

        context_material = json.dumps(
            {
                "base": base,
                "head": head,
                "specification": "docs/specifications/core-surface.md",
                "workflow": ".github/workflows/verify.yml",
            },
            sort_keys=True,
        ).encode()
        context_fingerprint = hashlib.sha256(context_material).hexdigest()
        bundle = {
            "schemaVersion": 1,
            "changeID": f"fovea-ci-{head[:12]}",
            "baseCommit": base,
            "headCommit": head,
            "verifiedCommit": head,
            "assuranceStage": args.assurance_stage,
            "taskContextFingerprint": context_fingerprint,
            "riskClass": "R3",
            "accountableOwner": "pending-human-maintainer",
            "requirements": [
                "AIQA-GATE-003",
                "AIQA-GATE-007",
                "AIQA-GATE-009",
                "HTTP-CONF-PRIVATE-IMAGE-PROFILE",
                "W1-Feed-Scroll-Smoke",
                "W2-Detail-Hero-Smoke",
                "W3-Auth-Gallery-Smoke",
                "SEC-CASE-014",
                "SEC-CASE-015",
                "SEC-CASE-016",
                "SEC-CASE-017",
                "SEC-CASE-018",
            ],
            "agent": {
                "tool": os.environ.get("FOVEA_AGENT_TOOL", "not-attested-by-ci"),
                "toolVersion": os.environ.get("FOVEA_AGENT_TOOL_VERSION", "unknown"),
                "model": os.environ.get("FOVEA_AGENT_MODEL", "unknown"),
                "modelVersion": os.environ.get("FOVEA_AGENT_MODEL_VERSION", "unknown"),
                "configurationFingerprint": os.environ.get(
                    "FOVEA_AGENT_CONFIGURATION_FINGERPRINT",
                    hashlib.sha256(b"unattested-agent-configuration").hexdigest(),
                ),
            },
            "permissions": {
                "tools": ["git", "xcodebuild", "swift", "python3"],
                "networkDomains": ["github.com"] if trusted else [],
                "hadProductionSecrets": False,
                "couldWriteProtectedBranch": False,
                "couldReadHeldOutTests": False,
            },
            "changedFiles": changed_files(root, base, head),
            "logicalChangedLines": logical_lines(root, base, head),
            "commands": [
                "scripts/verify.sh",
                f"scripts/verify-rollback.py --base {base} --head {head}",
                "scripts/generate-ci-evidence.py",
            ],
            "verification": verification,
            "dependencyChanges": [],
            "assumptions": [
                "CI evidence attests verification results, not the truth of unattested agent metadata.",
                "GitHub Actions run identity and branch protection remain external trust anchors.",
            ],
            "unproven": [
                "Human accountable-owner attestation",
                "Protected required-check status until a remote repository is configured",
                "Held-out evaluator independent of the public repository",
                "Agent identity fields when not supplied by reviewed change metadata",
            ],
            "rollback": f"Revert commits after {base}; rollback gate proves {base} builds and tests cleanly.",
        }
        output = (root / args.output).resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n")
        print(f"CI evidence bundle: {output.relative_to(root)} {digest(output)}")
        print(f"producer={producer} status={status} verifiedCommit={head}")
        return 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"CI evidence generation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
