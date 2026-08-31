#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/Performance"))

import w5_apng_compressed_checkpoint_model as model


class CompressedCheckpointModelTests(unittest.TestCase):
    def frames(self, count: int, subrect: int = 64, previous: int | None = None):
        return tuple(
            model.FrameFootprint(subrect, disposal_previous=index == previous)
            for index in range(count)
        )

    def test_blob_round_trip_and_tamper_fail_closed(self) -> None:
        raw = bytes(range(64))
        blob = model.encode_checkpoint_blob(raw, 4, 4)
        width, height, decoded = model.decode_checkpoint_blob(blob)
        self.assertEqual((width, height, decoded), (4, 4, raw))
        altered = bytearray(blob)
        altered[-1] ^= 1
        with self.assertRaises(model.CompressedCheckpointModelError):
            model.decode_checkpoint_blob(bytes(altered))

    def test_ratio_conversion_is_ceil_bounded(self) -> None:
        self.assertEqual(model.checkpoint_blob_bytes_for_ratio(1_000_000, 10_000), 10_000)
        self.assertEqual(model.checkpoint_blob_bytes_for_ratio(101, 10_000), 36)

    def test_implicit_initial_state_does_not_consume_blob(self) -> None:
        plan = model.build_plan(
            frames=self.frames(4),
            canvas_rgba_bytes=1024,
            checkpoint_blob_bytes=100,
            access_weights=model.uniform_weights(4),
            retained_budget_bytes=400,
            max_replay_frames=2,
            retain_raw_subrects=False,
            retained_source_bytes=0,
            decompressor_workspace_bytes=16,
        )
        self.assertEqual(plan.retained_checkpoint_bytes, (plan.checkpoint_count - 1) * 100)

    def test_compression_can_satisfy_replay_where_full_canvas_cannot(self) -> None:
        plan = model.build_plan(
            frames=self.frames(16),
            canvas_rgba_bytes=4096,
            checkpoint_blob_bytes=128,
            access_weights=model.uniform_weights(16),
            retained_budget_bytes=512,
            max_replay_frames=4,
            retain_raw_subrects=False,
            retained_source_bytes=0,
            decompressor_workspace_bytes=32,
        )
        self.assertLessEqual(plan.worst_replay_frames, 4)
        self.assertLess(plan.retained_checkpoint_bytes, 4096)

    def test_source_raw_base_failure_is_fail_closed(self) -> None:
        with self.assertRaisesRegex(
            model.CompressedCheckpointModelError,
            "cannot hold source/raw state",
        ):
            model.build_plan(
                frames=self.frames(4, 512),
                canvas_rgba_bytes=1024,
                checkpoint_blob_bytes=64,
                access_weights=model.uniform_weights(4),
                retained_budget_bytes=1000,
                max_replay_frames=2,
                retain_raw_subrects=True,
                retained_source_bytes=0,
                decompressor_workspace_bytes=0,
            )

    def test_peak_includes_retained_working_output_and_workspace(self) -> None:
        plan = model.build_plan(
            frames=self.frames(2, 128, previous=1),
            canvas_rgba_bytes=1024,
            checkpoint_blob_bytes=64,
            access_weights=model.uniform_weights(2),
            retained_budget_bytes=1024,
            max_replay_frames=2,
            retain_raw_subrects=False,
            retained_source_bytes=100,
            decompressor_workspace_bytes=32,
        )
        expected_working = 1024 + 128 + 128 + 32
        self.assertEqual(plan.compositor_working_bytes_upper_bound, expected_working)
        self.assertEqual(
            plan.modeled_peak_bytes_upper_bound,
            plan.retained_bytes + expected_working + 1024,
        )

    def test_tail_hot_access_moves_checkpoint_later(self) -> None:
        uniform = model.build_plan(
            frames=self.frames(12),
            canvas_rgba_bytes=1024,
            checkpoint_blob_bytes=100,
            access_weights=model.uniform_weights(12),
            retained_budget_bytes=300,
            max_replay_frames=6,
            retain_raw_subrects=False,
            retained_source_bytes=0,
            decompressor_workspace_bytes=0,
        )
        tail = model.build_plan(
            frames=self.frames(12),
            canvas_rgba_bytes=1024,
            checkpoint_blob_bytes=100,
            access_weights=model.tail_hot_weights(12),
            retained_budget_bytes=300,
            max_replay_frames=6,
            retain_raw_subrects=False,
            retained_source_bytes=0,
            decompressor_workspace_bytes=0,
        )
        self.assertGreaterEqual(tail.checkpoint_starts[-1], uniform.checkpoint_starts[-1])

    def test_invalid_ratio_and_geometry_fail_closed(self) -> None:
        with self.assertRaises(model.CompressedCheckpointModelError):
            model.checkpoint_blob_bytes_for_ratio(0, 1000)
        with self.assertRaises(model.CompressedCheckpointModelError):
            model.encode_checkpoint_blob(b"x", 1, 1)


if __name__ == "__main__":
    unittest.main()
