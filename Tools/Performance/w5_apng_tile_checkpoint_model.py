#!/usr/bin/env python3
"""Persistent-tile checkpoint model for an owned APNG compositor.

The model is deliberately analytical. It treats every tile touched by a frame as a
new immutable tile version, retains checkpoint roots as flat tile-reference tables,
and shares unchanged tile versions across roots. A frame using `previous` disposal
creates transient output tiles but restores the pre-frame root, so those output
versions are not retained by later checkpoints. A full-tile background clear returns
to the implicit transparent tile; a partial clear creates a new tile version.
"""

from __future__ import annotations

import dataclasses
import math
from typing import Iterable, Sequence


class TileCheckpointModelError(ValueError):
    pass


@dataclasses.dataclass(frozen=True)
class TileFrame:
    x: int
    y: int
    width: int
    height: int
    disposal: str = "none"

    def __post_init__(self) -> None:
        if self.x < 0 or self.y < 0 or self.width <= 0 or self.height <= 0:
            raise TileCheckpointModelError("frame rectangle is invalid")
        if self.disposal not in {"none", "background", "previous"}:
            raise TileCheckpointModelError("frame disposal is invalid")

    @property
    def rgba_bytes(self) -> int:
        return self.width * self.height * 4


@dataclasses.dataclass(frozen=True)
class TileGeometry:
    canvas_width: int
    canvas_height: int
    tile_size: int

    def __post_init__(self) -> None:
        if self.canvas_width <= 0 or self.canvas_height <= 0 or self.tile_size <= 0:
            raise TileCheckpointModelError("tile geometry values must be positive")

    @property
    def columns(self) -> int:
        return math.ceil(self.canvas_width / self.tile_size)

    @property
    def rows(self) -> int:
        return math.ceil(self.canvas_height / self.tile_size)

    @property
    def tile_count(self) -> int:
        return self.columns * self.rows

    @property
    def canvas_rgba_bytes(self) -> int:
        return self.canvas_width * self.canvas_height * 4

    def tile_bounds(self, tile_index: int) -> tuple[int, int, int, int]:
        if tile_index < 0 or tile_index >= self.tile_count:
            raise TileCheckpointModelError("tile index is outside geometry")
        column = tile_index % self.columns
        row = tile_index // self.columns
        x = column * self.tile_size
        y = row * self.tile_size
        width = min(self.tile_size, self.canvas_width - x)
        height = min(self.tile_size, self.canvas_height - y)
        return (x, y, width, height)

    def tile_bytes(self, tile_index: int) -> int:
        _, _, width, height = self.tile_bounds(tile_index)
        return width * height * 4

    def tiles_for_frame(self, frame: TileFrame) -> tuple[int, ...]:
        right = frame.x + frame.width
        bottom = frame.y + frame.height
        if right > self.canvas_width or bottom > self.canvas_height:
            raise TileCheckpointModelError("frame rectangle exceeds canvas")
        first_column = frame.x // self.tile_size
        last_column = (right - 1) // self.tile_size
        first_row = frame.y // self.tile_size
        last_row = (bottom - 1) // self.tile_size
        return tuple(
            row * self.columns + column
            for row in range(first_row, last_row + 1)
            for column in range(first_column, last_column + 1)
        )

    def frame_covers_tile(self, frame: TileFrame, tile_index: int) -> bool:
        tile_x, tile_y, tile_width, tile_height = self.tile_bounds(tile_index)
        return (
            frame.x <= tile_x
            and frame.y <= tile_y
            and frame.x + frame.width >= tile_x + tile_width
            and frame.y + frame.height >= tile_y + tile_height
        )


@dataclasses.dataclass(frozen=True)
class TileStateTrace:
    geometry: TileGeometry
    frames: tuple[TileFrame, ...]
    pre_frame_states: tuple[tuple[int, ...], ...]
    nonzero_versions_by_start: tuple[frozenset[int], ...]
    version_bytes: dict[int, int]
    dirty_tiles_by_frame: tuple[tuple[int, ...], ...]
    dirty_tile_bytes_by_frame: tuple[int, ...]
    transient_output_tile_bytes_by_frame: tuple[int, ...]

    def __post_init__(self) -> None:
        if len(self.pre_frame_states) != len(self.frames):
            raise TileCheckpointModelError("pre-frame state count mismatch")


