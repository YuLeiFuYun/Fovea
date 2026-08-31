#!/usr/bin/env python3
"""Deterministic byte/replay model for an owned APNG checkpoint compositor.

This is an analytical design tool, not a runtime measurement. A checkpoint start denotes
the pre-frame canvas state used to render that frame. Frame zero normally uses an implicit
transparent canvas, so it costs working memory but no retained checkpoint bytes. Raw frame
payloads are modeled as decoded subrect RGBA. Rendering target frame i replays frames from
the latest checkpoint start through i inclusive.
"""

from __future__ import annotations

import dataclasses
import math
from typing import Sequence


class CheckpointModelError(ValueError):
    pass


@dataclasses.dataclass(frozen=True)
class FrameFootprint:
    subrect_rgba_bytes: int
    disposal_previous: bool = False

    def __post_init__(self) -> None:
        if self.subrect_rgba_bytes <= 0:
            raise CheckpointModelError("frame subrect bytes must be positive")


@dataclasses.dataclass(frozen=True)
class CheckpointPlan:
    frame_count: int
    canvas_rgba_bytes: int
    checkpoint_starts: tuple[int, ...]
    replay_frames_by_target: tuple[int, ...]
    retained_raw_subrect_bytes: int
    retained_checkpoint_bytes: int
    retained_source_bytes: int
    compositor_working_bytes_upper_bound: int
    materialized_output_bytes: int
    modeled_peak_bytes_upper_bound: int
    expected_replay_frames: float
    p95_replay_frames: int
    worst_replay_frames: int
    access_weight_sum: float
    retain_raw_subrects: bool
    max_replay_constraint: int
    implicit_initial_checkpoint: bool

    @property
    def checkpoint_count(self) -> int:
        return len(self.checkpoint_starts)

    @property
    def retained_checkpoint_count(self) -> int:
        return self.checkpoint_count - int(self.implicit_initial_checkpoint)

    @property
    def retained_bytes(self) -> int:
        return (
            self.retained_raw_subrect_bytes
            + self.retained_checkpoint_bytes
            + self.retained_source_bytes
        )

    def to_dict(self) -> dict[str, object]:
        return dataclasses.asdict(self) | {
            "checkpoint_count": self.checkpoint_count,
            "retained_checkpoint_count": self.retained_checkpoint_count,
            "retained_bytes": self.retained_bytes,
        }


def _validate_common(
    frames: Sequence[FrameFootprint],
    canvas_rgba_bytes: int,
    access_weights: Sequence[float],
    max_replay_frames: int,
    retained_source_bytes: int,
) -> None:
    if not frames:
        raise CheckpointModelError("at least one frame is required")
    if canvas_rgba_bytes <= 0:
        raise CheckpointModelError("canvas bytes must be positive")
    if any(frame.subrect_rgba_bytes > canvas_rgba_bytes for frame in frames):
        raise CheckpointModelError("frame subrect bytes cannot exceed canvas bytes")
    if len(access_weights) != len(frames):
        raise CheckpointModelError("access weight count must equal frame count")
    if any(not math.isfinite(weight) or weight < 0 for weight in access_weights):
        raise CheckpointModelError("access weights must be finite and nonnegative")
    if sum(access_weights) <= 0:
        raise CheckpointModelError("access weights must have positive total")
    if max_replay_frames <= 0:
        raise CheckpointModelError("max replay frames must be positive")
    if retained_source_bytes < 0:
        raise CheckpointModelError("retained source bytes must be nonnegative")


def _segment_cost(weights: Sequence[float], start: int, end: int) -> float:
    return sum(weights[target] * (target - start + 1) for target in range(start, end))


