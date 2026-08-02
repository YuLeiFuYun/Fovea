#!/usr/bin/env python3
"""Render the mandatory cross-session Fovea context from repository memory."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / ".artifacts/project-memory"


def load(relative: str) -> dict[str, Any]:
    value = json.loads((ROOT / relative).read_text())
    if not isinstance(value, dict):
        raise TypeError(f"{relative} must contain an object")
    return value


def canonical_digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def git(args: list[str]) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, text=True, capture_output=True
    ).stdout.strip()


def main() -> int:
    memory = load("docs/project-memory/project-memory.json")
    roadmap = load("docs/project-memory/long-horizon-roadmap.json")
    ledger = load("docs/project-memory/discussion-ledger.json")
    workloads = load("Benchmarks/workload-registry.json")
    phase_status = load("docs/phase0b-status.json")
    negative = load("docs/research/negative-results.json")
    head = git(["rev-parse", "HEAD"])
    dirty = bool(git(["status", "--porcelain=v1"]))
    generated = dt.datetime.now(dt.timezone.utc).isoformat()

    lines = [
        "# Fovea Mandatory Task Context",
        "",
        f"Generated: `{generated}`",
        f"HEAD: `{head}`",
        f"Dirty worktree: `{str(dirty).lower()}`",
        f"Project memory digest: `{canonical_digest(memory)}`",
        f"Long-horizon roadmap digest: `{canonical_digest(roadmap)}`",
        f"Discussion ledger digest: `{canonical_digest(ledger)}`",
        f"Workload registry digest: `{canonical_digest(workloads)}`",
        "",
        "## Standing requirements",
        "",
    ]
    for requirement in memory["standingRequirements"]:
        lines.append(f"- **{requirement['id']}** — {requirement['requirement']}")

    lines.extend(["", "## Current state", ""])
    current = memory["currentState"]
    lines.extend([
        f"- Phase: {current['currentPhase']}",
        f"- Current executable workload subset: {', '.join(current['currentExecutableWorkloads'])}",
        f"- Full accepted workload range: {current['fullAcceptedWorkloadRange']}",
        f"- Source state: {current['sourceState']}",
        f"- Release claim permitted: {current['releaseClaimPermitted']}",
    ])

    lines.extend(["", "## Long-horizon roadmap control plane", ""])
    lines.extend([
        f"- Roadmap: **{roadmap['roadmapID']}** (`{roadmap['status']}`)",
        f"- Canonical plan: `{roadmap['canonicalPlan']}`",
        f"- Active frontier: {', '.join(roadmap['activeFrontier'])}",
        "- Route changes require explicit discussion-ledger supersession; unfinished phases remain visible.",
    ])
    lines.extend(["", "### P0-P9 phase status", ""])
    for phase in roadmap["phases"]:
        dependencies = ", ".join(phase.get("dependencies", [])) or "none"
        lines.append(
            f"- **{phase['id']} {phase['title']}** — status=`{phase['status']}`; "
            f"dependencies=`{dependencies}`"
        )
    lines.extend(["", "### Current roadmap execution queue", ""])
    for item in roadmap["currentExecutionQueue"]:
        lines.append(
            f"- **{item['id']}** [{item['phase']}] (`{item['status']}`) — {item['summary']}"
        )

    lines.extend(["", "## W1-W15 status", ""])
    for workload in workloads["workloads"]:
        lines.append(
            f"- **{workload['id']} {workload['name']}** — {workload['acceptedPurpose']}; "
            f"status=`{workload['status']}`; claim=`{workload['claimActivation']}`"
        )

    lines.extend(["", "## Open obligations", ""])
    obligations = sorted(memory["openObligations"], key=lambda item: (item["priority"], item["id"]))
    for obligation in obligations:
        lines.append(
            f"- **P{obligation['priority']} {obligation['id']}** "
            f"(`{obligation['status']}`) — {obligation['summary']}"
        )

    lines.extend(["", "## Capability gaps", ""])
    for gap in memory["capabilityGaps"]:
        lines.append(
            f"- **{gap['id']}** [{', '.join(gap['workloads'])}] "
            f"(`{gap['status']}`) — {gap['summary']}"
        )

    lines.extend(["", "## Active discussion decisions", ""])
    for entry in ledger["entries"]:
        if not str(entry["status"]).startswith("active"):
            continue
        lines.append(f"### {entry['id']}")
        for decision in entry.get("decisions", entry.get("remediation", [])):
            lines.append(f"- {decision}")
        lines.append("")

    lines.extend(["## Negative results that must remain visible", ""])
    for entry in negative.get("entries", []):
        lines.append(f"- **{entry['id']}** — {entry.get('finding', entry.get('summary', 'registered negative result'))}")

    lines.extend([
        "",
        "## Phase 0b blockers",
        "",
    ])
    for blocker in phase_status.get("blockers", []):
        lines.append(f"- **{blocker['id']}** (`{blocker['status']}`) — {blocker['summary']}")

    lines.extend([
        "",
        "## Mandatory interpretation",
        "",
        "- W1-W3 are the current executable baseline, not the full comparison program.",
        "- Planned, implemented, calibrated and formally verified are distinct states.",
        "- Do not remove or renumber W1-W15 without an explicit discussion-ledger supersession.",
        "- Do not reset, commit or push without explicit user instruction.",
        "- At task end, update memory, gaps, negative results and open obligations before claiming completion.",
    ])

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    markdown = "\n".join(lines) + "\n"
    (OUT_DIR / "current-context.md").write_text(markdown)
    (OUT_DIR / "current-context.json").write_text(json.dumps({
        "schemaVersion": 1,
        "generatedAt": generated,
        "head": head,
        "dirty": dirty,
        "projectMemoryDigest": canonical_digest(memory),
        "longHorizonRoadmapDigest": canonical_digest(roadmap),
        "discussionLedgerDigest": canonical_digest(ledger),
        "workloadRegistryDigest": canonical_digest(workloads),
        "activeRequirementIDs": [item["id"] for item in memory["standingRequirements"]],
        "activeRoadmapPhases": roadmap["activeFrontier"],
        "roadmapExecutionQueueIDs": [item["id"] for item in roadmap["currentExecutionQueue"]],
        "openObligationIDs": [
            item["id"] for item in obligations if item["status"] not in {"completed", "superseded"}
        ],
        "currentExecutableWorkloads": current["currentExecutableWorkloads"],
        "fullAcceptedWorkloadRange": current["fullAcceptedWorkloadRange"],
    }, indent=2, sort_keys=True) + "\n")
    print(f"Project context: {OUT_DIR.relative_to(ROOT)}/current-context.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
