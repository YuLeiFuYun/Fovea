#!/usr/bin/env python3
"""Analytical compressed full-canvas checkpoint model for owned APNG composition.

A checkpoint stores the straight-alpha pre-frame canvas in a deterministic, checksummed
zlib blob. The synthetic model treats the blob size as an explicit sensitivity input;
it does not infer scaled compression ratios from the native fixtures. Frame zero retains
no blob because its transparent pre-frame state is implicit.
"""

from __future__ import annotations

import dataclasses
import functools
import math
import struct
import zlib
from typing import Sequence


MAGIC = b"FOVAPNG1"
HEADER = struct.Struct(">8sIIIII")
COMPRESSION_MODEL = "straight-alpha-zlib-level-9-checksummed-v1"


class CompressedCheckpointModelError(ValueError):
    pass


@dataclasses.dataclass(frozen=True)
class FrameFootprint:
    subrect_rgba_bytes: int
    disposal_previous: bool = False

    def __post_init__(self) -> None:
        if self.subrect_rgba_bytes <= 0:
            raise CompressedCheckpointModelError("frame subrect bytes must be positive")


@dataclasses.dataclass(frozen=True)
class CompressedCheckpointPlan:
    frame_count: int
    canvas_rgba_bytes: int
    checkpoint_blob_bytes: int
    checkpoint_starts: tuple[int, ...]
    replay_frames_by_target: tuple[int, ...]
    retained_raw_subrect_bytes: int
    retained_checkpoint_bytes: int
    retained_source_bytes: int
    decompressor_workspace_bytes: int
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


def checkpoint_blob_bytes_for_ratio(
    canvas_rgba_bytes: int,
    ratio_ppm: int,
    *,
    minimum_blob_bytes: int = HEADER.size + 8,
) -> int:
    if canvas_rgba_bytes <= 0:
        raise CompressedCheckpointModelError("canvas bytes must be positive")
    if ratio_ppm <= 0 or ratio_ppm > 1_000_000:
        raise CompressedCheckpointModelError("compression ratio ppm must be in 1...1000000")
    if minimum_blob_bytes < HEADER.size:
        raise CompressedCheckpointModelError("minimum blob bytes cannot be smaller than header")
    scaled = (canvas_rgba_bytes * ratio_ppm + 999_999) // 1_000_000
    return max(minimum_blob_bytes, scaled)


def encode_checkpoint_blob(
    straight_alpha_rgba: bytes,
    width: int,
    height: int,
    *,
    compression_level: int = 9,
) -> bytes:
    if width <= 0 or height <= 0:
        raise CompressedCheckpointModelError("checkpoint dimensions must be positive")
    expected = width * height * 4
    if len(straight_alpha_rgba) != expected:
        raise CompressedCheckpointModelError("checkpoint raw byte count mismatch")
    if compression_level < 0 or compression_level > 9:
        raise CompressedCheckpointModelError("zlib compression level must be in 0...9")
    payload = zlib.compress(straight_alpha_rgba, compression_level)
    checksum = zlib.crc32(straight_alpha_rgba) & 0xFFFFFFFF
    return HEADER.pack(
        MAGIC,
        width,
        height,
        expected,
        checksum,
        len(payload),
    ) + payload


def decode_checkpoint_blob(blob: bytes) -> tuple[int, int, bytes]:
    if len(blob) < HEADER.size:
        raise CompressedCheckpointModelError("checkpoint blob is truncated")
    magic, width, height, raw_count, checksum, payload_count = HEADER.unpack(
        blob[: HEADER.size]
    )
    if magic != MAGIC:
        raise CompressedCheckpointModelError("checkpoint blob magic mismatch")
    if width <= 0 or height <= 0 or raw_count != width * height * 4:
        raise CompressedCheckpointModelError("checkpoint blob geometry mismatch")
    payload = blob[HEADER.size :]
    if len(payload) != payload_count:
        raise CompressedCheckpointModelError("checkpoint payload byte count mismatch")
    try:
        raw = zlib.decompress(payload)
    except zlib.error as error:
        raise CompressedCheckpointModelError("checkpoint payload decompression failed") from error
    if len(raw) != raw_count:
        raise CompressedCheckpointModelError("checkpoint decoded byte count mismatch")
    if zlib.crc32(raw) & 0xFFFFFFFF != checksum:
        raise CompressedCheckpointModelError("checkpoint decoded checksum mismatch")
    return width, height, raw