def _optimal_checkpoint_starts(
    weights: Sequence[float],
    checkpoint_count: int,
    max_replay_frames: int,
) -> tuple[int, ...]:
    frame_count = len(weights)
    if checkpoint_count <= 0 or checkpoint_count > frame_count:
        raise CheckpointModelError("checkpoint count is outside frame range")
    if checkpoint_count * max_replay_frames < frame_count:
        raise CheckpointModelError("checkpoint count cannot satisfy max replay constraint")

    infinity = float("inf")
    costs = [[infinity] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    previous = [[-1] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    costs[0][0] = 0.0
    for segments in range(1, checkpoint_count + 1):
        minimum_end = segments
        maximum_end = min(frame_count, segments * max_replay_frames)
        for end in range(minimum_end, maximum_end + 1):
            minimum_start = max(segments - 1, end - max_replay_frames)
            maximum_start = end - 1
            for start in range(minimum_start, maximum_start + 1):
                prefix = costs[segments - 1][start]
                if not math.isfinite(prefix):
                    continue
                candidate = prefix + _segment_cost(weights, start, end)
                if candidate < costs[segments][end] - 1e-12:
                    costs[segments][end] = candidate
                    previous[segments][end] = start
                elif math.isclose(candidate, costs[segments][end], rel_tol=0, abs_tol=1e-12):
                    prior_start = previous[segments][end]
                    if prior_start < 0 or start < prior_start:
                        previous[segments][end] = start
    if not math.isfinite(costs[checkpoint_count][frame_count]):
        raise CheckpointModelError("no checkpoint layout satisfies constraints")

    starts: list[int] = []
    end = frame_count
    for segments in range(checkpoint_count, 0, -1):
        start = previous[segments][end]
        if start < 0:
            raise CheckpointModelError("checkpoint plan reconstruction failed")
        starts.append(start)
        end = start
    starts.reverse()
    if starts[0] != 0:
        raise CheckpointModelError("first checkpoint must start at frame zero")
    return tuple(starts)


def _optimal_checkpoint_starts_with_semantics(
    weights: Sequence[float],
    checkpoint_count: int,
    max_replay_frames: int,
    semantic_replay_starts: Sequence[int],
) -> tuple[int, ...]:
    frame_count = len(weights)
    if checkpoint_count <= 0 or checkpoint_count > frame_count:
        raise CheckpointModelError("checkpoint count is outside frame range")
    if len(semantic_replay_starts) != frame_count:
        raise CheckpointModelError("semantic replay start count must equal frame count")
    for target, semantic_start in enumerate(semantic_replay_starts):
        if semantic_start < 0 or semantic_start > target:
            raise CheckpointModelError("semantic replay start must be within target prefix")

    infinity = float("inf")
    costs = [[infinity] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    previous = [[-1] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    costs[0][0] = 0.0
    for segments in range(1, checkpoint_count + 1):
        for end in range(segments, frame_count + 1):
            for start in range(segments - 1, end):
                prefix = costs[segments - 1][start]
                if not math.isfinite(prefix):
                    continue
                replay_values = tuple(
                    target - max(start, semantic_replay_starts[target]) + 1
                    for target in range(start, end)
                )
                if max(replay_values, default=0) > max_replay_frames:
                    continue
                candidate = prefix + sum(
                    weights[target] * replay
                    for target, replay in zip(range(start, end), replay_values)
                )
                if candidate < costs[segments][end] - 1e-12:
                    costs[segments][end] = candidate
                    previous[segments][end] = start
                elif math.isclose(candidate, costs[segments][end], rel_tol=0, abs_tol=1e-12):
                    prior_start = previous[segments][end]
                    if prior_start < 0 or start < prior_start:
                        previous[segments][end] = start
    if not math.isfinite(costs[checkpoint_count][frame_count]):
        raise CheckpointModelError("no checkpoint layout satisfies constraints")

    starts: list[int] = []
    end = frame_count
    for segments in range(checkpoint_count, 0, -1):
        start = previous[segments][end]
        if start < 0:
            raise CheckpointModelError("checkpoint plan reconstruction failed")
        starts.append(start)
        end = start
    starts.reverse()
    if starts[0] != 0:
        raise CheckpointModelError("first checkpoint must start at frame zero")
    return tuple(starts)


def _replay_by_target(
    frame_count: int,
    checkpoint_starts: Sequence[int],
    semantic_replay_starts: Sequence[int] | None = None,
) -> tuple[int, ...]:
    if not checkpoint_starts or checkpoint_starts[0] != 0:
        raise CheckpointModelError("checkpoint starts must begin at frame zero")
    if tuple(checkpoint_starts) != tuple(sorted(set(checkpoint_starts))):
        raise CheckpointModelError("checkpoint starts must be unique and increasing")
    if checkpoint_starts[-1] >= frame_count:
        raise CheckpointModelError("checkpoint start is outside frame range")
    if semantic_replay_starts is None:
        semantic_replay_starts = tuple(0 for _ in range(frame_count))
    if len(semantic_replay_starts) != frame_count:
        raise CheckpointModelError("semantic replay start count must equal frame count")
    for target, start in enumerate(semantic_replay_starts):
        if start < 0 or start > target:
            raise CheckpointModelError("semantic replay start must be within target prefix")

    starts = iter(checkpoint_starts)
    current = next(starts)
    following = next(starts, None)
    replay: list[int] = []
    for target in range(frame_count):
        while following is not None and target >= following:
            current = following
            following = next(starts, None)
        effective_start = max(current, semantic_replay_starts[target])
        replay.append(target - effective_start + 1)
    return tuple(replay)


def _weighted_quantile(values: Sequence[int], weights: Sequence[float], quantile: float) -> int:
    if not 0 < quantile <= 1:
        raise CheckpointModelError("quantile must be in (0, 1]")
    total = sum(weights)
    threshold = total * quantile
    cumulative = 0.0
    for value, weight in sorted(zip(values, weights), key=lambda item: item[0]):
        cumulative += weight
        if cumulative + 1e-15 >= threshold:
            return value
    return max(values)


def _build_plan_for_starts(
    *,
    frames: Sequence[FrameFootprint],
    canvas_rgba_bytes: int,
    access_weights: Sequence[float],
    checkpoint_starts: tuple[int, ...],
    retain_raw_subrects: bool,
    retained_source_bytes: int,
    max_replay_frames: int,
    implicit_initial_checkpoint: bool,
    semantic_replay_starts: Sequence[int] | None = None,
) -> CheckpointPlan:
    replay = _replay_by_target(
        len(frames), checkpoint_starts, semantic_replay_starts
    )
    if max(replay) > max_replay_frames:
        raise CheckpointModelError("checkpoint layout exceeds maximum replay constraint")
    raw_bytes = sum(frame.subrect_rgba_bytes for frame in frames) if retain_raw_subrects else 0
    retained_checkpoint_count = len(checkpoint_starts) - int(implicit_initial_checkpoint)
    if retained_checkpoint_count < 0:
        raise CheckpointModelError("invalid implicit checkpoint accounting")
    checkpoint_bytes = retained_checkpoint_count * canvas_rgba_bytes
    access_weight_sum = sum(access_weights)
    expected_replay = sum(
        value * weight for value, weight in zip(replay, access_weights)
    ) / access_weight_sum
    maximum_subrect = max(frame.subrect_rgba_bytes for frame in frames)
    maximum_previous = max(
        (frame.subrect_rgba_bytes for frame in frames if frame.disposal_previous),
        default=0,
    )
    working = canvas_rgba_bytes + maximum_subrect + maximum_previous
    materialized_output = canvas_rgba_bytes
    modeled_peak = (
        raw_bytes
        + retained_source_bytes
        + checkpoint_bytes
        + working
        + materialized_output
    )
    return CheckpointPlan(
        frame_count=len(frames),
        canvas_rgba_bytes=canvas_rgba_bytes,
        checkpoint_starts=checkpoint_starts,
        replay_frames_by_target=replay,
        retained_raw_subrect_bytes=raw_bytes,
        retained_checkpoint_bytes=checkpoint_bytes,
        retained_source_bytes=retained_source_bytes,
        compositor_working_bytes_upper_bound=working,
        materialized_output_bytes=materialized_output,
        modeled_peak_bytes_upper_bound=modeled_peak,
        expected_replay_frames=expected_replay,
        p95_replay_frames=_weighted_quantile(replay, access_weights, 0.95),
        worst_replay_frames=max(replay),
        access_weight_sum=access_weight_sum,
        retain_raw_subrects=retain_raw_subrects,
        max_replay_constraint=max_replay_frames,
        implicit_initial_checkpoint=implicit_initial_checkpoint,
    )


def build_pareto_frontier(
    *,
    frames: Sequence[FrameFootprint],
    canvas_rgba_bytes: int,
    access_weights: Sequence[float],
    retained_budget_bytes: int,
    max_replay_frames: int,
    retain_raw_subrects: bool = True,
    retained_source_bytes: int = 0,
    implicit_initial_checkpoint: bool = True,
    semantic_replay_starts: Sequence[int] | None = None,
) -> tuple[CheckpointPlan, ...]:
    _validate_common(
        frames,
        canvas_rgba_bytes,
        access_weights,
        max_replay_frames,
        retained_source_bytes,
    )
    if retained_budget_bytes < 0:
        raise CheckpointModelError("retained budget must be nonnegative")
    raw_bytes = sum(frame.subrect_rgba_bytes for frame in frames) if retain_raw_subrects else 0
    base_bytes = raw_bytes + retained_source_bytes
    if base_bytes > retained_budget_bytes:
        raise CheckpointModelError("retained budget cannot hold source/raw state")

    stored_checkpoint_capacity = (retained_budget_bytes - base_bytes) // canvas_rgba_bytes
    maximum_checkpoints = min(
        len(frames),
        stored_checkpoint_capacity + int(implicit_initial_checkpoint),
    )
    minimum_checkpoints = (
        1
        if semantic_replay_starts is not None
        else math.ceil(len(frames) / max_replay_frames)
    )
    if maximum_checkpoints < minimum_checkpoints:
        raise CheckpointModelError(
            "retained budget cannot satisfy the maximum replay constraint"
        )

    candidates: list[CheckpointPlan] = []
    for checkpoint_count in range(minimum_checkpoints, maximum_checkpoints + 1):
        try:
            starts = (
                _optimal_checkpoint_starts(
                    access_weights, checkpoint_count, max_replay_frames
                )
                if semantic_replay_starts is None
                else _optimal_checkpoint_starts_with_semantics(
                    access_weights,
                    checkpoint_count,
                    max_replay_frames,
                    semantic_replay_starts,
                )
            )
        except CheckpointModelError:
            continue
        candidates.append(
            _build_plan_for_starts(
                frames=frames,
                canvas_rgba_bytes=canvas_rgba_bytes,
                access_weights=access_weights,
                checkpoint_starts=starts,
                retain_raw_subrects=retain_raw_subrects,
                retained_source_bytes=retained_source_bytes,
                max_replay_frames=max_replay_frames,
                implicit_initial_checkpoint=implicit_initial_checkpoint,
                semantic_replay_starts=semantic_replay_starts,
            )
        )

    frontier: list[CheckpointPlan] = []
    for candidate in candidates:
        dominated = False
        for prior in frontier:
            no_worse = (
                prior.retained_bytes <= candidate.retained_bytes
                and prior.expected_replay_frames <= candidate.expected_replay_frames + 1e-12
                and prior.p95_replay_frames <= candidate.p95_replay_frames
                and prior.worst_replay_frames <= candidate.worst_replay_frames
            )
            strictly_better = (
                prior.retained_bytes < candidate.retained_bytes
                or prior.expected_replay_frames < candidate.expected_replay_frames - 1e-12
                or prior.p95_replay_frames < candidate.p95_replay_frames
                or prior.worst_replay_frames < candidate.worst_replay_frames
            )
            if no_worse and strictly_better:
                dominated = True
                break
        if not dominated:
            frontier.append(candidate)
    if not frontier:
        raise CheckpointModelError("checkpoint frontier is empty")
    return tuple(frontier)


def build_plan(
    *,
    frames: Sequence[FrameFootprint],
    canvas_rgba_bytes: int,
    access_weights: Sequence[float],
    retained_budget_bytes: int,
    max_replay_frames: int,
    retain_raw_subrects: bool = True,
    retained_source_bytes: int = 0,
    implicit_initial_checkpoint: bool = True,
    semantic_replay_starts: Sequence[int] | None = None,
) -> CheckpointPlan:
    frontier = build_pareto_frontier(
        frames=frames,
        canvas_rgba_bytes=canvas_rgba_bytes,
        access_weights=access_weights,
        retained_budget_bytes=retained_budget_bytes,
        max_replay_frames=max_replay_frames,
        retain_raw_subrects=retain_raw_subrects,
        retained_source_bytes=retained_source_bytes,
        implicit_initial_checkpoint=implicit_initial_checkpoint,
        semantic_replay_starts=semantic_replay_starts,
    )
    return min(
        frontier,
        key=lambda plan: (
            plan.expected_replay_frames,
            plan.p95_replay_frames,
            plan.worst_replay_frames,
            plan.retained_bytes,
            plan.checkpoint_starts,
        ),
    )


def build_fixed_interval_plan(
    *,
    frames: Sequence[FrameFootprint],
    canvas_rgba_bytes: int,
    access_weights: Sequence[float],
    checkpoint_interval: int,
    retain_raw_subrects: bool = True,
    retained_source_bytes: int = 0,
    implicit_initial_checkpoint: bool = True,
    semantic_replay_starts: Sequence[int] | None = None,
) -> CheckpointPlan:
    if checkpoint_interval <= 0:
        raise CheckpointModelError("checkpoint interval must be positive")
    _validate_common(
        frames,
        canvas_rgba_bytes,
        access_weights,
        checkpoint_interval,
        retained_source_bytes,
    )
    starts = tuple(range(0, len(frames), checkpoint_interval))
    return _build_plan_for_starts(
        frames=frames,
        canvas_rgba_bytes=canvas_rgba_bytes,
        access_weights=access_weights,
        checkpoint_starts=starts,
        retain_raw_subrects=retain_raw_subrects,
        retained_source_bytes=retained_source_bytes,
        max_replay_frames=checkpoint_interval,
        implicit_initial_checkpoint=implicit_initial_checkpoint,
        semantic_replay_starts=semantic_replay_starts,
    )


def uniform_weights(frame_count: int) -> tuple[float, ...]:
    if frame_count <= 0:
        raise CheckpointModelError("frame count must be positive")
    return (1.0,) * frame_count


def tail_hot_weights(
    frame_count: int,
    tail_fraction: float = 0.25,
    tail_weight: float = 4.0,
) -> tuple[float, ...]:
    if frame_count <= 0:
        raise CheckpointModelError("frame count must be positive")
    if not 0 < tail_fraction <= 1 or not math.isfinite(tail_weight) or tail_weight <= 0:
        raise CheckpointModelError("invalid tail-hot parameters")
    tail_start = max(0, frame_count - math.ceil(frame_count * tail_fraction))
    return tuple(tail_weight if index >= tail_start else 1.0 for index in range(frame_count))


def repeat_footprints(
    frames: Sequence[FrameFootprint],
    frame_count: int,
) -> tuple[FrameFootprint, ...]:
    if not frames or frame_count <= 0:
        raise CheckpointModelError("repeat requires nonempty frames and positive count")
    return tuple(frames[index % len(frames)] for index in range(frame_count))
