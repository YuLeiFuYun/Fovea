#!/usr/bin/env python3
"""Fail closed when private Fovea workflows can spend hosted minutes implicitly."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = {
    "verify": ROOT / ".github/workflows/verify.yml",
    "live-network": ROOT / ".github/workflows/live-network-lab.yml",
}
POLICY = ROOT / "docs/governance/github-actions-budget-policy.md"
errors: list[str] = []


def block(source: str, heading: str) -> str:
    match = re.search(rf"^{re.escape(heading)}:\n(?P<body>(?:^[ ]+.*\n|^\n)*)", source, re.MULTILINE)
    return match.group("body") if match else ""


for name, path in WORKFLOWS.items():
    source = path.read_text()
    trigger = block(source, "on")
    if not trigger:
        errors.append(f"{name}: missing on block")
        continue
    if not re.search(r"^  workflow_dispatch:\s*$", trigger, re.MULTILINE):
        errors.append(f"{name}: workflow_dispatch is required")
    for forbidden in ("push", "pull_request", "schedule"):
        if re.search(rf"^  {forbidden}:\s*", trigger, re.MULTILINE):
            errors.append(f"{name}: automatic {forbidden} trigger is forbidden")
    budget = re.search(
        r"^      budget_approved:\s*$\n(?P<body>(?:^        .*\n)+)",
        trigger,
        re.MULTILINE,
    )
    if budget is None:
        errors.append(f"{name}: budget_approved dispatch input is required")
    else:
        body = budget.group("body")
        if not re.search(r"^        type: boolean\s*$", body, re.MULTILINE):
            errors.append(f"{name}: budget_approved must be boolean")
        if not re.search(r"^        default: false\s*$", body, re.MULTILINE):
            errors.append(f"{name}: budget_approved must default to false")
    jobs = block(source, "jobs")
    if "inputs.budget_approved" not in jobs:
        errors.append(f"{name}: every runner path must be guarded by budget approval")
    job_names = re.findall(r"^  ([A-Za-z0-9_-]+):\s*$", jobs, re.MULTILINE)
    for job_name in job_names:
        job_match = re.search(
            rf"^  {re.escape(job_name)}:\s*$\n(?P<body>(?:^    .*\n|^\n)*)",
            jobs,
            re.MULTILINE,
        )
        job_body = job_match.group("body") if job_match else ""
        if "runs-on:" in job_body and "timeout-minutes:" not in job_body:
            errors.append(f"{name}/{job_name}: runner job needs timeout-minutes")
    if "cancel-in-progress: true" not in source:
        errors.append(f"{name}: concurrency must cancel superseded runs")

verify = WORKFLOWS["verify"].read_text()
verify_trigger = block(verify, "on")
for required in (
    "type: choice",
    "default: identity",
    "- identity",
    "- full",
    "inputs.profile == 'identity'",
    "inputs.profile == 'full'",
    "RAW_BASE_COMMIT: ${{ inputs.base_commit }}",
):
    if required not in verify:
        errors.append(f"verify: missing profile/baseline contract marker: {required}")
if "profile:" not in verify_trigger:
    errors.append("verify: profile dispatch input is required")
if "timeout-minutes: 15" not in verify:
    errors.append("verify: identity matrix must cap each architecture at 15 minutes")
if "timeout-minutes: 60" not in verify:
    errors.append("verify: full verification must retain a 60-minute hard ceiling")
if "inputs.profile == 'identity' || inputs.profile == 'full'" in verify:
    errors.append("verify: full profile must not repeat the identity matrix")

live = WORKFLOWS["live-network"].read_text()
if "cron:" in live:
    errors.append("live-network: cron execution is forbidden during private publication")

if not POLICY.is_file():
    errors.append("GitHub Actions budget policy document is missing")
else:
    policy = POLICY.read_text()
    for marker in (
        "manually dispatched only",
        "budget_approved: false",
        "all 102 mutation applications",
        "Do not push a sequence of speculative root commits",
    ):
        if marker not in policy:
            errors.append(f"budget policy is missing required decision: {marker}")

if errors:
    for error in errors:
        print(f"error: {error}")
    raise SystemExit(1)
print("GitHub Actions budget governance passed: manual-only, explicit approval, bounded jobs")