@dataclasses.dataclass(frozen=True)
class TileCheckpointPlan:
    frame_count: int
    tile_size: int
    tile_count: int
    checkpoint_starts: tuple[int, ...]
    layout_family: str
    replay_frames_by_target: tuple[int, ...]
    unique_retained_tile_version_count: int
    retained_tile_version_bytes: int
    retained_root_bytes: int
    retained_raw_subrect_bytes: int
    retained_source_bytes: int
    retained_bytes: int
    maximum_dirty_tile_bytes: int
    materialized_output_bytes: int
    root_build_scratch_bytes: int
    modeled_peak_bytes_upper_bound: int
    expected_replay_frames: float
    p95_replay_frames: int
    worst_replay_frames: int
    implicit_initial_root: bool
    root_entry_bytes: int
    root_header_bytes: int

    @property
    def checkpoint_count(self) -> int:
        return len(self.checkpoint_starts)

    @property
    def retained_root_count(self) -> int:
        return self.checkpoint_count - int(self.implicit_initial_root)

    def to_dict(self) -> dict[str, object]:
        payload = dataclasses.asdict(self)
        payload["checkpoint_count"] = self.checkpoint_count
        payload["retained_root_count"] = self.retained_root_count
        return payload


def build_trace(
    geometry: TileGeometry,
    frames: Sequence[TileFrame],
) -> TileStateTrace:
    if not frames:
        raise TileCheckpointModelError("at least one frame is required")
    state = [0] * geometry.tile_count
    pre_states: list[tuple[int, ...]] = []
    version_bytes: dict[int, int] = {}
    dirty_tiles_by_frame: list[tuple[int, ...]] = []
    dirty_tile_bytes_by_frame: list[int] = []
    transient_output_bytes: list[int] = []
    next_version = 1

    for frame in frames:
        pre_states.append(tuple(state))
        dirty_tiles = geometry.tiles_for_frame(frame)
        dirty_bytes = sum(geometry.tile_bytes(index) for index in dirty_tiles)
        dirty_tiles_by_frame.append(dirty_tiles)
        dirty_tile_bytes_by_frame.append(dirty_bytes)

        output_state = list(state)
        for tile_index in dirty_tiles:
            output_state[tile_index] = next_version
            version_bytes[next_version] = geometry.tile_bytes(tile_index)
            next_version += 1
        transient_output_bytes.append(dirty_bytes)

        if frame.disposal == "none":
            state = output_state
        elif frame.disposal == "previous":
            # The output versions are intentionally unreachable from later pre-frame states.
            continue
        else:
            post_state = output_state
            for tile_index in dirty_tiles:
                if geometry.frame_covers_tile(frame, tile_index):
                    post_state[tile_index] = 0
                else:
                    post_state[tile_index] = next_version
                    version_bytes[next_version] = geometry.tile_bytes(tile_index)
                    next_version += 1
            state = post_state

    return TileStateTrace(
        geometry=geometry,
        frames=tuple(frames),
        pre_frame_states=tuple(pre_states),
        nonzero_versions_by_start=tuple(
            frozenset(version for version in state_value if version != 0)
            for state_value in pre_states
        ),
        version_bytes=version_bytes,
        dirty_tiles_by_frame=tuple(dirty_tiles_by_frame),
        dirty_tile_bytes_by_frame=tuple(dirty_tile_bytes_by_frame),
        transient_output_tile_bytes_by_frame=tuple(transient_output_bytes),
    )


def replay_frames_by_target(
    frame_count: int,
    checkpoint_starts: Sequence[int],
) -> tuple[int, ...]:
    starts = tuple(checkpoint_starts)
    if not starts or starts[0] != 0:
        raise TileCheckpointModelError("checkpoint starts must begin at frame zero")
    if starts != tuple(sorted(set(starts))):
        raise TileCheckpointModelError("checkpoint starts must be unique and increasing")
    if starts[-1] >= frame_count:
        raise TileCheckpointModelError("checkpoint start is outside frame range")
    result: list[int] = []
    current = 0
    following_index = 1
    for target in range(frame_count):
        if following_index < len(starts) and target >= starts[following_index]:
            current = starts[following_index]
            following_index += 1
        result.append(target - current + 1)
    return tuple(result)


