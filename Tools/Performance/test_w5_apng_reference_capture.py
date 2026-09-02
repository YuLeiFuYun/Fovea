#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = ROOT / "Tools/Performance"


def load_module(name: str, path: pathlib.Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


reference = load_module("w5_reference_contract", PERFORMANCE / "w5_apng_reference.py")
unit_fixture = load_module(
    "w5_reference_fixture_builder", PERFORMANCE / "test_w5_apng_reference.py"
)
validator_module = load_module(
    "w5_reference_validator_contract", PERFORMANCE / "validate_w5_apng_reference.py"
)


def identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"path": str(path), "byteCount": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def snapshot(head: str, head_tree: str, working_tree: str) -> dict[str, object]:
    return {
        "root": "/unavailable",
        "headCommit": head,
        "headTree": head_tree,
        "workingTree": working_tree,
        "dirty": head_tree != working_tree,
        "statusShort": [" M synthetic"] if head_tree != working_tree else [],
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
    }


class W5APNGReferenceCaptureTests(unittest.TestCase):
    def validator_command(self, root: pathlib.Path) -> list[str]:
        return [sys.executable, str(PERFORMANCE / "validate_w5_apng_reference.py"), str(root)]

    def run_validator(self, root: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.validator_command(root),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_valid_capture_and_tamper_failures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="w5-apng-reference-contract-") as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_capture(root)
            completed = self.run_validator(root)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

            report_path = root / "report.json"
            self.expect_json_failure(
                root,
                report_path,
                lambda payload: payload["sourceAfter"]["Fovea"].__setitem__(
                    "workingTree", "f" * 40
                ),
                "source before/after mismatch",
            )
            self.expect_json_failure(
                root,
                report_path,
                lambda payload: payload["calibration"]["best"].__setitem__(
                    "orientation", "bottom-up"
                ),
                "calibration best candidate mismatch",
            )
            self.expect_json_failure(
                root,
                report_path,
                lambda payload: payload["fixtureResults"]["SYNTHETIC"]["frames"][0][
                    "rawSubrectRGBA"
                ].__setitem__("sha256", "f" * 64),
                "rawSubrectRGBA: identity mismatch",
            )

            reference_path = root / "frames/SYNTHETIC-frame-00-reference.rgba"
            original = reference_path.read_bytes()
            try:
                altered = bytearray(original)
                altered[0] ^= 1
                reference_path.write_bytes(altered)
                completed = self.run_validator(root)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("referenceComposedRGBA: identity mismatch", completed.stdout + completed.stderr)
            finally:
                reference_path.write_bytes(original)

    def expect_json_failure(
        self,
        root: pathlib.Path,
        path: pathlib.Path,
        mutation,
        expected: str,
    ) -> None:
        original = path.read_bytes()
        try:
            payload = json.loads(original)
            mutation(payload)
            path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            completed = self.run_validator(root)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(expected, completed.stdout + completed.stderr)
        finally:
            path.write_bytes(original)

    def write_capture(self, root: pathlib.Path) -> None:
        input_directory = root / "inputs"
        frame_directory = root / "frames"
        input_directory.mkdir(parents=True)
        frame_directory.mkdir(parents=True)
        fixture_id = "SYNTHETIC"
        input_path = input_directory / f"{fixture_id}.apng"
        input_path.write_bytes(unit_fixture.make_apng())
        image = reference.parse_apng(input_path.read_bytes())
        best_composed = reference.compose_frames(image)

        apple_frames: dict[tuple[str, int], bytes] = {
            (fixture_id, index): frame.premultiplied_rgba
            for index, frame in enumerate(best_composed)
        }
        candidates = []
        candidate_frames = {}
        for premultiply in validator_module.ROUNDING_MODES:
            for orientation in validator_module.ORIENTATIONS:
                summary, frames = validator_module.summarize_candidate(
                    {fixture_id: image},
                    apple_frames,
                    premultiply,
                    orientation,
                )
                candidates.append(summary)
                candidate_frames[(premultiply, orientation)] = frames
        candidates.sort(
            key=lambda item: (
                -item["exactFrameCount"],
                item["differentPixelCount"],
                item["totalAbsoluteChannelDifference"],
                item["maximumChannelDifference"],
                item["premultiplyRounding"] != "nearest",
                item["orientation"] != "top-down",
            )
        )
        best = candidates[0]
        best_key = (
            best["premultiplyRounding"],
            best["orientation"],
        )
        frames = []
        artifact_inventory = {}
        raw_total = 0
        composed_total = 0
        for index, raw_frame in enumerate(image.frames):
            paths = {
                "rawSubrectRGBA": frame_directory / f"{fixture_id}-frame-{index:02d}-raw-subrect.rgba",
                "referenceComposedRGBA": frame_directory / f"{fixture_id}-frame-{index:02d}-reference.rgba",
                "appleImageIORGBA": frame_directory / f"{fixture_id}-frame-{index:02d}-AppleImageIO.rgba",
                "imageCraftRGBA": frame_directory / f"{fixture_id}-frame-{index:02d}-ImageCraft.rgba",
            }
            reference_bytes = candidate_frames[best_key][(fixture_id, index)]
            paths["rawSubrectRGBA"].write_bytes(raw_frame.rgba)
            paths["referenceComposedRGBA"].write_bytes(reference_bytes)
            paths["appleImageIORGBA"].write_bytes(reference_bytes)
            paths["imageCraftRGBA"].write_bytes(reference_bytes)
            raw_total += len(raw_frame.rgba)
            composed_total += len(reference_bytes)
            for path in paths.values():
                artifact_inventory[str(path.relative_to(root))] = identity(path)
            no_difference = validator_module.difference(reference_bytes, reference_bytes)
            frames.append(
                {
                    "index": index,
                    "control": {
                        "x": raw_frame.control.x_offset,
                        "y": raw_frame.control.y_offset,
                        "width": raw_frame.control.width,
                        "height": raw_frame.control.height,
                        "disposeOp": raw_frame.control.dispose_op,
                        "blendOp": raw_frame.control.blend_op,
                        "durationNanoseconds": raw_frame.control.duration_nanoseconds,
                    },
                    **{field: identity(path) for field, path in paths.items()},
                    "referenceVersusAppleImageIO": no_difference,
                    "referenceVersusImageCraft": no_difference,
                    "referenceAppleExact": True,
                    "referenceImageCraftExact": True,
                }
            )
        artifact_inventory[str(input_path.relative_to(root))] = identity(input_path)
        input_identity = identity(input_path)
        sources = {
            "Fovea": snapshot("0" * 40, "1" * 40, "2" * 40),
            "ImageCraft": snapshot("3" * 40, "4" * 40, "5" * 40),
            "APNGKit": snapshot("6" * 40, "7" * 40, "7" * 40),
        }
        governing = {
            "referenceDecoder": identity(PERFORMANCE / "w5_apng_reference.py"),
            "captureRunner": identity(PERFORMANCE / "capture_w5_apng_reference.py"),
            "validator": identity(PERFORMANCE / "validate_w5_apng_reference.py"),
            "syntheticContract": identity(PERFORMANCE / "test_w5_apng_reference.py"),
            "sourceOracleIdentity": {"path": "/unavailable/source-identity.json", "byteCount": 1, "sha256": "8" * 64},
            "sourceOracleManifest": {"path": "/unavailable/capture-manifest.json", "byteCount": 1, "sha256": "9" * 64},
            "sourceOracleAggregate": {"path": "/unavailable/aggregate.json", "byteCount": 1, "sha256": "a" * 64},
        }
        tied = [
            item
            for item in candidates
            if (
                item["exactFrameCount"],
                item["differentPixelCount"],
                item["totalAbsoluteChannelDifference"],
                item["maximumChannelDifference"],
            )
            == (
                best["exactFrameCount"],
                best["differentPixelCount"],
                best["totalAbsoluteChannelDifference"],
                best["maximumChannelDifference"],
            )
        ]
        report = {
            "schemaVersion": 1,
            "formalClaimEligible": False,
            "status": "owned-reference-byte-exact",
            "sourceOracle": {
                "root": "/unavailable",
                "sourceIdentity": governing["sourceOracleIdentity"],
                "captureManifest": governing["sourceOracleManifest"],
                "aggregate": governing["sourceOracleAggregate"],
                "validatedBeforeCapture": True,
                "schemaVersions": {"identity": 3, "manifest": 3, "aggregate": 3},
            },
            "sourceBefore": sources,
            "sourceAfter": sources,
            "sourceUnchangedDuringCapture": True,
            "governingFilesBefore": governing,
            "governingFilesAfter": governing,
            "governingFilesUnchangedDuringCapture": True,
            "retainedInputsBefore": {fixture_id: input_identity},
            "retainedInputsAfter": {fixture_id: input_identity},
            "retainedInputsUnchangedDuringCapture": True,
            "calibration": {
                "best": best,
                "tiedBest": tied,
                "candidates": candidates,
                "interpretation": "synthetic calibration",
            },
            "allReferenceAppleImageIOExact": True,
            "allReferenceImageCraftExact": True,
            "fixtureResults": {
                fixture_id: {
                    "role": "synthetic-subrect-disposal",
                    "canvasWidth": image.canvas_width,
                    "canvasHeight": image.canvas_height,
                    "frameCount": len(image.frames),
                    "numPlays": image.num_plays,
                    "bitDepth": image.bit_depth,
                    "colorType": image.color_type,
                    "rawSubrectRGBAByteCount": raw_total,
                    "referenceComposedRGBAByteCount": composed_total,
                    "composedOverRawSubrectByteRatio": composed_total / raw_total,
                    "frames": frames,
                }
            },
            "artifactInventory": dict(sorted(artifact_inventory.items())),
            "claimBoundary": ["synthetic contract"],
        }
        (root / "report.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n"
        )


if __name__ == "__main__":
    unittest.main()
