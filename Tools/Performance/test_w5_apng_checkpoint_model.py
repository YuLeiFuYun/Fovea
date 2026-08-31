#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/Performance"))

import w5_apng_checkpoint_model as model


class W5APNGCheckpointModelTests(unittest.TestCase):
    def test_uniform_access_places_two_checkpoints_evenly(self) -> None:
        frames = tuple(model.FrameFootprint(10) for _ in range(4))
        plan = model.build_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(4),
            retained_budget_bytes=140,
            max_replay_frames=4,
        )
        self.assertEqual(plan.checkpoint_starts, (0, 2))
        self.assertEqual(plan.replay_frames_by_target, (1, 2, 1, 2))
        self.assertEqual(plan.expected_replay_frames, 1.5)
        self.assertEqual(plan.p95_replay_frames, 2)
        self.assertEqual(plan.worst_replay_frames, 2)
        self.assertEqual(plan.retained_checkpoint_count, 1)
        self.assertEqual(plan.retained_bytes, 140)

    def test_tail_hot_access_moves_checkpoint_to_tail(self) -> None:
        frames = tuple(model.FrameFootprint(10) for _ in range(4))
        plan = model.build_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=(1.0, 1.0, 1.0, 100.0),
            retained_budget_bytes=140,
            max_replay_frames=4,
        )
        self.assertEqual(plan.checkpoint_starts, (0, 3))
        self.assertEqual(plan.replay_frames_by_target, (1, 2, 3, 1))
        self.assertLess(plan.expected_replay_frames, 1.1)

    def test_max_replay_constraint_is_fail_closed(self) -> None:
        frames = tuple(model.FrameFootprint(10) for _ in range(5))
        with self.assertRaisesRegex(model.CheckpointModelError, "maximum replay"):
            model.build_plan(
                frames=frames,
                canvas_rgba_bytes=100,
                access_weights=model.uniform_weights(5),
                retained_budget_bytes=249,
                max_replay_frames=2,
            )
        plan = model.build_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(5),
            retained_budget_bytes=250,
            max_replay_frames=2,
        )
        self.assertEqual(plan.checkpoint_count, 3)
        self.assertEqual(plan.retained_checkpoint_count, 2)
        self.assertEqual(plan.checkpoint_starts[0], 0)
        self.assertEqual(plan.worst_replay_frames, 2)
        self.assertAlmostEqual(plan.expected_replay_frames, 1.4)
        self.assertTrue(all(value <= 2 for value in plan.replay_frames_by_target))

    def test_previous_disposal_region_is_counted_as_transient_state(self) -> None:
        frames = (
            model.FrameFootprint(10),
            model.FrameFootprint(20, disposal_previous=True),
            model.FrameFootprint(15),
        )
        plan = model.build_fixed_interval_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(3),
            checkpoint_interval=2,
        )
        self.assertEqual(plan.compositor_working_bytes_upper_bound, 140)
        self.assertEqual(plan.materialized_output_bytes, 100)
        self.assertEqual(plan.retained_raw_subrect_bytes, 45)
        self.assertEqual(plan.retained_checkpoint_bytes, 100)
        self.assertEqual(plan.modeled_peak_bytes_upper_bound, 385)

    def test_fixed_interval_replay_vector(self) -> None:
        frames = tuple(model.FrameFootprint(4) for _ in range(7))
        plan = model.build_fixed_interval_plan(
            frames=frames,
            canvas_rgba_bytes=64,
            access_weights=model.uniform_weights(7),
            checkpoint_interval=3,
            retained_source_bytes=11,
        )
        self.assertEqual(plan.checkpoint_starts, (0, 3, 6))
        self.assertEqual(plan.replay_frames_by_target, (1, 2, 3, 1, 2, 3, 1))
        self.assertEqual(plan.retained_source_bytes, 11)
        self.assertEqual(plan.retained_checkpoint_count, 2)
        self.assertEqual(plan.worst_replay_frames, 3)

    def test_budget_must_hold_raw_state_but_not_implicit_initial_canvas(self) -> None:
        frames = (model.FrameFootprint(80), model.FrameFootprint(80))
        with self.assertRaisesRegex(model.CheckpointModelError, "source/raw"):
            model.build_plan(
                frames=frames,
                canvas_rgba_bytes=100,
                access_weights=model.uniform_weights(2),
                retained_budget_bytes=159,
                max_replay_frames=2,
            )
        plan = model.build_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(2),
            retained_budget_bytes=160,
            max_replay_frames=2,
        )
        self.assertEqual(plan.checkpoint_starts, (0,))
        self.assertEqual(plan.retained_checkpoint_bytes, 0)

    def test_explicit_initial_checkpoint_consumes_canvas_bytes(self) -> None:
        frames = (model.FrameFootprint(10), model.FrameFootprint(10))
        with self.assertRaisesRegex(model.CheckpointModelError, "maximum replay"):
            model.build_plan(
                frames=frames,
                canvas_rgba_bytes=100,
                access_weights=model.uniform_weights(2),
                retained_budget_bytes=119,
                max_replay_frames=2,
                implicit_initial_checkpoint=False,
            )
        plan = model.build_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(2),
            retained_budget_bytes=120,
            max_replay_frames=2,
            implicit_initial_checkpoint=False,
        )
        self.assertEqual(plan.retained_checkpoint_count, 1)
        self.assertEqual(plan.retained_checkpoint_bytes, 100)

    def test_decode_on_replay_can_exclude_retained_raw_bytes(self) -> None:
        frames = tuple(model.FrameFootprint(25) for _ in range(4))
        plan = model.build_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(4),
            retained_budget_bytes=100,
            max_replay_frames=2,
            retain_raw_subrects=False,
        )
        self.assertEqual(plan.retained_raw_subrect_bytes, 0)
        self.assertEqual(plan.checkpoint_starts, (0, 2))

    def test_pareto_frontier_exposes_memory_replay_tradeoff(self) -> None:
        frames = tuple(model.FrameFootprint(10) for _ in range(6))
        frontier = model.build_pareto_frontier(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(6),
            retained_budget_bytes=360,
            max_replay_frames=3,
        )
        self.assertEqual([plan.checkpoint_count for plan in frontier], [2, 3, 4])
        self.assertEqual([plan.retained_bytes for plan in frontier], [160, 260, 360])
        self.assertEqual([plan.worst_replay_frames for plan in frontier], [3, 2, 2])
        self.assertGreater(
            frontier[0].expected_replay_frames,
            frontier[-1].expected_replay_frames,
        )

    def test_repeat_footprints_preserves_pattern(self) -> None:
        pattern = (
            model.FrameFootprint(1),
            model.FrameFootprint(2, disposal_previous=True),
        )
        repeated = model.repeat_footprints(pattern, 5)
        self.assertEqual([frame.subrect_rgba_bytes for frame in repeated], [1, 2, 1, 2, 1])
        self.assertTrue(repeated[3].disposal_previous)

    def test_semantic_replay_starts_reduce_replay_without_retained_bytes(self) -> None:
        frames = tuple(model.FrameFootprint(10) for _ in range(6))
        baseline = model.build_fixed_interval_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(6),
            checkpoint_interval=6,
            retain_raw_subrects=False,
            retained_source_bytes=20,
        )
        semantic = model.build_fixed_interval_plan(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(6),
            checkpoint_interval=6,
            retain_raw_subrects=False,
            retained_source_bytes=20,
            semantic_replay_starts=(0, 0, 2, 2, 4, 4),
        )
        self.assertEqual(baseline.retained_bytes, semantic.retained_bytes)
        self.assertEqual(baseline.modeled_peak_bytes_upper_bound, semantic.modeled_peak_bytes_upper_bound)
        self.assertEqual(baseline.replay_frames_by_target, (1, 2, 3, 4, 5, 6))
        self.assertEqual(semantic.replay_frames_by_target, (1, 2, 1, 2, 1, 2))
        self.assertLess(semantic.expected_replay_frames, baseline.expected_replay_frames)
        self.assertLess(semantic.worst_replay_frames, baseline.worst_replay_frames)

    def test_semantic_replay_start_cannot_skip_past_target(self) -> None:
        frames = tuple(model.FrameFootprint(10) for _ in range(3))
        with self.assertRaisesRegex(model.CheckpointModelError, "semantic replay start"):
            model.build_fixed_interval_plan(
                frames=frames,
                canvas_rgba_bytes=100,
                access_weights=model.uniform_weights(3),
                checkpoint_interval=3,
                semantic_replay_starts=(0, 2, 2),
            )

    def test_semantic_optimizer_can_meet_replay_bound_without_stored_checkpoint(self) -> None:
        frames = tuple(model.FrameFootprint(100) for _ in range(60))
        kwargs = dict(
            frames=frames,
            canvas_rgba_bytes=100,
            access_weights=model.uniform_weights(60),
            retained_budget_bytes=20,
            max_replay_frames=8,
            retain_raw_subrects=False,
            retained_source_bytes=20,
        )
        with self.assertRaisesRegex(model.CheckpointModelError, "maximum replay"):
            model.build_plan(**kwargs)
        semantic = model.build_plan(
            **kwargs, semantic_replay_starts=tuple(range(60))
        )
        self.assertEqual(semantic.checkpoint_starts, (0,))
        self.assertEqual(semantic.retained_checkpoint_bytes, 0)
        self.assertEqual(semantic.retained_bytes, 20)
        self.assertEqual(semantic.worst_replay_frames, 1)
        self.assertEqual(semantic.expected_replay_frames, 1.0)


if __name__ == "__main__":
    unittest.main()
