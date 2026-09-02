#!/usr/bin/env python3
from __future__ import annotations

import unittest

import w5_apng_tile_checkpoint_model as model


class W5APNGTileCheckpointModelTests(unittest.TestCase):
    def test_edge_tile_geometry_uses_actual_bytes(self) -> None:
        geometry = model.TileGeometry(canvas_width=10, canvas_height=6, tile_size=4)
        self.assertEqual((geometry.columns, geometry.rows, geometry.tile_count), (3, 2, 6))
        self.assertEqual(geometry.tile_bytes(0), 4 * 4 * 4)
        self.assertEqual(geometry.tile_bytes(2), 2 * 4 * 4)
        self.assertEqual(geometry.tile_bytes(5), 2 * 2 * 4)
        frame = model.TileFrame(x=3, y=3, width=5, height=3)
        self.assertEqual(geometry.tiles_for_frame(frame), (0, 1, 3, 4))

    def test_unchanged_tile_versions_are_shared_across_roots(self) -> None:
        geometry = model.TileGeometry(canvas_width=8, canvas_height=4, tile_size=4)
        frames = (
            model.TileFrame(0, 0, 4, 4),
            model.TileFrame(4, 0, 4, 4),
            model.TileFrame(0, 0, 4, 4),
        )
        trace = model.build_trace(geometry, frames)
        plan = model.build_plan(
            trace=trace,
            checkpoint_starts=(0, 1, 2),
            access_weights=(1.0, 1.0, 1.0),
            maximum_replay_frames=1,
            layout_family="test",
            retain_raw_subrects=False,
            retained_source_bytes=0,
        )
        self.assertEqual(plan.unique_retained_tile_version_count, 2)
        self.assertEqual(plan.retained_tile_version_bytes, 128)
        self.assertEqual(plan.retained_root_count, 2)
        self.assertEqual(plan.retained_root_bytes, 2 * (2 * 8 + 64))

    def test_previous_output_versions_do_not_enter_later_roots(self) -> None:
        geometry = model.TileGeometry(canvas_width=8, canvas_height=4, tile_size=4)
        frames = (
            model.TileFrame(0, 0, 4, 4, disposal="none"),
            model.TileFrame(4, 0, 4, 4, disposal="previous"),
            model.TileFrame(0, 0, 4, 4, disposal="none"),
        )
        trace = model.build_trace(geometry, frames)
        self.assertEqual(trace.pre_frame_states[1], trace.pre_frame_states[2])
        plan = model.build_plan(
            trace=trace,
            checkpoint_starts=(0, 1, 2),
            access_weights=(1.0, 1.0, 1.0),
            maximum_replay_frames=1,
            layout_family="test",
            retain_raw_subrects=False,
            retained_source_bytes=0,
        )
        self.assertEqual(plan.unique_retained_tile_version_count, 1)
        self.assertEqual(plan.retained_tile_version_bytes, 64)

    def test_full_tile_background_returns_to_implicit_transparent_tile(self) -> None:
        geometry = model.TileGeometry(canvas_width=4, canvas_height=4, tile_size=4)
        trace = model.build_trace(
            geometry,
            (
                model.TileFrame(0, 0, 4, 4, disposal="background"),
                model.TileFrame(0, 0, 4, 4),
            ),
        )
        self.assertEqual(trace.pre_frame_states[1], (0,))
        plan = model.build_plan(
            trace=trace,
            checkpoint_starts=(0, 1),
            access_weights=(1.0, 1.0),
            maximum_replay_frames=1,
            layout_family="test",
            retain_raw_subrects=False,
            retained_source_bytes=0,
        )
        self.assertEqual(plan.retained_tile_version_bytes, 0)

    def test_partial_tile_background_creates_post_disposal_version(self) -> None:
        geometry = model.TileGeometry(canvas_width=4, canvas_height=4, tile_size=4)
        trace = model.build_trace(
            geometry,
            (
                model.TileFrame(0, 0, 2, 4, disposal="background"),
                model.TileFrame(0, 0, 4, 4),
            ),
        )
        self.assertNotEqual(trace.pre_frame_states[1], (0,))
        plan = model.build_plan(
            trace=trace,
            checkpoint_starts=(0, 1),
            access_weights=(1.0, 1.0),
            maximum_replay_frames=1,
            layout_family="test",
            retain_raw_subrects=False,
            retained_source_bytes=0,
        )
        self.assertEqual(plan.retained_tile_version_bytes, 64)

    def test_plan_separates_retained_state_from_output_and_working_bytes(self) -> None:
        geometry = model.TileGeometry(canvas_width=8, canvas_height=8, tile_size=4)
        frames = tuple(model.TileFrame(0, 0, 4, 4) for _ in range(4))
        trace = model.build_trace(geometry, frames)
        plan = model.build_plan(
            trace=trace,
            checkpoint_starts=(0, 2),
            access_weights=(1.0,) * 4,
            maximum_replay_frames=2,
            layout_family="test",
            retain_raw_subrects=True,
            retained_source_bytes=0,
        )
        self.assertEqual(plan.replay_frames_by_target, (1, 2, 1, 2))
        self.assertEqual(plan.retained_raw_subrect_bytes, 4 * 64)
        self.assertEqual(plan.materialized_output_bytes, 8 * 8 * 4)
        self.assertEqual(plan.maximum_dirty_tile_bytes, 64)
        self.assertEqual(plan.worst_replay_frames, 2)
        self.assertEqual(plan.expected_replay_frames, 1.5)

    def test_candidate_layouts_all_respect_replay_bound(self) -> None:
        layouts = model.candidate_layouts(
            frame_count=20,
            access_weights=(1.0,) * 20,
            maximum_replay_frames=4,
        )
        self.assertGreater(len(layouts), 4)
        for _, starts in layouts:
            replay = model.replay_frames_by_target(20, starts)
            self.assertLessEqual(max(replay), 4)

    def test_tail_hot_access_optimal_layout_moves_last_checkpoint_later(self) -> None:
        uniform = model.access_optimal_starts((1.0,) * 8, 2, 4)
        tail_hot = model.access_optimal_starts(
            (1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 10.0, 10.0),
            2,
            4,
        )
        self.assertEqual(uniform, (0, 4))
        self.assertEqual(tail_hot, (0, 4))
        # With three roots, tail weighting can move an interior split while preserving the bound.
        uniform_three = model.access_optimal_starts((1.0,) * 8, 3, 4)
        tail_three = model.access_optimal_starts(
            (1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 10.0, 10.0),
            3,
            4,
        )
        self.assertNotEqual(uniform_three, tail_three)

    def test_pareto_frontier_removes_strictly_dominated_plan(self) -> None:
        geometry = model.TileGeometry(canvas_width=8, canvas_height=8, tile_size=4)
        trace = model.build_trace(
            geometry,
            tuple(model.TileFrame(0, 0, 4, 4) for _ in range(4)),
        )
        plans = [
            model.build_plan(
                trace=trace,
                checkpoint_starts=starts,
                access_weights=(1.0,) * 4,
                maximum_replay_frames=4,
                layout_family=name,
                retain_raw_subrects=False,
                retained_source_bytes=0,
            )
            for name, starts in (
                ("one", (0,)),
                ("two", (0, 2)),
                ("three", (0, 1, 2)),
            )
        ]
        frontier = model.pareto_frontier(plans)
        self.assertIn(plans[0], frontier)
        self.assertIn(plans[1], frontier)
        self.assertNotEqual(len(frontier), 0)


if __name__ == "__main__":
    unittest.main()