def weighted_quantile(
    values: Sequence[int],
    weights: Sequence[float],
    quantile: float,
) -> int:
    if len(values) != len(weights) or not values:
        raise TileCheckpointModelError("weighted quantile input mismatch")
    if not 0 < quantile <= 1:
        raise TileCheckpointModelError("quantile must be in (0, 1]")
    total = sum(weights)
    if total <= 0:
        raise TileCheckpointModelError("access weights must have positive total")
    threshold = total * quantile
    cumulative = 0.0
    for value, weight in sorted(zip(values, weights), key=lambda item: item[0]):
        cumulative += weight
        if cumulative + 1e-15 >= threshold:
            return value
    return max(values)


def build_plan(
    *,
    trace: TileStateTrace,
    checkpoint_starts: Sequence[int],
    access_weights: Sequence[float],
    maximum_replay_frames: int,
    layout_family: str,
    retain_raw_subrects: bool,
    retained_source_bytes: int,
    root_entry_bytes: int = 8,
    root_header_bytes: int = 64,
    implicit_initial_root: bool = True,
) -> TileCheckpointPlan:
    frame_count = len(trace.frames)
    if len(access_weights) != frame_count:
        raise TileCheckpointModelError("access weight count mismatch")
    if any(not math.isfinite(value) or value < 0 for value in access_weights):
        raise TileCheckpointModelError("access weights must be finite and nonnegative")
    if sum(access_weights) <= 0:
        raise TileCheckpointModelError("access weights must have positive total")
    if retained_source_bytes < 0 or root_entry_bytes <= 0 or root_header_bytes < 0:
        raise TileCheckpointModelError("retained/root byte values are invalid")
    starts = tuple(checkpoint_starts)
    replay = replay_frames_by_target(frame_count, starts)
    if max(replay) > maximum_replay_frames:
        raise TileCheckpointModelError("checkpoint layout exceeds replay bound")

    retained_versions: set[int] = set()
    for start in starts:
        if implicit_initial_root and start == 0:
            continue
        retained_versions.update(trace.nonzero_versions_by_start[start])
    retained_tile_bytes = sum(trace.version_bytes[value] for value in retained_versions)
    retained_root_count = len(starts) - int(implicit_initial_root)
    retained_root_bytes = retained_root_count * (
        trace.geometry.tile_count * root_entry_bytes + root_header_bytes
    )
    retained_raw_bytes = (
        sum(frame.rgba_bytes for frame in trace.frames) if retain_raw_subrects else 0
    )
    retained_bytes = (
        retained_tile_bytes
        + retained_root_bytes
        + retained_raw_bytes
        + retained_source_bytes
    )
    maximum_dirty_bytes = max(trace.dirty_tile_bytes_by_frame)
    root_scratch = trace.geometry.tile_count * root_entry_bytes + root_header_bytes
    output_bytes = trace.geometry.canvas_rgba_bytes
    modeled_peak = retained_bytes + maximum_dirty_bytes + output_bytes + root_scratch
    total_weight = sum(access_weights)
    expected = sum(
        replay_value * weight
        for replay_value, weight in zip(replay, access_weights)
    ) / total_weight
    return TileCheckpointPlan(
        frame_count=frame_count,
        tile_size=trace.geometry.tile_size,
        tile_count=trace.geometry.tile_count,
        checkpoint_starts=starts,
        layout_family=layout_family,
        replay_frames_by_target=replay,
        unique_retained_tile_version_count=len(retained_versions),
        retained_tile_version_bytes=retained_tile_bytes,
        retained_root_bytes=retained_root_bytes,
        retained_raw_subrect_bytes=retained_raw_bytes,
        retained_source_bytes=retained_source_bytes,
        retained_bytes=retained_bytes,
        maximum_dirty_tile_bytes=maximum_dirty_bytes,
        materialized_output_bytes=output_bytes,
        root_build_scratch_bytes=root_scratch,
        modeled_peak_bytes_upper_bound=modeled_peak,
        expected_replay_frames=expected,
        p95_replay_frames=weighted_quantile(replay, access_weights, 0.95),
        worst_replay_frames=max(replay),
        implicit_initial_root=implicit_initial_root,
        root_entry_bytes=root_entry_bytes,
        root_header_bytes=root_header_bytes,
    )


def fixed_interval_starts(frame_count: int, interval: int) -> tuple[int, ...]:
    if frame_count <= 0 or interval <= 0:
        raise TileCheckpointModelError("frame count and interval must be positive")
    return tuple(range(0, frame_count, interval))


def _segment_cost(weights: Sequence[float], start: int, end: int) -> float:
    return sum(weights[index] * (index - start + 1) for index in range(start, end))


