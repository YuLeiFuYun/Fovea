#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import pathlib
import shutil
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent
APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"
MIB = 1024 * 1024


def load_module(name: str, path: pathlib.Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


support = load_module(
    "w5_apng_checkpoint_capture_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)
reference = load_module(
    "w5_apng_checkpoint_reference",
    PERFORMANCE / "w5_apng_reference.py",
)
model = load_module(
    "w5_apng_checkpoint_model_capture",
    PERFORMANCE / "w5_apng_checkpoint_model.py",
)


def require_object(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be an object")
    return value


def require_list(value: object, label: str) -> list:
    if not isinstance(value, list):
        raise SystemExit(f"{label} must be an array")
    return value


def validate_relative_path(value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str) or not value:
        raise SystemExit(f"{label} must be a nonempty path")
    path = pathlib.Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"{label} must remain relative")
    return path


def validate_plan(plan: dict) -> None:
    if plan.get("schemaVersion") != 1:
        raise SystemExit("APNG checkpoint plan schema mismatch")
    if plan.get("planID") != "FOVEA-W5-APNG-CHECKPOINT-MODEL-V1":
        raise SystemExit("APNG checkpoint plan identity mismatch")
    fixtures = require_list(plan.get("sourceFixtures"), "sourceFixtures")
    fixture_ids = [require_object(item, "fixture").get("id") for item in fixtures]
    if any(not isinstance(value, str) or not value for value in fixture_ids):
        raise SystemExit("source fixture id is invalid")
    if len(fixture_ids) != len(set(fixture_ids)):
        raise SystemExit("source fixture ids must be unique")
    for fixture in fixtures:
        validate_relative_path(fixture.get("relativePath"), "fixture relativePath")
        if not isinstance(fixture.get("role"), str) or not fixture["role"]:
            raise SystemExit("source fixture role is invalid")

    scenarios = require_list(plan.get("syntheticScenarios"), "syntheticScenarios")
    scenario_ids: list[str] = []
    for raw in scenarios:
        scenario = require_object(raw, "synthetic scenario")
        identifier = scenario.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise SystemExit("synthetic scenario id is invalid")
        scenario_ids.append(identifier)
        if scenario.get("patternFixture") not in fixture_ids:
            raise SystemExit(f"unknown scenario pattern fixture: {identifier}")
        if scenario.get("patternMode") not in {
            "repeat-scaled-area-ratios",
            "first-full-then-one-pixel",
        }:
            raise SystemExit(f"unsupported scenario pattern mode: {identifier}")
        for field in ("frameCount", "canvasWidth", "canvasHeight", "encodedSourceBytes"):
            value = scenario.get(field)
            if not isinstance(value, int) or value <= 0:
                raise SystemExit(f"{identifier}: invalid {field}")
    if len(scenario_ids) != len(set(scenario_ids)):
        raise SystemExit("synthetic scenario ids must be unique")

    budgets = require_list(plan.get("retainedBudgetMiB"), "retainedBudgetMiB")
    replay_limits = require_list(plan.get("maximumReplayFrames"), "maximumReplayFrames")
    if budgets != sorted(set(budgets)) or any(
        not isinstance(value, int) or value <= 0 for value in budgets
    ):
        raise SystemExit("retained budget grid must be unique, sorted, positive integers")
    if replay_limits != sorted(set(replay_limits)) or any(
        not isinstance(value, int) or value <= 0 for value in replay_limits
    ):
        raise SystemExit("maximum replay grid must be unique, sorted, positive integers")

    access = require_list(plan.get("accessProfiles"), "accessProfiles")
    access_ids = {require_object(item, "access profile").get("id") for item in access}
    if access_ids != {"uniform", "tail-hot"}:
        raise SystemExit("access profile contract changed")
    strategies = require_list(plan.get("retentionStrategies"), "retentionStrategies")
    strategy_ids = {
        require_object(item, "retention strategy").get("id") for item in strategies
    }
    if strategy_ids != {"raw-subrect-retained", "encoded-source-retained"}:
        raise SystemExit("retention strategy contract changed")

    policies = require_object(
        plan.get("boundImplementationPolicies"), "boundImplementationPolicies"
    )
    expected = {
        "imageCraftMaximumEncodedBytes": 64 * MIB,
        "imageCraftMaximumTimelineDecodedBytes": 512 * MIB,
        "imageCraftMaximumFrameDecodeWindow": 8,
        "foveaAnimationFrameMemoryHardCap": 32 * MIB,
    }
    if policies != expected:
        raise SystemExit("bound implementation policy values changed")
    reference_policy = require_object(plan.get("referencePolicyPoint"), "referencePolicyPoint")
    if reference_policy != {"retainedBudgetMiB": 32, "maximumReplayFrames": 8}:
        raise SystemExit("reference policy point changed")


def validate_policy_sources(imagecraft_root: pathlib.Path) -> dict[str, object]:
    imagecraft_types = imagecraft_root / "Sources/ImageCraftCore/AnimatedImageTypes.swift"
    fovea_system = ROOT / "Sources/FoveaSystem/FoveaSystemPipeline.swift"
    imagecraft_text = imagecraft_types.read_text()
    fovea_text = fovea_system.read_text()
    observations = {
        "imageCraftMaximumEncodedBytesObserved": (
            "maximumEncodedBytes: 64 * 1024 * 1024" in imagecraft_text
        ),
        "imageCraftMaximumTimelineDecodedBytesObserved": (
            "maximumTimelineDecodedBytes: Int = 512 * 1024 * 1024" in imagecraft_text
        ),
        "imageCraftMaximumFrameDecodeWindowObserved": (
            "maximumFrameDecodeWindow: Int = 8" in imagecraft_text
        ),
        "foveaAnimationFrameMemoryHardCapObserved": (
            "min(32 * 1024 * 1024, max(1, renderedMemoryCostLimit / 4))"
            in fovea_text
        ),
    }
    missing = [name for name, observed in observations.items() if not observed]
    if missing:
        raise SystemExit(f"bound implementation policy source changed: {missing}")
    return {
        "observations": observations,
        "files": {
            "imageCraftAnimatedImageTypes": support.file_identity(imagecraft_types),
            "foveaSystemPipeline": support.file_identity(fovea_system),
        },
    }


def fixture_summary(identifier: str, role: str, input_bytes: int, image) -> dict[str, object]:
    canvas_bytes = image.canvas_width * image.canvas_height * 4
    raw_bytes = sum(frame.byte_count for frame in image.frames)
    frames = []
    for index, frame in enumerate(image.frames):
        control = frame.control
        frames.append(
            {
                "index": index,
                "rect": {
                    "x": control.x_offset,
                    "y": control.y_offset,
                    "width": control.width,
                    "height": control.height,
                },
                "subrectRGBABytes": frame.byte_count,
                "disposal": {0: "none", 1: "background", 2: "previous"}[
                    control.dispose_op
                ],
                "blend": {0: "source", 1: "over"}[control.blend_op],
            }
        )
    return {
        "id": identifier,
        "role": role,
        "inputByteCount": input_bytes,
        "canvasWidth": image.canvas_width,
        "canvasHeight": image.canvas_height,
        "canvasRGBABytes": canvas_bytes,
        "frameCount": len(image.frames),
        "totalRawSubrectRGBABytes": raw_bytes,
        "totalFullCanvasTrackRGBABytes": canvas_bytes * len(image.frames),
        "rawSubrectOverFullTrackRatio": raw_bytes
        / (canvas_bytes * len(image.frames)),
        "maximumSubrectRGBABytes": max(frame.byte_count for frame in image.frames),
        "previousDisposalFrameCount": sum(
            frame.control.dispose_op == 2 for frame in image.frames
        ),
        "frames": frames,
    }


def scaled_pattern(image, canvas_bytes: int) -> tuple:
    native_canvas_bytes = image.canvas_width * image.canvas_height * 4
    result = []
    for frame in image.frames:
        scaled = int(round((frame.byte_count / native_canvas_bytes) * canvas_bytes / 4)) * 4
        result.append(
            model.FrameFootprint(
                min(canvas_bytes, max(4, scaled)),
                disposal_previous=frame.control.dispose_op == 2,
            )
        )
    return tuple(result)


def build_synthetic_scenario(raw: dict, images: dict[str, object]) -> dict[str, object]:
    width = int(raw["canvasWidth"])
    height = int(raw["canvasHeight"])
    frame_count = int(raw["frameCount"])
    canvas_bytes = width * height * 4
    source = images[str(raw["patternFixture"])]
    if raw["patternMode"] == "first-full-then-one-pixel":
        frames = (model.FrameFootprint(canvas_bytes),) + tuple(
            model.FrameFootprint(4) for _ in range(frame_count - 1)
        )
    else:
        frames = model.repeat_footprints(
            scaled_pattern(source, canvas_bytes), frame_count
        )
    total_raw = sum(frame.subrect_rgba_bytes for frame in frames)
    return {
        "id": str(raw["id"]),
        "patternFixture": str(raw["patternFixture"]),
        "patternMode": str(raw["patternMode"]),
        "frameCount": frame_count,
        "canvasWidth": width,
        "canvasHeight": height,
        "canvasRGBABytes": canvas_bytes,
        "encodedSourceBytes": int(raw["encodedSourceBytes"]),
        "totalRawSubrectRGBABytes": total_raw,
        "totalFullCanvasTrackRGBABytes": canvas_bytes * frame_count,
        "rawSubrectOverFullTrackRatio": total_raw / (canvas_bytes * frame_count),
        "maximumSubrectRGBABytes": max(frame.subrect_rgba_bytes for frame in frames),
        "previousDisposalFrameCount": sum(
            frame.disposal_previous for frame in frames
        ),
        "frames": frames,
    }


def access_weights(profile: dict, frame_count: int) -> tuple[float, ...]:
    if profile["kind"] == "uniform":
        return model.uniform_weights(frame_count)
    return model.tail_hot_weights(
        frame_count,
        tail_fraction=float(profile["tailFraction"]),
        tail_weight=float(profile["tailWeight"]),
    )


def compact_plan(plan) -> dict[str, object]:
    return {
        "checkpointCount": plan.checkpoint_count,
        "retainedCheckpointCount": plan.retained_checkpoint_count,
        "checkpointStarts": list(plan.checkpoint_starts),
        "retainedRawSubrectBytes": plan.retained_raw_subrect_bytes,
        "retainedCheckpointBytes": plan.retained_checkpoint_bytes,
        "retainedSourceBytes": plan.retained_source_bytes,
        "retainedBytes": plan.retained_bytes,
        "compositorWorkingBytesUpperBound": plan.compositor_working_bytes_upper_bound,
        "materializedOutputBytes": plan.materialized_output_bytes,
        "modeledPeakBytesUpperBound": plan.modeled_peak_bytes_upper_bound,
        "expectedReplayFrames": plan.expected_replay_frames,
        "p95ReplayFrames": plan.p95_replay_frames,
        "worstReplayFrames": plan.worst_replay_frames,
        "implicitInitialCheckpoint": plan.implicit_initial_checkpoint,
    }


def analyze(plan: dict, native_images: dict[str, object], retained_inputs: dict[str, dict]) -> dict:
    fixture_contracts = {
        str(item["id"]): item for item in require_list(plan["sourceFixtures"], "fixtures")
    }
    native = {
        identifier: fixture_summary(
            identifier,
            str(fixture_contracts[identifier]["role"]),
            int(retained_inputs[identifier]["byteCount"]),
            image,
        )
        for identifier, image in native_images.items()
    }
    scenarios = {
        str(raw["id"]): build_synthetic_scenario(raw, native_images)
        for raw in require_list(plan["syntheticScenarios"], "syntheticScenarios")
    }
    profiles = [require_object(item, "access profile") for item in plan["accessProfiles"]]
    strategies = [
        require_object(item, "retention strategy")
        for item in plan["retentionStrategies"]
    ]
    budgets = [int(value) * MIB for value in plan["retainedBudgetMiB"]]
    replay_limits = [int(value) for value in plan["maximumReplayFrames"]]
    reference_budget = int(plan["referencePolicyPoint"]["retainedBudgetMiB"]) * MIB
    reference_replay = int(plan["referencePolicyPoint"]["maximumReplayFrames"])

    matrix = []
    reference_frontiers: dict[str, object] = {}
    reference_failures: list[dict[str, str]] = []
    maximum_budget = max(budgets)
    for scenario_id, scenario in scenarios.items():
        frames = scenario["frames"]
        canvas_bytes = int(scenario["canvasRGBABytes"])
        for profile in profiles:
            weights = access_weights(profile, len(frames))
            for strategy in strategies:
                retain_raw = bool(strategy["retainRawSubrects"])
                retained_source = 0 if retain_raw else int(scenario["encodedSourceBytes"])
                retained_raw = (
                    sum(frame.subrect_rgba_bytes for frame in frames)
                    if retain_raw
                    else 0
                )
                frontier_by_replay: dict[int, tuple] = {}
                frontier_error_by_replay: dict[int, str] = {}
                for replay_limit in replay_limits:
                    try:
                        frontier_by_replay[replay_limit] = model.build_pareto_frontier(
                            frames=frames,
                            canvas_rgba_bytes=canvas_bytes,
                            access_weights=weights,
                            retained_budget_bytes=maximum_budget,
                            max_replay_frames=replay_limit,
                            retain_raw_subrects=retain_raw,
                            retained_source_bytes=retained_source,
                        )
                    except model.CheckpointModelError as error:
                        frontier_by_replay[replay_limit] = ()
                        frontier_error_by_replay[replay_limit] = str(error)
                for budget in budgets:
                    for replay_limit in replay_limits:
                        row = {
                            "scenarioID": scenario_id,
                            "accessProfileID": str(profile["id"]),
                            "retentionStrategyID": str(strategy["id"]),
                            "retainedBudgetBytes": budget,
                            "maximumReplayFrames": replay_limit,
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
                            row["status"] = "feasible"
                            row["selectedPlan"] = compact_plan(selected)
                            if budget == reference_budget and replay_limit == reference_replay:
                                key = "/".join(
                                    (scenario_id, str(profile["id"]), str(strategy["id"]))
                                )
                                reference_frontiers[key] = [
                                    compact_plan(item) for item in eligible
                                ]
                        else:
                            if retained_raw + retained_source > budget:
                                reason = "retained budget cannot hold source/raw state"
                            else:
                                reason = frontier_error_by_replay.get(
                                    replay_limit,
                                    "retained budget cannot satisfy the maximum replay constraint",
                                )
                            row["status"] = "infeasible"
                            row["reason"] = reason
                            if budget == reference_budget and replay_limit == reference_replay:
                                reference_failures.append(
                                    {
                                        "scenarioID": scenario_id,
                                        "accessProfileID": str(profile["id"]),
                                        "retentionStrategyID": str(strategy["id"]),
                                        "reason": reason,
                                    }
                                )
                        matrix.append(row)

    feasible = [row for row in matrix if row["status"] == "feasible"]
    reference_rows = [
        row
        for row in matrix
        if row["retainedBudgetBytes"] == reference_budget
        and row["maximumReplayFrames"] == reference_replay
    ]
    reference_feasible = [row for row in reference_rows if row["status"] == "feasible"]
    reference_case_counts: dict[str, dict[str, int]] = {}
    for scenario_id in scenarios:
        rows = [row for row in reference_rows if row["scenarioID"] == scenario_id]
        feasible_count = sum(row["status"] == "feasible" for row in rows)
        reference_case_counts[scenario_id] = {
            "feasible": feasible_count,
            "infeasible": len(rows) - feasible_count,
        }
    scenario_records = {
        identifier: {key: value for key, value in scenario.items() if key != "frames"}
        for identifier, scenario in scenarios.items()
    }
    return {
        "schemaVersion": 1,
        "nativeFixtures": native,
        "syntheticScenarios": scenario_records,
        "matrix": matrix,
        "referencePolicyFrontiers": reference_frontiers,
        "referencePolicyFailures": reference_failures,
        "summary": {
            "matrixCaseCount": len(matrix),
            "feasibleCaseCount": len(feasible),
            "infeasibleCaseCount": len(matrix) - len(feasible),
            "referencePolicyCaseCount": len(reference_rows),
            "referencePolicyFeasibleCaseCount": len(reference_feasible),
            "referencePolicyInfeasibleCaseCount": len(reference_rows)
            - len(reference_feasible),
            "referencePolicyFeasibleCombinations": [
                {
                    "scenarioID": scenario_id,
                    "retentionStrategyID": strategy_id,
                }
                for scenario_id, strategy_id in sorted(
                    {
                        (
                            str(row["scenarioID"]),
                            str(row["retentionStrategyID"]),
                        )
                        for row in reference_feasible
                    }
                )
            ],
            "referencePolicyScenariosWithAnyFeasibleCase": sorted(
                identifier
                for identifier, counts in reference_case_counts.items()
                if counts["feasible"] > 0
            ),
            "referencePolicyScenariosWithNoFeasibleCase": sorted(
                identifier
                for identifier, counts in reference_case_counts.items()
                if counts["feasible"] == 0
            ),
            "referencePolicyFullyFeasibleScenarios": sorted(
                identifier
                for identifier, counts in reference_case_counts.items()
                if counts["infeasible"] == 0
            ),
            "referencePolicyScenarioCaseCounts": reference_case_counts,
        },
        "claimBoundary": plan["modelBoundary"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--plan",
        type=pathlib.Path,
        default=ROOT / "Benchmarks/ComparativeLab/apng-checkpoint-plan.json",
    )
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    plan_path = args.plan.resolve()
    plan = json.loads(plan_path.read_text())
    validate_plan(plan)

    fixture_source_root = (ROOT / str(plan["sourceFixtureRoot"])).resolve()
    apngkit_root = ROOT / ".artifacts/research/animation-libs/APNGKit"
    imagecraft_root = ROOT.parent / "ImageCraft"
    if not fixture_source_root.is_dir():
        raise SystemExit(f"missing APNGKit fixture root: {fixture_source_root}")
    source_before = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(imagecraft_root),
        "APNGKit": support.git_snapshot(apngkit_root),
    }
    apngkit = source_before["APNGKit"]
    if apngkit["headCommit"] != APNGKIT_COMMIT or apngkit["dirty"] is not False:
        raise SystemExit("APNGKit fixture checkout must match the clean exact commit")

    policy_sources_before = validate_policy_sources(imagecraft_root)
    governing_paths = {
        "plan": plan_path,
        "model": PERFORMANCE / "w5_apng_checkpoint_model.py",
        "modelTests": PERFORMANCE / "test_w5_apng_checkpoint_model.py",
        "referenceParser": PERFORMANCE / "w5_apng_reference.py",
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_checkpoint_model.py",
        "captureContract": PERFORMANCE / "test_w5_apng_checkpoint_capture.py",
        "animationPolicy": ROOT / "docs/specifications/animation-policy.md",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }

    fixture_contracts = {
        str(item["id"]): item for item in require_list(plan["sourceFixtures"], "fixtures")
    }
    input_sources = {
        identifier: fixture_source_root
        / validate_relative_path(contract["relativePath"], "fixture relativePath")
        for identifier, contract in fixture_contracts.items()
    }
    for identifier, path in input_sources.items():
        if not path.is_file():
            raise SystemExit(f"missing APNG fixture {identifier}: {path}")
    inputs_before = {
        identifier: support.file_identity(path) for identifier, path in input_sources.items()
    }

    retained_plan = output / "plan.json"
    shutil.copyfile(plan_path, retained_plan)
    inputs_directory = output / "inputs"
    inputs_directory.mkdir()
    retained_inputs: dict[str, dict[str, object]] = {}
    native_images = {}
    for identifier, source_path in input_sources.items():
        retained = inputs_directory / f"{identifier}.apng"
        shutil.copyfile(source_path, retained)
        retained_inputs[identifier] = support.file_identity(retained)
        native_images[identifier] = reference.parse_apng_file(retained)

    source_identity = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        "sources": source_before,
        "policySources": policy_sources_before,
        "plan": support.file_identity(retained_plan),
        "inputs": retained_inputs,
        "claimBoundary": plan["modelBoundary"],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(
        json.dumps(source_identity, indent=2, sort_keys=True) + "\n"
    )

    analysis = analyze(plan, native_images, retained_inputs)
    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-CHECKPOINT-MODEL-SOURCE-BOUND-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "plan": support.file_identity(retained_plan),
        "analysis": analysis,
    }
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    inputs_after = {
        identifier: support.file_identity(path) for identifier, path in input_sources.items()
    }
    source_after = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(imagecraft_root),
        "APNGKit": support.git_snapshot(apngkit_root),
    }
    policy_sources_after = validate_policy_sources(imagecraft_root)
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
        "policySourcesBefore": policy_sources_before,
        "policySourcesAfter": policy_sources_after,
        "policySourcesUnchangedDuringCapture": (
            policy_sources_before == policy_sources_after
        ),
        "governingFilesBefore": governing_before,
        "governingFilesAfter": governing_after,
        "governingFilesUnchangedDuringCapture": governing_before == governing_after,
        "sourceIdentity": support.file_identity(source_identity_path),
        "plan": support.file_identity(retained_plan),
        "report": support.file_identity(report_path),
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_checkpoint_model.py"),
            str(output),
        ],
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    if not manifest["sourceUnchangedDuringCapture"]:
        raise SystemExit(f"source changed during capture: {manifest_path}")
    if not manifest["inputSourcesUnchangedDuringCapture"]:
        raise SystemExit(f"input source changed during capture: {manifest_path}")
    if not manifest["policySourcesUnchangedDuringCapture"]:
        raise SystemExit(f"policy source changed during capture: {manifest_path}")
    if not manifest["governingFilesUnchangedDuringCapture"]:
        raise SystemExit(f"governing file changed during capture: {manifest_path}")

    support.run(manifest["validatorCommand"], ROOT)
    print(report_path)


if __name__ == "__main__":
    main()
