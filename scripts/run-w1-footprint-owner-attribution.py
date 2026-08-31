#!/usr/bin/env python3
"""Run the preregistered W1 cache-purge x UI-backing-release attribution matrix.

Every cell is a fresh app process. The normal ComparativeLab W1 path is unchanged when
FOVEA_W1_OWNER_INTERVENTION is absent; this runner opts into the owner-attribution
instrumentation and keeps all simulator results explicitly E2/directional.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import random
import runpy
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
RESEARCH_ROOT = ROOT.parent / "FoveaImageLifecycleResearch"
CONTRACT_PATH = RESEARCH_ROOT / "data" / "w1-footprint-owner-contract.json"
ANALYZER_PATH = RESEARCH_ROOT / "scripts" / "analyze_w1_footprint_owner.py"
DEFAULT_ARTIFACT_ROOT = ROOT / ".artifacts" / "performance" / "h007-w1-footprint-owner"
CELLS = ("WI-00", "WI-10", "WI-01", "WI-11")
SETTLE_LABELS = ("immediate", "50ms", "250ms", "1000ms")
PHASE_LABELS = (
    "post-cache-preparation-baseline",
    "scroll-start",
    "scroll-finished",
    "cancel-all-start",
    "cancel-all-finished",
    "loads-drained",
    "pre-intervention-visible-state",
    "post-intervention",
)
DIAGNOSTIC_TIMELINE_KINDS = {
    "decodeQueued",
    "decodeStarted",
    "decodeCompleted",
    "decodeCancelled",
    "responseBodyMaterialized",
    "progressiveFinalizationReady",
    "renderedPublished",
    "renderedMemoryPurged",
}

# Reuse the source-bound simulator plumbing instead of maintaining a second Xcode/simulator
# implementation. runpy does not execute that file's __main__ block.
sys.path.insert(0, str(ROOT / "scripts"))
COMMON = runpy.run_path(str(ROOT / "scripts" / "run-comparative-simulator-lab.py"))
APPS: dict[str, tuple[str, str]] = COMMON["APPS"]
A_TIER: list[str] = COMMON["A_TIER_HEADLESS"]
SIMULATOR_IDENTITY: dict[str, str] = COMMON["SIMULATOR_IDENTITY"]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def slug(value: str) -> str:
    return "-".join(part for part in "".join(c.lower() if c.isalnum() else " " for c in value).split())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_contract() -> dict[str, Any]:
    require(CONTRACT_PATH.is_file(), f"missing H007 contract: {CONTRACT_PATH}")
    require(ANALYZER_PATH.is_file(), f"missing H007 analyzer: {ANALYZER_PATH}")
    contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    require(contract.get("schema") == 1, "unexpected H007 contract schema")
    require(
        contract.get("contract") == "w1-footprint-owner-attribution-v1",
        "unexpected H007 contract identity",
    )
    amendments = contract.get("preMeasurementAmendments", [])
    require(
        any(item.get("id") == "AMEND-001-DEFER-ADAPTER-TEARDOWN" for item in amendments),
        "H007 AMEND-001 must be recorded before measured owner attribution",
    )
    return contract


def prepare_and_build(env: dict[str, str], comparator: str) -> None:
    COMMON["run"](
        [
            "python3",
            "scripts/run-comparative-simulator-lab.py",
            "--comparator",
            comparator,
            "--workload",
            "W1-SCROLL-V1",
            "--build-only",
        ],
        env=env,
        timeout=1_800,
    )


def install_app(env: dict[str, str], udid: str, comparator: str) -> None:
    COMMON["install_existing_apps"](env, udid, [comparator])


def artifact_names(base_output_name: str) -> tuple[str, str, str, str]:
    require(base_output_name.endswith(".json"), "base output name must end with .json")
    stem = base_output_name[: -len(".json")]
    return (
        base_output_name,
        f"{stem}-w1-owner-cell.json",
        f"{stem}-diagnostics.json",
        f"{base_output_name}.failure",
    )


def wait_for_cell_artifacts(
    normal: Path,
    owner: Path,
    diagnostics: Path,
    failure: Path,
    *,
    require_diagnostics: bool,
    timeout: float = 240.0,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if failure.is_file():
            raise RuntimeError(f"benchmark app failed: {failure.read_text(errors='replace').strip()}")
        ready = normal.is_file() and owner.is_file()
        if require_diagnostics:
            ready = ready and diagnostics.is_file()
        if ready:
            return
        time.sleep(0.25)
    raise RuntimeError(f"timed out waiting for H007 cell artifact: {owner.name}")


def validate_owner_cell(owner: Any, expected_cell: str) -> None:
    require(isinstance(owner, dict), "owner cell must be an object")
    require(owner.get("schema") == 1, "unexpected owner cell schema")
    require(
        owner.get("contract") == "w1-footprint-owner-attribution-v1",
        "owner cell contract mismatch",
    )
    require(owner.get("interventionID") == expected_cell, "owner intervention identity mismatch")
    pre = owner.get("preInterventionPhysicalFootprintBytes")
    require(isinstance(pre, int) and pre >= 0, "owner cell pre footprint is invalid")
    hitch_count = owner.get("hitchCount")
    hitch_excess = owner.get("hitchExcessNanoseconds")
    require(isinstance(hitch_count, int) and hitch_count >= 0, "owner cell hitchCount is invalid")
    require(
        isinstance(hitch_excess, int) and hitch_excess >= 0,
        "owner cell hitchExcessNanoseconds is invalid",
    )

    samples = owner.get("settleSamples")
    require(isinstance(samples, list) and len(samples) == 4, "owner settle sample count mismatch")
    require([row.get("label") for row in samples] == list(SETTLE_LABELS), "owner settle labels drifted")
    previous_elapsed = -1
    for row in samples:
        elapsed = row.get("actualElapsedNanoseconds")
        footprint = row.get("physicalFootprintBytes")
        require(isinstance(elapsed, int) and elapsed >= previous_elapsed, "owner settle elapsed drifted")
        require(isinstance(footprint, int) and footprint >= 0, "owner settle footprint is invalid")
        previous_elapsed = elapsed

    phases = owner.get("phaseSamples")
    require(isinstance(phases, list), "owner phaseSamples are missing")
    labels = [row.get("label") for row in phases]
    require(labels == list(PHASE_LABELS), f"owner phase labels drifted: {labels}")
    previous_uptime = -1
    for row in phases:
        uptime = row.get("uptimeNanoseconds")
        footprint = row.get("physicalFootprintBytes")
        require(isinstance(uptime, int) and uptime >= previous_uptime, "owner phase clock is not monotonic")
        require(isinstance(footprint, int) and footprint >= 0, "owner phase footprint is invalid")
        previous_uptime = uptime

    snapshot = owner.get("visibleBackingSnapshot")
    require(isinstance(snapshot, dict), "owner visible backing snapshot is missing")
    for key in (
        "visibleCellCount",
        "visibleBackingOwnerCount",
        "uniqueImageIdentityCount",
        "uniqueBackingIdentityCount",
        "estimatedUniqueCPUBackingBytes",
    ):
        require(isinstance(snapshot.get(key), int) and snapshot[key] >= 0, f"invalid backing field: {key}")
    backings = snapshot.get("backings")
    require(isinstance(backings, list), "owner backing records are missing")
    ordinals = [row.get("backingOrdinal") for row in backings]
    require(ordinals == list(range(1, len(backings) + 1)), "backing ordinals are not contiguous")
    serialized = json.dumps(snapshot, sort_keys=True)
    require("0x" not in serialized and "pointer" not in serialized.lower(), "backing snapshot leaks raw pointer identity")


def phase_by_label(owner: dict[str, Any], label: str) -> dict[str, Any]:
    rows = [row for row in owner["phaseSamples"] if row.get("label") == label]
    require(len(rows) == 1, f"owner phase {label} must occur exactly once")
    return rows[0]


def bounded_clock_origin(
    owner: dict[str, Any],
    purge_event: dict[str, Any],
) -> dict[str, int]:
    pre = int(phase_by_label(owner, "pre-intervention-visible-state")["uptimeNanoseconds"])
    post = int(phase_by_label(owner, "post-intervention")["uptimeNanoseconds"])
    elapsed = purge_event.get("elapsedNanoseconds")
    require(isinstance(elapsed, int) and elapsed >= 0, "purge diagnostic lacks elapsed clock")
    require(pre >= elapsed and post >= elapsed, "diagnostic clock origin would underflow")
    return {
        "lowerBoundUptimeNanoseconds": pre - elapsed,
        "upperBoundUptimeNanoseconds": post - elapsed,
        "boundWidthNanoseconds": post - pre,
    }


def fovea_sidecar(
    owner: dict[str, Any],
    diagnostics: dict[str, Any],
    intervention: str,
    raw_diagnostics_path: str,
) -> dict[str, Any]:
    events = diagnostics.get("events")
    require(isinstance(events, list), "Fovea diagnostic sidecar events are missing")
    purge_events = [event for event in events if event.get("kind") == "renderedMemoryPurged"]
    expects_purge = intervention in {"WI-10", "WI-11"}
    if expects_purge:
        require(len(purge_events) == 1, f"expected exactly one Fovea purge event, got {len(purge_events)}")
        purge = purge_events[0]
        require(isinstance(purge.get("byteCount"), int) and purge["byteCount"] >= 0, "invalid purge byteCount")
        require(isinstance(purge.get("itemCount"), int) and purge["itemCount"] >= 0, "invalid purge itemCount")
        origin_bounds = bounded_clock_origin(owner, purge)
        timeline: list[dict[str, Any]] = []
        for event in events:
            if event.get("kind") not in DIAGNOSTIC_TIMELINE_KINDS:
                continue
            elapsed = event.get("elapsedNanoseconds")
            if not isinstance(elapsed, int) or elapsed < 0:
                continue
            timeline.append(
                {
                    "sequence": event.get("sequence"),
                    "kind": event.get("kind"),
                    "elapsedNanoseconds": elapsed,
                    "absoluteUptimeLowerBoundNanoseconds": (
                        origin_bounds["lowerBoundUptimeNanoseconds"] + elapsed
                    ),
                    "absoluteUptimeUpperBoundNanoseconds": (
                        origin_bounds["upperBoundUptimeNanoseconds"] + elapsed
                    ),
                    "byteCount": event.get("byteCount"),
                    "itemCount": event.get("itemCount"),
                    "durationNanoseconds": event.get("durationNanoseconds"),
                    "reason": event.get("reason"),
                }
            )
        rendered_purge = {
            "byteCount": purge["byteCount"],
            "itemCount": purge["itemCount"],
            "reason": purge.get("reason"),
            "sequence": purge.get("sequence"),
            "elapsedNanoseconds": purge.get("elapsedNanoseconds"),
            "clockOriginBounds": origin_bounds,
        }
    else:
        require(not purge_events, f"unexpected Fovea purge event in {intervention}")
        rendered_purge = None
        timeline = []

    return {
        "renderedMemoryPurged": rendered_purge,
        "visibleBackingSnapshot": owner["visibleBackingSnapshot"],
        "releasedUIBackingOwnerCount": owner["releasedUIBackingOwnerCount"],
        "diagnosticTimeline": timeline,
        "rawDiagnosticsArtifact": raw_diagnostics_path,
        "diagnosticClockPolicy": (
            "Purge cells derive a bounded monotonic clock origin from the unique purge event "
            "occurring between the absolute pre/post intervention phase samples. Non-purge cells "
            "do not use unanchored diagnostic timestamps for owner attribution."
        ),
    }


def cancellation_metrics(normal: dict[str, Any]) -> dict[str, Any]:
    origin = normal.get("originMetrics", {})
    keys = (
        "postCancellationBytes",
        "postCancellationCompletedBytes",
        "postCancellationAbandonedBytes",
        "cancellationAcknowledgementCount",
        "cancellationAcknowledgementP95Nanoseconds",
        "cancellationAcknowledgementMaximumNanoseconds",
        "completedRequestCount",
        "stoppedRequestCount",
    )
    return {key: origin.get(key) for key in keys}


def run_cell(
    *,
    env: dict[str, str],
    udid: str,
    comparator: str,
    identity: dict[str, Any],
    plan_digest: str,
    claim_digest: str,
    intervention: str,
    run_index: int,
    output_dir: Path,
    block_label: str,
    cache_state: str,
    time_scale: float,
) -> tuple[dict[str, Any], dict[str, Any]]:
    _, bundle = APPS[comparator]
    container = Path(
        COMMON["run"](
            ["xcrun", "simctl", "get_app_container", udid, bundle, "data"],
            env=env,
            timeout=60,
        ).stdout.strip()
    )
    output_name = f"h007-{block_label}-{intervention.lower().replace('-', '')}.json"
    normal_name, owner_name, diagnostic_name, failure_name = artifact_names(output_name)
    documents = container / "Documents"
    normal_source = documents / normal_name
    owner_source = documents / owner_name
    diagnostic_source = documents / diagnostic_name
    failure_source = documents / failure_name
    for path in (normal_source, owner_source, diagnostic_source, failure_source):
        path.unlink(missing_ok=True)

    child = env.copy()
    child.update(
        {
            "SIMCTL_CHILD_FOVEA_BENCHMARK_COMMIT": identity["commit"],
            "SIMCTL_CHILD_FOVEA_BENCHMARK_TREE_DIGEST": identity["sourceTreeDigest"],
            "SIMCTL_CHILD_FOVEA_BENCHMARK_DIRTY": "1" if identity["includesWorkingTreeChanges"] else "0",
            "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_ID": "FOVEA-P0B-COMP-V1",
            "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_DIGEST": plan_digest,
            "SIMCTL_CHILD_FOVEA_CLAIM_FAMILY_DIGEST": claim_digest,
            "SIMCTL_CHILD_FOVEA_SIMULATOR_PROFILE_ID": SIMULATOR_IDENTITY["deviceProfileID"],
            "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_VERSION": SIMULATOR_IDENTITY["osVersion"],
            "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_BUILD": SIMULATOR_IDENTITY["osBuild"],
            "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_CHANNEL": SIMULATOR_IDENTITY["osChannel"],
            "SIMCTL_CHILD_FOVEA_W1_OWNER_INTERVENTION": intervention,
        }
    )
    if comparator == "Fovea":
        child["SIMCTL_CHILD_FOVEA_BENCHMARK_DIAGNOSTICS"] = "1"

    COMMON["run"](
        [
            "xcrun",
            "simctl",
            "launch",
            "--terminate-running-process",
            udid,
            bundle,
            "--workload",
            "W1-SCROLL-V1",
            "--cache-state",
            cache_state,
            "--network-profile",
            "NET-LOCAL-V1",
            "--run-index",
            str(run_index),
            "--time-scale",
            str(time_scale),
            "--output",
            output_name,
        ],
        env=child,
        timeout=60,
    )
    wait_for_cell_artifacts(
        normal_source,
        owner_source,
        diagnostic_source,
        failure_source,
        require_diagnostics=comparator == "Fovea",
    )

    normal = json.loads(normal_source.read_text(encoding="utf-8"))
    spec = {
        "comparator": comparator,
        "workload": "W1-SCROLL-V1",
        "cache": cache_state,
        "cachePreparationRepetitions": 1,
        "derivedRasterProfile": None,
        "scale": time_scale,
    }
    COMMON["validate"](normal, spec, identity, plan_digest, claim_digest)
    failed_checks = [check for check in normal.get("checks", []) if not check.get("passed")]
    require(not failed_checks, f"W1 correctness guard failed in {block_label}/{intervention}: {failed_checks}")

    owner = json.loads(owner_source.read_text(encoding="utf-8"))
    validate_owner_cell(owner, intervention)

    raw_dir = output_dir / "raw" / block_label / intervention
    raw_dir.mkdir(parents=True, exist_ok=True)
    normal_dest = raw_dir / normal_name
    owner_dest = raw_dir / owner_name
    shutil.copy2(normal_source, normal_dest)
    shutil.copy2(owner_source, owner_dest)

    diagnostics: dict[str, Any] | None = None
    diagnostic_dest: Path | None = None
    if comparator == "Fovea":
        diagnostics = json.loads(diagnostic_source.read_text(encoding="utf-8"))
        diagnostic_dest = raw_dir / diagnostic_name
        shutil.copy2(diagnostic_source, diagnostic_dest)

    cell: dict[str, Any] = {
        "preInterventionPhysicalFootprintBytes": owner["preInterventionPhysicalFootprintBytes"],
        "settleSamples": owner["settleSamples"],
        "hitchCount": owner["hitchCount"],
        "hitchExcessNanoseconds": owner["hitchExcessNanoseconds"],
        "phaseSamples": owner["phaseSamples"],
        "uiBackingSnapshot": owner["visibleBackingSnapshot"],
        "releasedUIBackingOwnerCount": owner["releasedUIBackingOwnerCount"],
        "interventionDurationNanoseconds": owner["interventionDurationNanoseconds"],
        "originCancellationMetrics": cancellation_metrics(normal),
        "normalProcessMetrics": normal.get("processMetrics"),
        "rawRunArtifact": str(normal_dest.relative_to(ROOT)),
        "rawOwnerArtifact": str(owner_dest.relative_to(ROOT)),
    }
    if comparator == "Fovea":
        assert diagnostics is not None and diagnostic_dest is not None
        cell["foveaSidecar"] = fovea_sidecar(
            owner,
            diagnostics,
            intervention,
            str(diagnostic_dest.relative_to(ROOT)),
        )

    metadata = {
        "normalSHA256": sha256_file(normal_dest),
        "ownerSHA256": sha256_file(owner_dest),
        "diagnosticsSHA256": sha256_file(diagnostic_dest) if diagnostic_dest else None,
    }
    return cell, metadata


def randomized_orders(seed: int, count: int) -> list[list[str]]:
    rng = random.Random(seed)
    orders: list[list[str]] = []
    for _ in range(count):
        order = list(CELLS)
        rng.shuffle(order)
        orders.append(order)
    return orders


def run_campaign(args: argparse.Namespace) -> int:
    contract = load_contract()
    minimum_blocks = int(contract["runDesign"]["minimumMeasuredBlocksForE2"])
    if not args.diagnostic:
        require(args.blocks >= minimum_blocks, f"measured E2 campaign requires at least {minimum_blocks} blocks")
    require(args.warmup_blocks >= 0, "warmup block count must be non-negative")
    require(args.blocks >= 1, "block count must be positive")
    require(args.cache_state in {"cold", "warm-disk", "warm-memory"}, "invalid cache state")
    require(0 < args.time_scale <= 1, "time scale must be in (0, 1]")

    env: dict[str, str] = COMMON["environment"]()
    if not args.skip_build:
        prepare_and_build(env, args.comparator)

    identity: dict[str, Any] = COMMON["git_identity"](env)
    plan_digest: str = COMMON["canonical_digest"](ROOT / "Benchmarks/ComparativeLab/experiment-plan.json")
    claim_digest: str = COMMON["canonical_digest"](ROOT / "Benchmarks/statistical-claim-families.json")
    contract_digest = sha256_file(CONTRACT_PATH)

    udid: str = COMMON["simulator"](env)
    install_app(env, udid, args.comparator)
    if args.diagnostic:
        print("H007 diagnostic mode: host quiescence is not claim-bearing; results remain directional.", flush=True)
    else:
        COMMON["assert_measurement_host_quiet"](root=ROOT)

    campaign_name = args.output_name or (
        f"{slug(args.comparator)}-{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    )
    output_dir = DEFAULT_ARTIFACT_ROOT / campaign_name
    require(not output_dir.exists(), f"output directory already exists: {output_dir.relative_to(ROOT)}")
    output_dir.mkdir(parents=True)

    total_blocks = args.warmup_blocks + args.blocks
    orders = randomized_orders(args.seed, total_blocks)
    warmup_orders = orders[: args.warmup_blocks]
    measured_orders = orders[args.warmup_blocks :]
    raw_metadata: list[dict[str, Any]] = []
    run_index = 0

    print(
        f"H007 W1 owner attribution: comparator={args.comparator} warmups={args.warmup_blocks} "
        f"measuredBlocks={args.blocks} seed={args.seed}",
        flush=True,
    )

    for warmup_index, order in enumerate(warmup_orders):
        block_label = f"warmup-{warmup_index:02d}"
        print(f"Warmup block {warmup_index + 1}/{len(warmup_orders)} order={order}", flush=True)
        for cell_id in order:
            _, metadata = run_cell(
                env=env,
                udid=udid,
                comparator=args.comparator,
                identity=identity,
                plan_digest=plan_digest,
                claim_digest=claim_digest,
                intervention=cell_id,
                run_index=run_index,
                output_dir=output_dir,
                block_label=block_label,
                cache_state=args.cache_state,
                time_scale=args.time_scale,
            )
            raw_metadata.append({"phase": "warmup", "block": warmup_index, "cell": cell_id, **metadata})
            run_index += 1

    blocks: list[dict[str, Any]] = []
    for block_index, order in enumerate(measured_orders):
        if not args.diagnostic:
            COMMON["assert_measurement_host_quiet"](root=ROOT)
        block_label = f"block-{block_index:02d}"
        print(f"Measured block {block_index + 1}/{len(measured_orders)} order={order}", flush=True)
        cells: dict[str, Any] = {}
        for cell_id in order:
            cell, metadata = run_cell(
                env=env,
                udid=udid,
                comparator=args.comparator,
                identity=identity,
                plan_digest=plan_digest,
                claim_digest=claim_digest,
                intervention=cell_id,
                run_index=run_index,
                output_dir=output_dir,
                block_label=block_label,
                cache_state=args.cache_state,
                time_scale=args.time_scale,
            )
            cells[cell_id] = cell
            raw_metadata.append({"phase": "measured", "block": block_index, "cell": cell_id, **metadata})
            run_index += 1
        current_identity = COMMON["git_identity"](env)
        require(current_identity == identity, f"Fovea source identity changed during H007 block {block_index}")
        blocks.append({"blockIndex": block_index, "order": order, "cells": cells})

    final_identity = COMMON["git_identity"](env)
    require(final_identity == identity, "Fovea source identity changed during H007 campaign")

    payload = {
        "schema": 1,
        "contract": "w1-footprint-owner-attribution-v1",
        "evidenceClass": "E2",
        "comparator": args.comparator,
        "environment": {
            "executionEnvironment": "simulator",
            "simulatorIdentity": SIMULATOR_IDENTITY,
            "sourceIdentity": identity,
            "sourceUnchangedDuringRun": True,
            "contractSHA256": contract_digest,
            "experimentPlanDigest": plan_digest,
            "claimFamilyDigest": claim_digest,
            "cacheState": args.cache_state,
            "networkProfile": "NET-LOCAL-V1",
            "timeScale": args.time_scale,
            "randomSeed": args.seed,
            "warmupBlockCount": args.warmup_blocks,
            "warmupOrders": warmup_orders,
            "hostQuiescenceGateEnforced": not args.diagnostic,
            "formalDeviceClaimEligible": False,
        },
        "blocks": blocks,
    }
    input_path = output_dir / "input.json"
    input_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output_dir / "raw-artifacts.json").write_text(
        json.dumps(raw_metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    analysis_path = output_dir / "analysis.json"
    result = subprocess.run(
        ["python3", str(ANALYZER_PATH), str(input_path), "--output", str(analysis_path)],
        cwd=RESEARCH_ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=120,
    )
    if result.returncode != 0:
        print(result.stdout[-12_000:], file=sys.stderr)
        print(result.stderr[-12_000:], file=sys.stderr)
        raise RuntimeError("H007 offline analyzer rejected runtime artifact")
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    summary = {
        "schema": 1,
        "contract": payload["contract"],
        "comparator": args.comparator,
        "sourceIdentity": identity,
        "contractSHA256": contract_digest,
        "inputSHA256": sha256_file(input_path),
        "analysisSHA256": sha256_file(analysis_path),
        "measuredBlockCount": analysis["measuredBlockCount"],
        "minimumMeasuredBlocksGate": analysis["minimumMeasuredBlocksGate"],
        "zeroHitchAcrossInterventionCells": analysis["zeroHitchAcrossInterventionCells"],
        "aggregateContrasts": analysis["aggregateContrasts"],
        "formalDeviceClaimEligible": False,
        "status": "completed-directional-simulator" if args.diagnostic else "completed-e2-simulator",
    }
    summary_path = output_dir / "report.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        f"H007 complete: blocks={analysis['measuredBlockCount']} zeroHitch={analysis['zeroHitchAcrossInterventionCells']}",
        flush=True,
    )
    print(f"Input: {input_path.relative_to(ROOT)}", flush=True)
    print(f"Analysis: {analysis_path.relative_to(ROOT)}", flush=True)
    print(f"Report: {summary_path.relative_to(ROOT)}", flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run W1 footprint owner attribution cells in fresh simulator processes.")
    parser.add_argument("--comparator", choices=A_TIER, default="Fovea")
    parser.add_argument("--cache-state", choices=["cold", "warm-disk", "warm-memory"], default="cold")
    parser.add_argument("--time-scale", type=float, default=0.1)
    parser.add_argument("--blocks", type=int, default=5)
    parser.add_argument("--warmup-blocks", type=int, default=1)
    parser.add_argument("--seed", type=int, default=20260811)
    parser.add_argument("--output-name")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--diagnostic", action="store_true")
    args = parser.parse_args()
    try:
        return run_campaign(args)
    except Exception as error:
        print(f"H007 W1 owner attribution failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