def access_optimal_starts(
    access_weights: Sequence[float],
    checkpoint_count: int,
    maximum_replay_frames: int,
) -> tuple[int, ...]:
    frame_count = len(access_weights)
    if checkpoint_count <= 0 or checkpoint_count > frame_count:
        raise TileCheckpointModelError("checkpoint count is outside frame range")
    if checkpoint_count * maximum_replay_frames < frame_count:
        raise TileCheckpointModelError("checkpoint count cannot satisfy replay bound")
    infinity = float("inf")
    costs = [[infinity] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    previous = [[-1] * (frame_count + 1) for _ in range(checkpoint_count + 1)]
    costs[0][0] = 0.0
    for segments in range(1, checkpoint_count + 1):
        for end in range(segments, min(frame_count, segments * maximum_replay_frames) + 1):
            minimum_start = max(segments - 1, end - maximum_replay_frames)
            for start in range(minimum_start, end):
                prefix = costs[segments - 1][start]
                if not math.isfinite(prefix):
                    continue
                candidate = prefix + _segment_cost(access_weights, start, end)
                if candidate < costs[segments][end] - 1e-12:
                    costs[segments][end] = candidate
                    previous[segments][end] = start
                elif math.isclose(candidate, costs[segments][end], abs_tol=1e-12):
                    prior = previous[segments][end]
                    if prior < 0 or start < prior:
                        previous[segments][end] = start
    if not math.isfinite(costs[checkpoint_count][frame_count]):
        raise TileCheckpointModelError("no access-optimal layout satisfies replay bound")
    starts: list[int] = []
    end = frame_count
    for segments in range(checkpoint_count, 0, -1):
        start = previous[segments][end]
        if start < 0:
            raise TileCheckpointModelError("layout reconstruction failed")
        starts.append(start)
        end = start
    starts.reverse()
    return tuple(starts)


def candidate_layouts(
    *,
    frame_count: int,
    access_weights: Sequence[float],
    maximum_replay_frames: int,
) -> tuple[tuple[str, tuple[int, ...]], ...]:
    if frame_count <= 0 or maximum_replay_frames <= 0:
        raise TileCheckpointModelError("candidate layout domain is invalid")
    layouts: dict[tuple[int, ...], str] = {}
    for interval in range(1, maximum_replay_frames + 1):
        starts = fixed_interval_starts(frame_count, interval)
        layouts.setdefault(starts, f"fixed-interval-{interval}")

    minimum_count = math.ceil(frame_count / maximum_replay_frames)
    counts = {minimum_count, frame_count}
    for interval in range(1, maximum_replay_frames + 1):
        counts.add(math.ceil(frame_count / interval))
    for delta in (1, 2, 4, 8, 16):
        counts.add(min(frame_count, minimum_count + delta))
    for count in sorted(counts):
        starts = access_optimal_starts(
            access_weights,
            count,
            maximum_replay_frames,
        )
        layouts.setdefault(starts, f"access-optimal-{count}")
    return tuple(
        (family, starts)
        for starts, family in sorted(
            layouts.items(), key=lambda item: (len(item[0]), item[0])
        )
    )


def pareto_frontier(plans: Iterable[TileCheckpointPlan]) -> tuple[TileCheckpointPlan, ...]:
    ordered = sorted(
        plans,
        key=lambda item: (
            item.retained_bytes,
            item.expected_replay_frames,
            item.p95_replay_frames,
            item.worst_replay_frames,
            item.tile_size,
            item.checkpoint_starts,
        ),
    )
    frontier: list[TileCheckpointPlan] = []
    for candidate in ordered:
        dominated = False
        for other in ordered:
            if other is candidate:
                continue
            no_worse = (
                other.retained_bytes <= candidate.retained_bytes
                and other.expected_replay_frames
                <= candidate.expected_replay_frames + 1e-12
                and other.p95_replay_frames <= candidate.p95_replay_frames
                and other.worst_replay_frames <= candidate.worst_replay_frames
            )
            strictly_better = (
                other.retained_bytes < candidate.retained_bytes
                or other.expected_replay_frames
                < candidate.expected_replay_frames - 1e-12
                or other.p95_replay_frames < candidate.p95_replay_frames
                or other.worst_replay_frames < candidate.worst_replay_frames
            )
            if no_worse and strictly_better:
                dominated = True
                break
        if not dominated:
            frontier.append(candidate)
    return tuple(frontier)
