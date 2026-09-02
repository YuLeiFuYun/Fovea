#!/usr/bin/env python3
"""Source-bound YYImage semantic replay oracle for the Fovea APNG checkpoint model."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/Performance"))

import w5_apng_checkpoint_model as checkpoint

PLAN = ROOT / "Benchmarks/ComparativeLab/apng-semantic-replay-plan.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/w5-yyimage-semantic-replay-v1/report.json"
MIB = 1024 * 1024


class SemanticReplayOracleError(ValueError):
    pass


@dataclass(frozen=True)
class FrameSemantics:
    is_full_canvas: bool
    blend_source: bool
    disposal: str
    subrect_rgba_bytes: int


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def git(command: list[str], *, cwd: Path) -> str:
    return subprocess.run(
        ["git", *command], cwd=cwd, text=True, capture_output=True, check=True
    ).stdout.strip()


def validate_source_identity(plan: dict[str, Any]) -> dict[str, Any]:
    oracle = plan["sourceOracle"]
    root = ROOT / oracle["root"]
    source = root / oracle["sourceFile"]
    commit = git(["rev-parse", "HEAD"], cwd=root)
    status = git(["status", "--porcelain=v1"], cwd=root)
    source_sha = sha256_file(source)
    if commit != oracle["exactCommit"]:
        raise SemanticReplayOracleError(
            f"YYImage commit mismatch: expected {oracle['exactCommit']} got {commit}"
        )
    if status:
        raise SemanticReplayOracleError("YYImage retained source must be clean")
    if source_sha != oracle["sourceFileSHA256"]:
        raise SemanticReplayOracleError("YYImageCoder.m SHA256 mismatch")
    text = source.read_text(errors="strict")
    required = [
        "frame.blendFromIndex  = i;",
        "if (frame.dispose != YYImageDisposePrevious) lastBlendIndex = i;",
        "frame.dispose == YYImageDisposeBackground && frame.isFullSize",
        "lastBlendIndex = i + 1;",
        "frame.blendFromIndex = lastBlendIndex;",
    ]
    missing = [fragment for fragment in required if fragment not in text]
    if missing:
        raise SemanticReplayOracleError(f"YYImage semantic source fragments missing: {missing}")
    return {
        "name": oracle["name"],
        "version": oracle["version"],
        "commit": commit,
        "workingTreeClean": True,
        "sourceFile": oracle["sourceFile"],
        "sourceFileSHA256": source_sha,
        "algorithm": oracle["algorithm"],
    }


def frame_semantics_from_report_frame(frame: dict[str, Any]) -> FrameSemantics:
    rect = frame["imageCraftDescriptorRect"]
    full = (
        int(rect["x"]) == 0
        and int(rect["y"]) == 0
        and int(rect["width"]) == int(frame["imageCraftWidth"])
        and int(rect["height"]) == int(frame["imageCraftHeight"])
    )
    disposal = str(frame["imageCraftDisposal"])
    if disposal not in {"none", "background", "previous"}:
        raise SemanticReplayOracleError(f"unsupported disposal {disposal}")
    blend = str(frame["imageCraftBlend"])
    if blend not in {"source", "over"}:
        raise SemanticReplayOracleError(f"unsupported blend {blend}")
    return FrameSemantics(
        is_full_canvas=full,
        blend_source=blend == "source",
        disposal=disposal,
        subrect_rgba_bytes=int(frame["imageCraftSubrectRGBAByteCount"]),
    )


def yyimage_semantic_replay_starts(frames: Iterable[FrameSemantics]) -> tuple[int, ...]:
    last_blend_index = 0
    starts: list[int] = []
    for index, frame in enumerate(frames):
        if frame.blend_source and frame.is_full_canvas:
            blend_from_index = index
            if frame.disposal != "previous":
                last_blend_index = index
        elif frame.disposal == "background" and frame.is_full_canvas:
            blend_from_index = last_blend_index
            last_blend_index = index + 1
        else:
            blend_from_index = last_blend_index
        if not 0 <= blend_from_index <= index:
            raise SemanticReplayOracleError(
                f"derived replay start outside target prefix: frame={index} start={blend_from_index}"
            )
        starts.append(blend_from_index)
    return tuple(starts)


def repeat_semantics(pattern: tuple[FrameSemantics, ...], frame_count: int) -> tuple[FrameSemantics, ...]:
    if not pattern or frame_count <= 0:
        raise SemanticReplayOracleError("semantic repeat requires nonempty pattern")
    return tuple(pattern[index % len(pattern)] for index in range(frame_count))


def scaled_footprints(
    pattern: tuple[FrameSemantics, ...], frame_count: int, canvas_bytes: int, native_canvas_bytes: int
) -> tuple[checkpoint.FrameFootprint, ...]:
    repeated = repeat_semantics(pattern, frame_count)
    result = []
    for frame in repeated:
        scaled = int(round((frame.subrect_rgba_bytes / native_canvas_bytes) * canvas_bytes / 4)) * 4
        result.append(
            checkpoint.FrameFootprint(
                min(canvas_bytes, max(4, scaled)),
                disposal_previous=frame.disposal == "previous",
            )
        )
    return tuple(result)


def compact_plan(plan: checkpoint.CheckpointPlan) -> dict[str, Any]:
    return {
        "checkpointStarts": list(plan.checkpoint_starts),
        "checkpointCount": plan.checkpoint_count,
        "retainedCheckpointCount": plan.retained_checkpoint_count,
        "retainedCheckpointBytes": plan.retained_checkpoint_bytes,
        "retainedBytes": plan.retained_bytes,
        "modeledPeakBytesUpperBound": plan.modeled_peak_bytes_upper_bound,
        "expectedReplayFrames": plan.expected_replay_frames,
        "p95ReplayFrames": plan.p95_replay_frames,
        "worstReplayFrames": plan.worst_replay_frames,
        "replayFramesByTarget": list(plan.replay_frames_by_target),
    }


def maybe_plan(**kwargs: Any) -> tuple[dict[str, Any] | None, str | None]:
    try:
        return compact_plan(checkpoint.build_plan(**kwargs)), None
    except checkpoint.CheckpointModelError as error:
        return None, str(error)


def compare_same_layout(
    frames: tuple[checkpoint.FrameFootprint, ...],
    canvas_bytes: int,
    source_bytes: int,
    semantic_starts: tuple[int, ...],
) -> dict[str, Any]:
    common = dict(
        frames=frames,
        canvas_rgba_bytes=canvas_bytes,
        access_weights=checkpoint.uniform_weights(len(frames)),
        checkpoint_interval=len(frames),
        retain_raw_subrects=False,
        retained_source_bytes=source_bytes,
    )
    baseline = checkpoint.build_fixed_interval_plan(**common)
    semantic = checkpoint.build_fixed_interval_plan(
        **common, semantic_replay_starts=semantic_starts
    )
    if baseline.retained_bytes != semantic.retained_bytes:
        raise SemanticReplayOracleError("same-layout retained bytes changed")
    if baseline.modeled_peak_bytes_upper_bound != semantic.modeled_peak_bytes_upper_bound:
        raise SemanticReplayOracleError("same-layout modeled peak changed")
    if any(after > before for before, after in zip(baseline.replay_frames_by_target, semantic.replay_frames_by_target)):
        raise SemanticReplayOracleError("semantic replay regressed a target")
    return {
        "baseline": compact_plan(baseline),
        "semantic": compact_plan(semantic),
        "strictReplayImprovement": semantic.replay_frames_by_target != baseline.replay_frames_by_target,
        "sameRetainedBytes": True,
        "sameModeledPeakBytes": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, default=PLAN)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    plan_path = args.plan if args.plan.is_absolute() else ROOT / args.plan
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    plan = load_json(plan_path)
    if plan.get("schemaVersion") != 1:
        raise SemanticReplayOracleError("semantic replay plan schema changed")
    source_identity = validate_source_identity(plan)
    composition_root = ROOT / plan["compositionEvidenceRoot"]

    report_by_fixture: dict[str, dict[str, Any]] = {}
    semantic_patterns: dict[str, tuple[FrameSemantics, ...]] = {}
    real_results: dict[str, Any] = {}
    evidence_hashes: dict[str, str] = {}
    for fixture_id in plan["realFixtureIDs"]:
        report_path = composition_root / f"{fixture_id}.json"
        report = load_json(report_path)
        evidence_hashes[str(report_path.relative_to(ROOT))] = sha256_file(report_path)
        if report.get("fixtureID") != fixture_id:
            raise SemanticReplayOracleError(f"composition fixture mismatch: {fixture_id}")
        frames = tuple(frame_semantics_from_report_frame(item) for item in report["frames"])
        semantic_patterns[fixture_id] = frames
        report_by_fixture[fixture_id] = report
        starts = yyimage_semantic_replay_starts(frames)
        footprints = tuple(
            checkpoint.FrameFootprint(
                frame.subrect_rgba_bytes,
                disposal_previous=frame.disposal == "previous",
            )
            for frame in frames
        )
        canvas_bytes = int(report["frames"][0]["imageCraftWidth"]) * int(
            report["frames"][0]["imageCraftHeight"]
        ) * 4
        real_results[fixture_id] = {
            "semanticReplayStarts": list(starts),
            "comparison": compare_same_layout(
                footprints, canvas_bytes, int(report["inputByteCount"]), starts
            ),
        }

    scenario_results: dict[str, Any] = {}
    max_replay = int(plan["maximumReplayFrames"])
    budgets = [int(value) * MIB for value in plan["retainedBudgetMiB"]]
    for raw in plan["syntheticScenarios"]:
        scenario_id = str(raw["id"])
        fixture_id = str(raw["patternFixture"])
        pattern = semantic_patterns[fixture_id]
        native_report = report_by_fixture[fixture_id]
        native_canvas = int(native_report["frames"][0]["imageCraftWidth"]) * int(
            native_report["frames"][0]["imageCraftHeight"]
        ) * 4
        frame_count = int(raw["frameCount"])
        canvas_bytes = int(raw["canvasWidth"]) * int(raw["canvasHeight"]) * 4
        semantics = repeat_semantics(pattern, frame_count)
        starts = yyimage_semantic_replay_starts(semantics)
        frames = scaled_footprints(pattern, frame_count, canvas_bytes, native_canvas)
        source_bytes = int(raw["encodedSourceBytes"])
        weights = checkpoint.uniform_weights(frame_count)
        rows = []
        for budget in budgets:
            common = dict(
                frames=frames,
                canvas_rgba_bytes=canvas_bytes,
                access_weights=weights,
                retained_budget_bytes=budget,
                max_replay_frames=max_replay,
                retain_raw_subrects=False,
                retained_source_bytes=source_bytes,
            )
            baseline, baseline_error = maybe_plan(**common)
            semantic, semantic_error = maybe_plan(
                **common, semantic_replay_starts=starts
            )
            row: dict[str, Any] = {
                "retainedBudgetBytes": budget,
                "baseline": baseline,
                "baselineError": baseline_error,
                "semantic": semantic,
                "semanticError": semantic_error,
            }
            if semantic is not None and baseline is not None:
                row["semanticNoWorse"] = (
                    semantic["retainedBytes"] <= baseline["retainedBytes"]
                    and semantic["modeledPeakBytesUpperBound"] <= baseline["modeledPeakBytesUpperBound"]
                    and semantic["expectedReplayFrames"] <= baseline["expectedReplayFrames"]
                    and semantic["p95ReplayFrames"] <= baseline["p95ReplayFrames"]
                    and semantic["worstReplayFrames"] <= baseline["worstReplayFrames"]
                )
                row["semanticStrictlyBetter"] = row["semanticNoWorse"] and (
                    semantic["retainedBytes"] < baseline["retainedBytes"]
                    or semantic["modeledPeakBytesUpperBound"] < baseline["modeledPeakBytesUpperBound"]
                    or semantic["expectedReplayFrames"] < baseline["expectedReplayFrames"]
                    or semantic["p95ReplayFrames"] < baseline["p95ReplayFrames"]
                    or semantic["worstReplayFrames"] < baseline["worstReplayFrames"]
                )
            elif semantic is not None and baseline is None:
                row["semanticNoWorse"] = True
                row["semanticStrictlyBetter"] = True
                row["feasibilityExpansion"] = True
            else:
                row["semanticNoWorse"] = semantic is None and baseline is None
                row["semanticStrictlyBetter"] = False
            rows.append(row)
        scenario_results[scenario_id] = {
            "patternFixture": fixture_id,
            "frameCount": frame_count,
            "canvasRGBABytes": canvas_bytes,
            "encodedSourceBytes": source_bytes,
            "semanticReplayStarts": list(starts),
            "semanticResetFrameCount": sum(index == start for index, start in enumerate(starts)),
            "budgets": rows,
        }

    real_strict = [
        fixture_id
        for fixture_id, item in real_results.items()
        if item["comparison"]["strictReplayImprovement"]
    ]
    synthetic_strict = [
        scenario_id
        for scenario_id, item in scenario_results.items()
        if any(row["semanticStrictlyBetter"] for row in item["budgets"])
    ]
    report = {
        "schemaVersion": 1,
        "studyID": plan["planID"],
        "status": "passed-source-bound-analytical-semantic-replay",
        "capturedAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "planPath": str(plan_path.relative_to(ROOT)),
        "planSHA256": sha256_file(plan_path),
        "sourceIdentity": source_identity,
        "compositionEvidenceSHA256": evidence_hashes,
        "modelPath": "Tools/Performance/w5_apng_checkpoint_model.py",
        "modelSHA256": sha256_file(ROOT / "Tools/Performance/w5_apng_checkpoint_model.py"),
        "maximumReplayFrames": max_replay,
        "retainedBudgetBytes": budgets,
        "realFixtureResults": real_results,
        "syntheticScenarioResults": scenario_results,
        "summary": {
            "realFixtureCount": len(real_results),
            "realFixturesWithStrictReplayImprovement": real_strict,
            "syntheticScenarioCount": len(scenario_results),
            "syntheticScenariosWithStrictImprovementOrFeasibilityExpansion": synthetic_strict,
            "allRealFixturesNonRegressingAtSameRetainedAndPeakBytes": all(
                item["comparison"]["sameRetainedBytes"]
                and item["comparison"]["sameModeledPeakBytes"]
                for item in real_results.values()
            ),
            "allComparableSyntheticRowsNonRegressing": all(
                row["semanticNoWorse"]
                for item in scenario_results.values()
                for row in item["budgets"]
            ),
        },
        "claimBoundary": plan["claimBoundary"],
    }
    report["canonicalSHA256"] = sha256_bytes(canonical_json_bytes(report))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "YYImage semantic replay oracle: "
        f"realStrict={real_strict} syntheticStrict={synthetic_strict} "
        f"artifact={output_path.relative_to(ROOT)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
