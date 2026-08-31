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
MIB = 1024 * 1024
APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"


def load_module(name: str, path: pathlib.Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


support = load_module(
    "w5_apng_tile_capture_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)
base_capture = load_module(
    "w5_apng_tile_base_capture_support",
    PERFORMANCE / "capture_w5_apng_checkpoint_model.py",
)
reference = load_module(
    "w5_apng_tile_reference",
    PERFORMANCE / "w5_apng_reference.py",
)
base_model = load_module(
    "w5_apng_tile_base_model",
    PERFORMANCE / "w5_apng_checkpoint_model.py",
)
tile_model = load_module(
    "w5_apng_tile_model_capture",
    PERFORMANCE / "w5_apng_tile_checkpoint_model.py",
)


def require_object(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be an object")
    return value


def require_list(value: object, label: str) -> list:
    if not isinstance(value, list):
        raise SystemExit(f"{label} must be an array")
    return value


def validate_tile_plan(plan: dict) -> None:
    if plan.get("schemaVersion") != 1:
        raise SystemExit("APNG tile checkpoint plan schema mismatch")
    if plan.get("planID") != "FOVEA-W5-APNG-TILE-CHECKPOINT-CANDIDATE-V1":
        raise SystemExit("APNG tile checkpoint plan identity mismatch")
    if plan.get("basePlan") != "Benchmarks/ComparativeLab/apng-checkpoint-plan.json":
        raise SystemExit("APNG tile checkpoint base plan changed")
    tile_sizes = plan.get("tileSizes")
    if tile_sizes != [32, 64, 128, 256]:
        raise SystemExit("APNG tile size grid changed")
    root = require_object(plan.get("rootRepresentation"), "rootRepresentation")
    if root != {
        "entryBytesPerTile": 8,
        "frameZeroRoot": "implicit-transparent-not-retained",
        "headerBytesPerRetainedRoot": 64,
        "sharing": "unchanged immutable tile versions are shared across checkpoint roots",
    }:
        raise SystemExit("APNG tile root representation changed")
    if plan.get("retainedBudgetMiB") != [8, 16, 32, 64, 128, 256, 512]:
        raise SystemExit("APNG tile retained budget grid changed")
    if plan.get("maximumReplayFrames") != [4, 8, 16]:
        raise SystemExit("APNG tile replay grid changed")
    if plan.get("referencePolicyPoint") != {
        "retainedBudgetMiB": 32,
        "maximumReplayFrames": 8,
    }:
        raise SystemExit("APNG tile reference policy changed")
    sparse = require_object(plan.get("sparseMotion"), "sparseMotion")
    if sparse != {
        "mode": "deterministic-coprime-translation",
        "purpose": "avoid assuming every one-pixel sparse update remains in the same tile",
        "xMultiplier": 97,
        "yMultiplier": 193,
    }:
        raise SystemExit("APNG tile sparse motion changed")
    boundaries = [str(value).lower() for value in plan.get("modelBoundary") or []]
    required_boundary_tokens = (
        "not a proof of global",
        "previous-disposal",
        "flat table",
        "not a product",
    )
    if any(not any(token in item for item in boundaries) for token in required_boundary_tokens):
        raise SystemExit("APNG tile model boundary is incomplete")


def disposal_name(raw: int) -> str:
    try:
        return {0: "none", 1: "background", 2: "previous"}[raw]
    except KeyError as error:
        raise SystemExit(f"unsupported APNG disposal value: {raw}") from error


def scale_frame(frame, image, width: int, height: int):
    control = frame.control
    x = (control.x_offset * width) // image.canvas_width
    y = (control.y_offset * height) // image.canvas_height
    right = math.ceil(
        (control.x_offset + control.width) * width / image.canvas_width
    )
    bottom = math.ceil(
        (control.y_offset + control.height) * height / image.canvas_height
    )
    return tile_model.TileFrame(
        x=x,
        y=y,
        width=max(1, right - x),
        height=max(1, bottom - y),
        disposal=disposal_name(control.dispose_op),
    )


def scenario_frames(
    raw: dict,
    native_images: dict[str, object],
    tile_plan: dict,
) -> tuple:
    frame_count = int(raw["frameCount"])
    width = int(raw["canvasWidth"])
    height = int(raw["canvasHeight"])
    if raw["patternMode"] == "first-full-then-one-pixel":
        sparse = tile_plan["sparseMotion"]
        frames = [tile_model.TileFrame(0, 0, width, height, "none")]
        for index in range(1, frame_count):
            frames.append(
                tile_model.TileFrame(
                    (index * int(sparse["xMultiplier"])) % width,
                    (index * int(sparse["yMultiplier"])) % height,
                    1,
                    1,
                    "none",
                )
            )
        return tuple(frames)
    image = native_images[str(raw["patternFixture"])]
    pattern = tuple(scale_frame(frame, image, width, height) for frame in image.frames)
    return tuple(pattern[index % len(pattern)] for index in range(frame_count))


def access_weights(profile: dict, frame_count: int) -> tuple[float, ...]:
    if profile["kind"] == "uniform":
        return base_model.uniform_weights(frame_count)
    return base_model.tail_hot_weights(
        frame_count,
        tail_fraction=float(profile["tailFraction"]),
        tail_weight=float(profile["tailWeight"]),
    )


def compact_plan(plan) -> dict[str, object]:
    return {
        "tileSize": plan.tile_size,
        "tileCount": plan.tile_count,
        "layoutFamily": plan.layout_family,
        "checkpointCount": plan.checkpoint_count,
        "retainedRootCount": plan.retained_root_count,
        "checkpointStarts": list(plan.checkpoint_starts),
        "uniqueRetainedTileVersionCount": plan.unique_retained_tile_version_count,
        "retainedTileVersionBytes": plan.retained_tile_version_bytes,
        "retainedRootBytes": plan.retained_root_bytes,
        "retainedRawSubrectBytes": plan.retained_raw_subrect_bytes,
        "retainedSourceBytes": plan.retained_source_bytes,
        "retainedBytes": plan.retained_bytes,
        "maximumDirtyTileBytes": plan.maximum_dirty_tile_bytes,
        "materializedOutputBytes": plan.materialized_output_bytes,
        "rootBuildScratchBytes": plan.root_build_scratch_bytes,
        "modeledPeakBytesUpperBound": plan.modeled_peak_bytes_upper_bound,
        "expectedReplayFrames": plan.expected_replay_frames,
        "p95ReplayFrames": plan.p95_replay_frames,
        "worstReplayFrames": plan.worst_replay_frames,
        "implicitInitialRoot": plan.implicit_initial_root,
    }


def scenario_summary(raw: dict, frames: tuple) -> dict[str, object]:
    canvas_bytes = int(raw["canvasWidth"]) * int(raw["canvasHeight"]) * 4
    raw_bytes = sum(frame.rgba_bytes for frame in frames)
    return {
        "id": str(raw["id"]),
        "patternFixture": str(raw["patternFixture"]),
        "patternMode": str(raw["patternMode"]),
        "frameCount": len(frames),
        "canvasWidth": int(raw["canvasWidth"]),
        "canvasHeight": int(raw["canvasHeight"]),
        "canvasRGBABytes": canvas_bytes,
        "encodedSourceBytes": int(raw["encodedSourceBytes"]),
        "totalRawSubrectRGBABytes": raw_bytes,
        "totalFullCanvasTrackRGBABytes": canvas_bytes * len(frames),
        "rawSubrectOverFullTrackRatio": raw_bytes
        / (canvas_bytes * len(frames)),
        "previousDisposalFrameCount": sum(
            frame.disposal == "previous" for frame in frames
        ),
        "backgroundDisposalFrameCount": sum(
            frame.disposal == "background" for frame in frames
        ),
    }


def analyze(
    tile_plan: dict,
    base_plan: dict,
    native_images: dict[str, object],
) -> dict[str, object]:
    profiles = [require_object(item, "access profile") for item in base_plan["accessProfiles"]]
    strategies = [
        require_object(item, "retention strategy")
        for item in base_plan["retentionStrategies"]
    ]
    budgets = [int(value) * MIB for value in tile_plan["retainedBudgetMiB"]]
    replay_limits = [int(value) for value in tile_plan["maximumReplayFrames"]]
    reference_budget = int(tile_plan["referencePolicyPoint"]["retainedBudgetMiB"]) * MIB
    reference_replay = int(tile_plan["referencePolicyPoint"]["maximumReplayFrames"])
    root_entry_bytes = int(tile_plan["rootRepresentation"]["entryBytesPerTile"])
    root_header_bytes = int(tile_plan["rootRepresentation"]["headerBytesPerRetainedRoot"])

    matrix: list[dict[str, object]] = []
    reference_frontiers: dict[str, object] = {}
    layout_counts: dict[str, int] = {}
    scenario_records: dict[str, object] = {}

    for raw_scenario in base_plan["syntheticScenarios"]:
        scenario_id = str(raw_scenario["id"])
        frames = scenario_frames(raw_scenario, native_images, tile_plan)
        scenario_records[scenario_id] = scenario_summary(raw_scenario, frames)
        layouts_by_profile_replay: dict[tuple[str, int], tuple] = {}
        for profile in profiles:
            weights = access_weights(profile, len(frames))
            for replay_limit in replay_limits:
                layouts = tile_model.candidate_layouts(
                    frame_count=len(frames),
                    access_weights=weights,
                    maximum_replay_frames=replay_limit,
                )
                layouts_by_profile_replay[(str(profile["id"]), replay_limit)] = layouts
                layout_counts[
                    f"{scenario_id}/{profile['id']}/{replay_limit}"
                ] = len(layouts)

        for tile_size in tile_plan["tileSizes"]:
            geometry = tile_model.TileGeometry(
                int(raw_scenario["canvasWidth"]),
                int(raw_scenario["canvasHeight"]),
                int(tile_size),
            )
            trace = tile_model.build_trace(geometry, frames)
            for profile in profiles:
                profile_id = str(profile["id"])
                weights = access_weights(profile, len(frames))
                for replay_limit in replay_limits:
                    layouts = layouts_by_profile_replay[(profile_id, replay_limit)]
                    for strategy in strategies:
                        strategy_id = str(strategy["id"])
                        retain_raw = bool(strategy["retainRawSubrects"])
                        retained_source = (
                            0 if retain_raw else int(raw_scenario["encodedSourceBytes"])
                        )
                        candidates = [
                            tile_model.build_plan(
                                trace=trace,
                                checkpoint_starts=starts,
                                access_weights=weights,
                                maximum_replay_frames=replay_limit,
                                layout_family=family,
                                retain_raw_subrects=retain_raw,
                                retained_source_bytes=retained_source,
                                root_entry_bytes=root_entry_bytes,
                                root_header_bytes=root_header_bytes,
                            )
                            for family, starts in layouts
                        ]
                        for budget in budgets:
                            eligible = [
                                candidate
                                for candidate in candidates
                                if candidate.retained_bytes <= budget
                            ]
                            row: dict[str, object] = {
                                "scenarioID": scenario_id,
                                "tileSize": int(tile_size),
                                "accessProfileID": profile_id,
                                "retentionStrategyID": strategy_id,
                                "retainedBudgetBytes": budget,
                                "maximumReplayFrames": replay_limit,
                                "candidateLayoutCount": len(candidates),
                            }
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
                                row["status"] = "feasible-candidate"
                                row["selectedPlan"] = compact_plan(selected)
                                if budget == reference_budget and replay_limit == reference_replay:
                                    frontier = tile_model.pareto_frontier(eligible)
                                    key = "/".join(
                                        (
                                            scenario_id,
                                            str(tile_size),
                                            profile_id,
                                            strategy_id,
                                        )
                                    )
                                    reference_frontiers[key] = [
                                        compact_plan(item) for item in frontier
                                    ]
                            else:
                                minimum_retained = min(
                                    candidate.retained_bytes for candidate in candidates
                                )
                                row["status"] = "no-feasible-candidate"
                                row["minimumCandidateRetainedBytes"] = minimum_retained
                                row["reason"] = (
                                    "every preregistered tile layout exceeds the retained-byte budget"
                                )
                            matrix.append(row)

    feasible = [row for row in matrix if row["status"] == "feasible-candidate"]
    reference_rows = [
        row
        for row in matrix
        if row["retainedBudgetBytes"] == reference_budget
        and row["maximumReplayFrames"] == reference_replay
    ]
    reference_feasible = [
        row for row in reference_rows if row["status"] == "feasible-candidate"
    ]
    hard_cap = int(base_plan["boundImplementationPolicies"]["foveaAnimationFrameMemoryHardCap"])
    reference_peak_within_hard_cap = [
        row
        for row in reference_feasible
        if row["selectedPlan"]["modeledPeakBytesUpperBound"] <= hard_cap
    ]
    scenario_case_counts: dict[str, dict[str, int]] = {}
    for scenario_id in scenario_records:
        rows = [row for row in reference_rows if row["scenarioID"] == scenario_id]
        count = sum(row["status"] == "feasible-candidate" for row in rows)
        scenario_case_counts[scenario_id] = {
            "feasibleCandidate": count,
            "noFeasibleCandidate": len(rows) - count,
        }
    tile_case_counts: dict[str, dict[str, int]] = {}
    for tile_size in tile_plan["tileSizes"]:
        rows = [row for row in reference_rows if row["tileSize"] == tile_size]
        count = sum(row["status"] == "feasible-candidate" for row in rows)
        tile_case_counts[str(tile_size)] = {
            "feasibleCandidate": count,
            "noFeasibleCandidate": len(rows) - count,
        }

    return {
        "schemaVersion": 1,
        "scenarioSummaries": scenario_records,
        "matrix": matrix,
        "referencePolicyFrontiers": reference_frontiers,
        "candidateLayoutCounts": layout_counts,
        "summary": {
            "matrixCaseCount": len(matrix),
            "feasibleCandidateCaseCount": len(feasible),
            "noFeasibleCandidateCaseCount": len(matrix) - len(feasible),
            "referencePolicyCaseCount": len(reference_rows),
            "referencePolicyFeasibleCandidateCaseCount": len(reference_feasible),
            "referencePolicyNoFeasibleCandidateCaseCount": len(reference_rows)
            - len(reference_feasible),
            "referencePolicyPeakWithinFoveaHardCapCount": len(
                reference_peak_within_hard_cap
            ),
            "referencePolicyFeasibleCandidateCombinations": [
                {
                    "scenarioID": scenario_id,
                    "tileSize": tile_size,
                    "retentionStrategyID": strategy_id,
                }
                for scenario_id, tile_size, strategy_id in sorted(
                    {
                        (
                            str(row["scenarioID"]),
                            int(row["tileSize"]),
                            str(row["retentionStrategyID"]),
                        )
                        for row in reference_feasible
                    }
                )
            ],
            "referencePolicyScenariosWithAnyFeasibleCandidate": sorted(
                identifier
                for identifier, counts in scenario_case_counts.items()
                if counts["feasibleCandidate"] > 0
            ),
            "referencePolicyScenariosWithNoFeasibleCandidate": sorted(
                identifier
                for identifier, counts in scenario_case_counts.items()
                if counts["feasibleCandidate"] == 0
            ),
            "referencePolicyScenarioCaseCounts": scenario_case_counts,
            "referencePolicyTileSizeCaseCounts": tile_case_counts,
            "candidateFamilyGlobalOptimalityClaim": False,
        },
        "claimBoundary": tile_plan["modelBoundary"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--plan",
        type=pathlib.Path,
        default=ROOT / "Benchmarks/ComparativeLab/apng-tile-checkpoint-plan.json",
    )
    parser.add_argument("--base-plan", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    tile_plan_path = args.plan.resolve()
    tile_plan = json.loads(tile_plan_path.read_text())
    validate_tile_plan(tile_plan)
    base_plan_path = (
        args.base_plan.resolve()
        if args.base_plan is not None
        else (ROOT / str(tile_plan["basePlan"])).resolve()
    )
    base_plan = json.loads(base_plan_path.read_text())
    base_capture.validate_plan(base_plan)

    fixture_root = (ROOT / str(base_plan["sourceFixtureRoot"])).resolve()
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
        raise SystemExit("APNGKit fixture checkout must match the clean exact commit")
    policy_sources_before = base_capture.validate_policy_sources(imagecraft_root)

    governing_paths = {
        "tilePlan": tile_plan_path,
        "basePlan": base_plan_path,
        "tileModel": PERFORMANCE / "w5_apng_tile_checkpoint_model.py",
        "tileModelTests": PERFORMANCE / "test_w5_apng_tile_checkpoint_model.py",
        "captureRunner": pathlib.Path(__file__).resolve(),
        "validator": PERFORMANCE / "validate_w5_apng_tile_checkpoint_model.py",
        "captureContract": PERFORMANCE / "test_w5_apng_tile_checkpoint_capture.py",
        "ownedReference": PERFORMANCE / "w5_apng_reference.py",
        "ownedReferenceTests": PERFORMANCE / "test_w5_apng_reference.py",
        "fullCanvasModel": PERFORMANCE / "w5_apng_checkpoint_model.py",
        "fullCanvasStudy": ROOT / "docs/research/w5-apng-checkpoint-model-2026-08.json",
        "ownedReferenceStudy": ROOT / "docs/research/w5-apng-owned-reference-2026-08.json",
    }
    governing_before = {
        name: support.file_identity(path) for name, path in governing_paths.items()
    }

    fixture_contracts = {
        str(item["id"]): item for item in base_plan["sourceFixtures"]
    }
    source_inputs = {
        identifier: fixture_root / str(contract["relativePath"])
        for identifier, contract in fixture_contracts.items()
    }
    for identifier, path in source_inputs.items():
        if not path.is_file():
            raise SystemExit(f"missing APNG fixture {identifier}: {path}")
    inputs_before = {
        identifier: support.file_identity(path)
        for identifier, path in source_inputs.items()
    }

    retained_tile_plan = output / "tile-plan.json"
    retained_base_plan = output / "base-plan.json"
    shutil.copyfile(tile_plan_path, retained_tile_plan)
    shutil.copyfile(base_plan_path, retained_base_plan)
    inputs_directory = output / "inputs"
    inputs_directory.mkdir()
    retained_inputs: dict[str, dict[str, object]] = {}
    native_images = {}
    for identifier, source_path in source_inputs.items():
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
        "tilePlan": support.file_identity(retained_tile_plan),
        "basePlan": support.file_identity(retained_base_plan),
        "inputs": retained_inputs,
        "claimBoundary": tile_plan["modelBoundary"],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(
        json.dumps(source_identity, indent=2, sort_keys=True) + "\n"
    )

    analysis = analyze(tile_plan, base_plan, native_images)
    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APNG-TILE-CHECKPOINT-CANDIDATE-SOURCE-BOUND-2026-08",
        "formalClaimEligible": False,
        "sourceIdentity": support.file_identity(source_identity_path),
        "tilePlan": support.file_identity(retained_tile_plan),
        "basePlan": support.file_identity(retained_base_plan),
        "analysis": analysis,
    }
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    source_after = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(imagecraft_root),
        "APNGKit": support.git_snapshot(apngkit_root),
    }
    inputs_after = {
        identifier: support.file_identity(path)
        for identifier, path in source_inputs.items()
    }
    policy_sources_after = base_capture.validate_policy_sources(imagecraft_root)
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
        "tilePlan": support.file_identity(retained_tile_plan),
        "basePlan": support.file_identity(retained_base_plan),
        "report": support.file_identity(report_path),
        "validatorCommand": [
            sys.executable,
            str(PERFORMANCE / "validate_w5_apng_tile_checkpoint_model.py"),
            str(output),
        ],
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    for flag in (
        "sourceUnchangedDuringCapture",
        "inputSourcesUnchangedDuringCapture",
        "policySourcesUnchangedDuringCapture",
        "governingFilesUnchangedDuringCapture",
    ):
        if not manifest[flag]:
            raise SystemExit(f"APNG tile capture did not preserve {flag}: {manifest_path}")
    support.run(manifest["validatorCommand"], ROOT)
    print(report_path)


if __name__ == "__main__":
    main()
