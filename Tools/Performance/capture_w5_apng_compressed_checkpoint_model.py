#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import pathlib
import shutil
import statistics
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent
MIB = 1024 * 1024
APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


support = load_module(
    "w5_apng_compressed_capture_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)
reference = load_module(
    "w5_apng_compressed_capture_reference",
    PERFORMANCE / "w5_apng_reference.py",
)
base = load_module(
    "w5_apng_compressed_capture_base",
    PERFORMANCE / "capture_w5_apng_checkpoint_model.py",
)
model = load_module(
    "w5_apng_compressed_capture_model",
    PERFORMANCE / "w5_apng_compressed_checkpoint_model.py",
)


def require_object(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be an object")
    return value


def require_list(value: object, label: str) -> list:
    if not isinstance(value, list):
        raise SystemExit(f"{label} must be an array")
    return value


def validate_compressed_plan(plan: dict) -> None:
    if plan.get("schemaVersion") != 1:
        raise SystemExit("compressed checkpoint plan schema mismatch")
    if plan.get("planID") != "FOVEA-W5-APNG-COMPRESSED-CHECKPOINT-MODEL-V1":
        raise SystemExit("compressed checkpoint plan identity mismatch")
    if plan.get("basePlan") != "Benchmarks/ComparativeLab/apng-checkpoint-plan.json":
        raise SystemExit("compressed checkpoint base plan path changed")
    compression = require_object(plan.get("compressionModel"), "compressionModel")
    expected = {
        "id": model.COMPRESSION_MODEL,
        "level": 9,
        "headerBytes": model.HEADER.size,
        "minimumBlobBytes": model.HEADER.size + 8,
        "decompressorWorkspaceBytes": 256 * 1024,
        "nativeAnchor": compression.get("nativeAnchor"),
    }
    if compression != expected or not isinstance(compression.get("nativeAnchor"), str):
        raise SystemExit("compressed checkpoint model contract changed")
    ratios = require_list(plan.get("checkpointBlobRatioPPM"), "checkpointBlobRatioPPM")
    if ratios != sorted(set(ratios)) or any(
        not isinstance(value, int) or value <= 0 or value > 1_000_000
        for value in ratios
    ):
        raise SystemExit("checkpoint ratio grid is invalid")
    if plan.get("referencePolicyPoint") != {
        "retainedBudgetMiB": 32,
        "maximumReplayFrames": 8,
        "modeledPeakHardCapMiB": 32,
    }:
        raise SystemExit("compressed checkpoint reference policy changed")
    reporting = require_object(plan.get("reportingPolicy"), "reportingPolicy")
    if reporting != {
        "separateRetainedAndPeakFeasibility": True,
        "reportLargestFeasibleRatioByScenario": True,
        "reportLargestPeakClearingRatioByScenario": True,
        "globalOptimalityClaim": False,
    }:
        raise SystemExit("compressed checkpoint reporting policy changed")
    boundaries = require_list(plan.get("modelBoundary"), "modelBoundary")
    if len(boundaries) < 5:
        raise SystemExit("compressed checkpoint model boundary is incomplete")


def pre_frame_states(image) -> tuple[bytes, ...]:
    canvas = bytearray(image.canvas_width * image.canvas_height * 4)
    states: list[bytes] = []
    for raw_frame in image.frames:
        states.append(bytes(canvas))
        control = raw_frame.control
        previous = bytes(canvas) if control.dispose_op == 2 else None
        source_offset = 0
        for row in range(control.height):
            canvas_row = control.y_offset + row
            for column in range(control.width):
                canvas_column = control.x_offset + column
                destination_offset = (
                    canvas_row * image.canvas_width + canvas_column
                ) * 4
                source = tuple(raw_frame.rgba[source_offset : source_offset + 4])
                source_offset += 4
                if control.blend_op == 0:
                    result = source
                else:
                    destination = tuple(
                        canvas[destination_offset : destination_offset + 4]
                    )
                    result = reference._straight_over(source, destination)
                canvas[destination_offset : destination_offset + 4] = bytes(result)
        if control.dispose_op == 1:
            for row in range(control.height):
                start = (
                    (control.y_offset + row) * image.canvas_width + control.x_offset
                ) * 4
                end = start + control.width * 4
                canvas[start:end] = b"\x00" * (control.width * 4)
        elif control.dispose_op == 2:
            if previous is None:
                raise SystemExit("missing previous state")
            canvas[:] = previous
    return tuple(states)


def native_anchor(
    images: dict[str, object],
    output: pathlib.Path,
) -> tuple[dict[str, object], dict[str, dict[str, object]]]:
    checkpoint_directory = output / "checkpoints"
    checkpoint_directory.mkdir()
    fixtures: dict[str, object] = {}
    inventory: dict[str, dict[str, object]] = {}
    all_ratios: list[int] = []
    for fixture_id, image in images.items():
        raw_bytes = image.canvas_width * image.canvas_height * 4
        records = []
        states = pre_frame_states(image)
        for frame_index, state in enumerate(states[1:], start=1):
            blob = model.encode_checkpoint_blob(
                state,
                image.canvas_width,
                image.canvas_height,
                compression_level=9,
            )
            width, height, decoded = model.decode_checkpoint_blob(blob)
            if width != image.canvas_width or height != image.canvas_height or decoded != state:
                raise SystemExit(f"checkpoint round-trip mismatch: {fixture_id} {frame_index}")
            path = checkpoint_directory / f"{fixture_id}-pre-frame-{frame_index:03d}.fapc"
            path.write_bytes(blob)
            identity = support.file_identity(path)
            relative = str(path.relative_to(output))
            inventory[relative] = identity
            ratio_ppm = math.ceil(len(blob) * 1_000_000 / raw_bytes)
            all_ratios.append(ratio_ppm)
            records.append(
                {
                    "frameIndex": frame_index,
                    "rawStraightAlphaBytes": raw_bytes,
                    "checkpointBlob": identity,
                    "checkpointBlobRatioPPM": ratio_ppm,
                    "roundTripExact": True,
                }
            )
        ratios = [item["checkpointBlobRatioPPM"] for item in records]
        fixtures[fixture_id] = {
            "canvasWidth": image.canvas_width,
            "canvasHeight": image.canvas_height,
            "frameCount": len(image.frames),
            "retainedCheckpointCount": len(records),
            "compressionModel": model.COMPRESSION_MODEL,
            "records": records,
            "minimumRatioPPM": min(ratios) if ratios else None,
            "maximumRatioPPM": max(ratios) if ratios else None,
            "medianRatioPPM": statistics.median(ratios) if ratios else None,
            "meanRatioPPM": statistics.fmean(ratios) if ratios else None,
        }
    return (
        {
            "compressionModel": model.COMPRESSION_MODEL,
            "fixtureCount": len(fixtures),
            "checkpointBlobCount": len(all_ratios),
            "minimumRatioPPM": min(all_ratios),
            "maximumRatioPPM": max(all_ratios),
            "medianRatioPPM": statistics.median(all_ratios),
            "meanRatioPPM": statistics.fmean(all_ratios),
            "fixtures": fixtures,
            "interpretationBoundary": (
                "Native deterministic zlib ratios are exact for these retained small fixture "
                "states only. They are not used to assign synthetic scaled scenario ratios."
            ),
        },
        inventory,
    )


def access_weights(profile: dict, frame_count: int) -> tuple[float, ...]:
    if profile["kind"] == "uniform":
        return model.uniform_weights(frame_count)
    return model.tail_hot_weights(
        frame_count,
        tail_fraction=float(profile["tailFraction"]),
        tail_weight=float(profile["tailWeight"]),
    )


def compressed_frames(base_frames) -> tuple[model.FrameFootprint, ...]:
    return tuple(
        model.FrameFootprint(
            frame.subrect_rgba_bytes,
            disposal_previous=frame.disposal_previous,
        )
        for frame in base_frames
    )


def compact_plan(plan) -> dict[str, object]:
    return {
        "checkpointCount": plan.checkpoint_count,
        "retainedCheckpointCount": plan.retained_checkpoint_count,
        "checkpointStarts": list(plan.checkpoint_starts),
        "checkpointBlobBytes": plan.checkpoint_blob_bytes,
        "retainedRawSubrectBytes": plan.retained_raw_subrect_bytes,
        "retainedCheckpointBytes": plan.retained_checkpoint_bytes,
        "retainedSourceBytes": plan.retained_source_bytes,
        "retainedBytes": plan.retained_bytes,
        "decompressorWorkspaceBytes": plan.decompressor_workspace_bytes,
        "compositorWorkingBytesUpperBound": plan.compositor_working_bytes_upper_bound,
        "materializedOutputBytes": plan.materialized_output_bytes,
        "modeledPeakBytesUpperBound": plan.modeled_peak_bytes_upper_bound,
        "expectedReplayFrames": plan.expected_replay_frames,
        "p95ReplayFrames": plan.p95_replay_frames,
        "worstReplayFrames": plan.worst_replay_frames,
        "implicitInitialCheckpoint": plan.implicit_initial_checkpoint,
    }


def analyze(base_plan: dict, compressed_plan: dict, images: dict[str, object]) -> dict:
    scenarios = {
        str(raw["id"]): base.build_synthetic_scenario(raw, images)
        for raw in require_list(base_plan["syntheticScenarios"], "syntheticScenarios")
    }
    profiles = [require_object(item, "access profile") for item in base_plan["accessProfiles"]]
    strategies = [
        require_object(item, "retention strategy")
        for item in base_plan["retentionStrategies"]
    ]
    ratios = [int(value) for value in compressed_plan["checkpointBlobRatioPPM"]]
    budgets = [int(value) * MIB for value in base_plan["retainedBudgetMiB"]]
    replay_limits = [int(value) for value in base_plan["maximumReplayFrames"]]
    reference_budget = int(compressed_plan["referencePolicyPoint"]["retainedBudgetMiB"]) * MIB
    reference_replay = int(compressed_plan["referencePolicyPoint"]["maximumReplayFrames"])
    peak_hard_cap = int(compressed_plan["referencePolicyPoint"]["modeledPeakHardCapMiB"]) * MIB
    workspace = int(compressed_plan["compressionModel"]["decompressorWorkspaceBytes"])
    minimum_blob = int(compressed_plan["compressionModel"]["minimumBlobBytes"])
    maximum_budget = max(budgets)

    matrix: list[dict[str, object]] = []
    for scenario_id, scenario in scenarios.items():
        frames = compressed_frames(scenario["frames"])
        canvas_bytes = int(scenario["canvasRGBABytes"])
        for profile in profiles:
            weights = access_weights(profile, len(frames))
            for strategy in strategies:
                retain_raw = bool(strategy["retainRawSubrects"])
                retained_source = 0 if retain_raw else int(scenario["encodedSourceBytes"])
                retained_raw = sum(frame.subrect_rgba_bytes for frame in frames) if retain_raw else 0
                for ratio_ppm in ratios:
                    blob_bytes = model.checkpoint_blob_bytes_for_ratio(
                        canvas_bytes,
                        ratio_ppm,
                        minimum_blob_bytes=minimum_blob,
                    )
                    frontier_by_replay: dict[int, tuple] = {}
                    error_by_replay: dict[int, str] = {}
                    for replay_limit in replay_limits:
                        try:
                            frontier_by_replay[replay_limit] = model.build_pareto_frontier(
                                frames=frames,
                                canvas_rgba_bytes=canvas_bytes,
                                checkpoint_blob_bytes=blob_bytes,
                                access_weights=weights,
                                retained_budget_bytes=maximum_budget,
                                max_replay_frames=replay_limit,
                                retain_raw_subrects=retain_raw,
                                retained_source_bytes=retained_source,
                                decompressor_workspace_bytes=workspace,
                            )
                        except model.CompressedCheckpointModelError as error:
                            frontier_by_replay[replay_limit] = ()
                            error_by_replay[replay_limit] = str(error)
                    for budget in budgets:
                        for replay_limit in replay_limits:
                            row: dict[str, object] = {
                                "scenarioID": scenario_id,
                                "accessProfileID": str(profile["id"]),
                                "retentionStrategyID": str(strategy["id"]),
                                "checkpointBlobRatioPPM": ratio_ppm,
                                "checkpointBlobBytes": blob_bytes,
                                "retainedBudgetBytes": budget,
                                "maximumReplayFrames": replay_limit,
                                "modeledPeakHardCapBytes": peak_hard_cap,
                            }
                            eligible = [
                                item
                                for item in frontier_by_replay[replay_limit]
                                if item.retained_bytes <= budget
                            ]
                            if eligible:
                                selected = min(
                                    eligible,
                                    key=lambda item: (
                                        item.expected_replay_frames,
                                        item.p95_replay_frames,
                                        item.worst_replay_frames,
                                        item.retained_bytes,
                                        item.checkpoint_starts,
                                    ),
                                )
                                peak_eligible = [
                                    item
                                    for item in eligible
                                    if item.modeled_peak_bytes_upper_bound <= peak_hard_cap
                                ]
                                row["status"] = "retained-feasible"
                                row["selectedPlan"] = compact_plan(selected)
                                row["peakHardCapFeasible"] = bool(peak_eligible)
                                if peak_eligible:
                                    peak_selected = min(
                                        peak_eligible,
                                        key=lambda item: (
                                            item.expected_replay_frames,
                                            item.p95_replay_frames,
                                            item.worst_replay_frames,
                                            item.retained_bytes,
                                            item.checkpoint_starts,
                                        ),
                                    )
                                    row["selectedPeakClearingPlan"] = compact_plan(peak_selected)
                            else:
                                row["status"] = "infeasible"
                                row["peakHardCapFeasible"] = False
                                if retained_raw + retained_source > budget:
                                    row["reason"] = "retained budget cannot hold source/raw state"
                                else:
                                    row["reason"] = error_by_replay.get(
                                        replay_limit,
                                        "retained budget cannot satisfy the maximum replay constraint",
                                    )
                            matrix.append(row)

    reference_rows = [
        row for row in matrix
        if row["retainedBudgetBytes"] == reference_budget
        and row["maximumReplayFrames"] == reference_replay
    ]
    retained_feasible = [row for row in matrix if row["status"] == "retained-feasible"]
    peak_feasible = [row for row in matrix if row["peakHardCapFeasible"]]
    reference_retained = [row for row in reference_rows if row["status"] == "retained-feasible"]
    reference_peak = [row for row in reference_rows if row["peakHardCapFeasible"]]

    thresholds: dict[str, dict[str, object]] = {}
    for scenario_id in scenarios:
        thresholds[scenario_id] = {}
        for strategy in strategies:
            strategy_id = str(strategy["id"])
            key_rows = [
                row for row in reference_rows
                if row["scenarioID"] == scenario_id
                and row["retentionStrategyID"] == strategy_id
            ]
            retained_ratios = [
                int(row["checkpointBlobRatioPPM"])
                for row in key_rows if row["status"] == "retained-feasible"
            ]
            peak_ratios = [
                int(row["checkpointBlobRatioPPM"])
                for row in key_rows if row["peakHardCapFeasible"]
            ]
            thresholds[scenario_id][strategy_id] = {
                "largestRetainedFeasibleRatioPPM": max(retained_ratios) if retained_ratios else None,
                "largestPeakClearingRatioPPM": max(peak_ratios) if peak_ratios else None,
                "allAccessProfilesRetainedFeasibleAtLargestRatio": (
                    bool(retained_ratios)
                    and sum(
                        row["status"] == "retained-feasible"
                        and row["checkpointBlobRatioPPM"] == max(retained_ratios)
                        for row in key_rows
                    ) == len(profiles)
                ),
                "allAccessProfilesPeakClearingAtLargestRatio": (
                    bool(peak_ratios)
                    and sum(
                        row["peakHardCapFeasible"]
                        and row["checkpointBlobRatioPPM"] == max(peak_ratios)
                        for row in key_rows
                    ) == len(profiles)
                ),
            }

    scenario_records = {
        identifier: {key: value for key, value in scenario.items() if key != "frames"}
        for identifier, scenario in scenarios.items()
    }
    return {
        "schemaVersion": 1,
        "compressionModel": compressed_plan["compressionModel"],
        "syntheticScenarios": scenario_records,
        "matrix": matrix,
        "referencePolicyThresholds": thresholds,
        "summary": {
            "matrixCaseCount": len(matrix),
            "retainedFeasibleCaseCount": len(retained_feasible),
            "infeasibleCaseCount": len(matrix) - len(retained_feasible),
            "modeledPeakHardCapFeasibleCaseCount": len(peak_feasible),
            "referencePolicyCaseCount": len(reference_rows),
            "referencePolicyRetainedFeasibleCaseCount": len(reference_retained),
            "referencePolicyPeakHardCapFeasibleCaseCount": len(reference_peak),
            "referencePolicyGlobalOptimalityClaim": False,
            "referencePolicyScenariosWithAnyRetainedFeasibleRatio": sorted({
                str(row["scenarioID"]) for row in reference_retained
            }),
            "referencePolicyScenariosWithAnyPeakClearingRatio": sorted({
                str(row["scenarioID"]) for row in reference_peak
            }),
        },
        "claimBoundary": compressed_plan["modelBoundary"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base-plan",
        type=pathlib.Path,
        default=ROOT / "Benchmarks/ComparativeLab/apng-checkpoint-plan.json",
    )
    parser.add_argument(
        "--compressed-plan",
        type=pathlib.Path,
        default=ROOT / "Benchmarks/ComparativeLab/apng-compressed-checkpoint-plan.json",
    )
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    base_plan_path = args.base_plan.resolve()
    compressed_plan_path = args.compressed_plan.resolve()
    base_plan = json.loads(base_plan_path.read_text())
    compressed_plan = json.loads(compressed_plan_path.read_text())
    base.validate_plan(base_plan)
    validate_compressed_plan(compressed_plan)

    fixture_source_root = (ROOT / str(base_plan["sourceFixtureRoot"])).resolve()
    apngkit_root = ROOT / ".artifacts/research/animation-libs/APNGKit"
    imagecraft_root = ROOT.parent / "ImageCraft"
    source_before = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(imagecraft_root),
        "APNGKit": support.git_snapshot(apngkit_root),
    }
    if (
        source_before["APNGKit"]["headCommit"] != APNGKIT_COMMIT
        or source_before["APNGKit"]["dirty"] is not False
    ):
        raise SystemExit("APNGKit fixture checkout must match clean exact commit")
    policy_before = base.validate_policy_sources(imagecraft_root)

    governing_paths = {
        "basePlan": base_plan_path,
        "compressedPlan": compressed_plan_path,
        "model": PERFORMANCE / "w5_apng_compressed_checkpoint_model.py",
        "modelTests": PERFORMANCE / "test_w5_apng_compressed_checkpoint_model.py",
        "referenceParser": PERFORMANCE / "w5_apng_reference.py",
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_compressed_checkpoint_model.py",
        "captureContract": PERFORMANCE / "test_w5_apng_compressed_checkpoint_capture.py",
        "animationPolicy": ROOT / "docs/specifications/animation-policy.md",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }

    fixture_contracts = {
        str(item["id"]): item for item in require_list(base_plan["sourceFixtures"], "sourceFixtures")
    }
    input_sources = {
        identifier: fixture_source_root
        / base.validate_relative_path(contract["relativePath"], "fixture relativePath")
        for identifier, contract in fixture_contracts.items()
    }
    inputs_before = {
        identifier: support.file_identity(path) for identifier, path in input_sources.items()
    }

    retained_base_plan = output / "base-plan.json"
    retained_compressed_plan = output / "compressed-plan.json"
    shutil.copyfile(base_plan_path, retained_base_plan)
    shutil.copyfile(compressed_plan_path, retained_compressed_plan)
    inputs_directory = output / "inputs"
    inputs_directory.mkdir()
    retained_inputs: dict[str, dict[str, object]] = {}
    images = {}
    artifact_inventory: dict[str, dict[str, object]] = {}
    for identifier, source_path in input_sources.items():
        retained = inputs_directory / f"{identifier}.apng"
        shutil.copyfile(source_path, retained)
        identity = support.file_identity(retained)
        retained_inputs[identifier] = identity
        artifact_inventory[str(retained.relative_to(output))] = identity
        images[identifier] = reference.parse_apng_file(retained)

    anchor, checkpoint_inventory = native_anchor(images, output)
    artifact_inventory.update(checkpoint_inventory)
    source_identity = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        "sources": source_before,
        "policySources": policy_before,
        "basePlan": support.file_identity(retained_base_plan),
        "compressedPlan": support.file_identity(retained_compressed_plan),
        "inputs": retained_inputs,
        "claimBoundary": compressed_plan["modelBoundary"],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(json.dumps(source_identity, indent=2, sort_keys=True) + "\n")

    analysis = analyze(base_plan, compressed_plan, images)
    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-COMPRESSED-CHECKPOINT-MODEL-SOURCE-BOUND-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "basePlan": support.file_identity(retained_base_plan),
        "compressedPlan": support.file_identity(retained_compressed_plan),
        "nativeCheckpointRoundTrip": anchor,
        "analysis": analysis,
        "artifactInventory": dict(sorted(artifact_inventory.items())),
    }
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    source_after = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(imagecraft_root),
        "APNGKit": support.git_snapshot(apngkit_root),
    }
    inputs_after = {
        identifier: support.file_identity(path) for identifier, path in input_sources.items()
    }
    policy_after = base.validate_policy_sources(imagecraft_root)
    governing_after = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }
    manifest = {
        "schemaVersion": 1,
        "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_before == source_after,
        "inputSourcesBefore": inputs_before,
        "inputSourcesAfter": inputs_after,
        "inputSourcesUnchangedDuringCapture": inputs_before == inputs_after,
        "policySourcesBefore": policy_before,
        "policySourcesAfter": policy_after,
        "policySourcesUnchangedDuringCapture": policy_before == policy_after,
        "governingFilesBefore": governing_before,
        "governingFilesAfter": governing_after,
        "governingFilesUnchangedDuringCapture": governing_before == governing_after,
        "sourceIdentity": support.file_identity(source_identity_path),
        "basePlan": support.file_identity(retained_base_plan),
        "compressedPlan": support.file_identity(retained_compressed_plan),
        "report": support.file_identity(report_path),
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_compressed_checkpoint_model.py"),
            str(output),
        ],
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    for field in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "policySourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if manifest[field] is not True:
            raise SystemExit(f"{field} failed: {manifest_path}")

    support.run(manifest["validatorCommand"], ROOT)
    print(report_path)


if __name__ == "__main__":
    main()
