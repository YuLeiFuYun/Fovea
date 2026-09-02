#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/Performance"))

import w5_yyimage_semantic_replay_oracle as oracle


class YYImageSemanticReplayOracleTests(unittest.TestCase):
    def test_full_background_advances_next_anchor(self) -> None:
        frames = tuple(
            oracle.FrameSemantics(True, False, "background", 100) for _ in range(4)
        )
        self.assertEqual(oracle.yyimage_semantic_replay_starts(frames), (0, 1, 2, 3))

    def test_full_source_resets_at_current_frame_unless_previous(self) -> None:
        frames = (
            oracle.FrameSemantics(True, False, "none", 100),
            oracle.FrameSemantics(True, True, "none", 100),
            oracle.FrameSemantics(False, False, "none", 20),
            oracle.FrameSemantics(True, True, "previous", 100),
            oracle.FrameSemantics(False, False, "none", 20),
        )
        self.assertEqual(oracle.yyimage_semantic_replay_starts(frames), (0, 1, 1, 3, 1))

    def test_subrect_background_does_not_create_full_canvas_reset(self) -> None:
        frames = (
            oracle.FrameSemantics(True, False, "none", 100),
            oracle.FrameSemantics(False, False, "background", 20),
            oracle.FrameSemantics(False, False, "none", 20),
        )
        self.assertEqual(oracle.yyimage_semantic_replay_starts(frames), (0, 0, 0))

    def test_source_bound_full_background_fixture_is_strict_same_bytes_improvement(self) -> None:
        report = json.loads(
            (
                ROOT
                / ".artifacts/performance/w5-apng-composition-oracle-v5/APNG-OVER-BACKGROUND.json"
            ).read_text()
        )
        semantics = tuple(oracle.frame_semantics_from_report_frame(item) for item in report["frames"])
        starts = oracle.yyimage_semantic_replay_starts(semantics)
        self.assertEqual(starts, (0, 1, 2))
        frames = tuple(
            oracle.checkpoint.FrameFootprint(item.subrect_rgba_bytes) for item in semantics
        )
        canvas = report["frames"][0]["imageCraftWidth"] * report["frames"][0]["imageCraftHeight"] * 4
        result = oracle.compare_same_layout(frames, canvas, report["inputByteCount"], starts)
        self.assertTrue(result["strictReplayImprovement"])
        self.assertTrue(result["sameRetainedBytes"])
        self.assertTrue(result["sameModeledPeakBytes"])
        self.assertEqual(result["baseline"]["worstReplayFrames"], 3)
        self.assertEqual(result["semantic"]["worstReplayFrames"], 1)


if __name__ == "__main__":
    unittest.main()