def _validate_common(
    frames: Sequence[FrameFootprint],
    canvas_rgba_bytes: int,
    access_weights: Sequence[float],
    checkpoint_blob_bytes: int,
    max_replay_frames: int,
    retained_source_bytes: int,
    decompressor_workspace_bytes: int,
) -> None:
    if not frames:
        raise CompressedCheckpointModelError("at least one frame is required")
    if canvas_rgba_bytes <= 0 or checkpoint_blob_bytes <= 0:
        raise CompressedCheckpointModelError("canvas and checkpoint bytes must be positive")
    if any(frame.subrect_rgba_bytes > canvas_rgba_bytes for frame in frames):
        raise CompressedCheckpointModelError("frame subrect bytes cannot exceed canvas bytes")
    if len(access_weights) != len(frames):
        raise CompressedCheckpointModelError("access weight count must equal frame count")
    if any(not math.isfinite(weight) or weight < 0 for weight in access_weights):
        raise CompressedCheckpointModelError("access weights must be finite and nonnegative")
    if sum(access_weights) <= 0:
        raise CompressedCheckpointModelError("access weights must have positive total")
    if max_replay_frames <= 0:
        raise CompressedCheckpointModelError("max replay frames must be positive")
    if retained_source_bytes < 0 or decompressor_workspace_bytes < 0:
        raise CompressedCheckpointModelError("source/workspace bytes must be nonnegative")


def replay_frames_by_target(
    frame_count: int,
    checkpoint_starts: Sequence[int],
) -> tuple[int, ...]:
    starts = tuple(checkpoint_starts)
    if frame_count <= 0 or not starts or starts[0] != 0:
        raise CompressedCheckpointModelError("checkpoint starts must begin at frame zero")
    if starts != tuple(sorted(set(starts))) or starts[-1] >= frame_count:
        raise CompressedCheckpointModelError("checkpoint starts are invalid")
    result: list[int] = []
    current = starts[0]
    next_index = 1
    for target in range(frame_count):
        if next_index < len(starts) and target >= starts[next_index]:
            current = starts[next_index]
            next_index += 1
        result.append(target - current + 1)
    return tuple(result)


def _segment_cost(weights: Sequence[float], start: int, end: int) -> float:
    return sum(weights[target] * (target - start + 1) for target in range(start, end))


@functools.lru_cache(maxsize=None)
def _optimal_checkpoint_starts(
    weights: tuple[float, ...],
    checkpoint_count: int,
    max_replay_frames: int,
) -> tuple[int, ...]:
    frame_count = len(weights)
    if checkpoint_count <= 0 or checkpoint_count > frame_count:
        raise CompressedCheckpointModelError("checkpoint count is outside frame range")
    if checkpoint_count * max_replay_frames < frame_count:
        raise CompressedCheckpointModelError("checkpoint count cannot satisfy replay bound")
    infinity = float("inf")
    costs = [[infinity] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    previous = [[-1] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    costs[0][0] = 0.0
    for segments in range(1, checkpoint_count + 1):
        for end in range(segments, min(frame_count, segments * max_replay_frames) + 1):
            minimum_start = max(segments - 1, end - max_replay_frames)
            for start in range(minimum_start, end):
                prefix = costs[segments - 1][start]
                if not math.isfinite(prefix):
                    continue
                candidate = prefix + _segment_cost(weights, start, end)
                if candidate < costs[segments][end] - 1e-12:
                    costs[segments][end] = candidate
                    previous[segments][end] = start
                elif math.isclose(candidate, costs[segments][end], abs_tol=1e-12):
                    prior = previous[segments][end]
                    if prior < 0 or start < prior:
                        previous[segments][end] = start
    if not math.isfinite(costs[checkpoint_count][frame_count]):
        raise CompressedCheckpointModelError("no checkpoint layout satisfies replay bound")
    starts: list[int] = []
    end = frame_count
    for segments in range(checkpoint_count, 0, -1):
        start = previous[segments][end]
        if start < 0:
            raise CompressedCheckpointModelError("checkpoint layout reconstruction failed")
        starts.append(start)
        end = start
    starts.reverse()
    return tuple(starts)


def _weighted_quantile(
    values: Sequence[int],
    weights: Sequence[float],
    quantile: float,
) -> int:
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
    checkpoint_blob_bytes: int,
    access_weights: Sequence[float],
    checkpoint_starts: Sequence[int],
    retain_raw_subrects: bool,
    retained_source_bytes: int,
    max_replay_frames: int,
    decompressor_workspace_bytes: int,
    implicit_initial_checkpoint: bool,
) -> CompressedCheckpointPlan:
    starts = tuple(checkpoint_starts)
    replay = replay_frames_by_target(len(frames), starts)
    if max(replay) > max_replay_frames:
        raise CompressedCheckpointModelError("checkpoint layout exceeds replay bound")
    retained_raw = (
        sum(frame.subrect_rgba_bytes for frame in frames) if retain_raw_subrects else 0
    )
    retained_count = len(starts) - int(implicit_initial_checkpoint)
    retained_checkpoints = retained_count * checkpoint_blob_bytes
    maximum_subrect = max(frame.subrect_rgba_bytes for frame in frames)
    maximum_previous = max(
        (frame.subrect_rgba_bytes for frame in frames if frame.disposal_previous),
        default=0,
    )
    working = (
        canvas_rgba_bytes
        + maximum_subrect
        + maximum_previous
        + decompressor_workspace_bytes
    )
    output = canvas_rgba_bytes
    retained = retained_raw + retained_checkpoints + retained_source_bytes
    total_weight = sum(access_weights)
    expected = sum(value * weight for value, weight in zip(replay, access_weights)) / total_weight
    return CompressedCheckpointPlan(
        frame_count=len(frames),
        canvas_rgba_bytes=canvas_rgba_bytes,
        checkpoint_blob_bytes=checkpoint_blob_bytes,
        checkpoint_starts=starts,
        replay_frames_by_target=replay,
        retained_raw_subrect_bytes=retained_raw,
        retained_checkpoint_bytes=retained_checkpoints,
        retained_source_bytes=retained_source_bytes,
        decompressor_workspace_bytes=decompressor_workspace_bytes,
        compositor_working_bytes_upper_bound=working,
        materialized_output_bytes=output,
        modeled_peak_bytes_upper_bound=retained + working + output,
        expected_replay_frames=expected,
        p95_replay_frames=_weighted_quantile(replay, access_weights, 0.95),
        worst_replay_frames=max(replay),
        access_weight_sum=total_weight,
        retain_raw_subrects=retain_raw_subrects,
        max_replay_constraint=max_replay_frames,
        implicit_initial_checkpoint=implicit_initial_checkpoint,
    )


def build_pareto_frontier(
    *,
    frames: Sequence[FrameFootprint],
    canvas_rgba_bytes: int,
    checkpoint_blob_bytes: int,
    access_weights: Sequence[float],
    retained_budget_bytes: int,
    max_replay_frames: int,
    retain_raw_subrects: bool,
    retained_source_bytes: int,
    decompressor_workspace_bytes: int,
    implicit_initial_checkpoint: bool = True,
) -> tuple[CompressedCheckpointPlan, ...]:
    _validate_common(
        frames,
        canvas_rgba_bytes,
        access_weights,
        checkpoint_blob_bytes,
        max_replay_frames,
        retained_source_bytes,
        decompressor_workspace_bytes,
    )
    if retained_budget_bytes < 0:
        raise CompressedCheckpointModelError("retained budget must be nonnegative")
    retained_raw = (
        sum(frame.subrect_rgba_bytes for frame in frames) if retain_raw_subrects else 0
    )
    base = retained_raw + retained_source_bytes
    if base > retained_budget_bytes:
        raise CompressedCheckpointModelError("retained budget cannot hold source/raw state")
    stored_capacity = (retained_budget_bytes - base) // checkpoint_blob_bytes
    maximum_count = min(
        len(frames), stored_capacity + int(implicit_initial_checkpoint)
    )
    minimum_count = math.ceil(len(frames) / max_replay_frames)
    if maximum_count < minimum_count:
        raise CompressedCheckpointModelError(
            "retained budget cannot satisfy the maximum replay constraint"
        )
    candidates = []
    for count in range(minimum_count, maximum_count + 1):
        starts = _optimal_checkpoint_starts(tuple(access_weights), count, max_replay_frames)
        candidates.append(
            _build_plan_for_starts(
                frames=frames,
                canvas_rgba_bytes=canvas_rgba_bytes,
                checkpoint_blob_bytes=checkpoint_blob_bytes,
                access_weights=access_weights,
                checkpoint_starts=starts,
                retain_raw_subrects=retain_raw_subrects,
                retained_source_bytes=retained_source_bytes,
                max_replay_frames=max_replay_frames,
                decompressor_workspace_bytes=decompressor_workspace_bytes,
                implicit_initial_checkpoint=implicit_initial_checkpoint,
            )
        )
    frontier: list[CompressedCheckpointPlan] = []
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
        raise CompressedCheckpointModelError("checkpoint frontier is empty")
    return tuple(frontier)


def build_plan(**kwargs) -> CompressedCheckpointPlan:
    frontier = build_pareto_frontier(**kwargs)
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


def uniform_weights(frame_count: int) -> tuple[float, ...]:
    if frame_count <= 0:
        raise CompressedCheckpointModelError("frame count must be positive")
    return (1.0,) * frame_count


def tail_hot_weights(
    frame_count: int,
    *,
    tail_fraction: float = 0.25,
    tail_weight: float = 4.0,
) -> tuple[float, ...]:
    if frame_count <= 0 or not 0 < tail_fraction <= 1 or tail_weight <= 0:
        raise CompressedCheckpointModelError("tail-hot parameters are invalid")
    start = max(0, frame_count - math.ceil(frame_count * tail_fraction))
    return tuple(tail_weight if index >= start else 1.0 for index in range(frame_count))
