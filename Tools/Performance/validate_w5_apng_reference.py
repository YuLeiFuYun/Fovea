#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import pathlib
import sys

PERFORMANCE = pathlib.Path(__file__).resolve().parent


def load_module(name: str, path: pathlib.Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


reference = load_module(
    "w5_apng_owned_reference_validator",
    PERFORMANCE / "w5_apng_reference.py",
)

ROUNDING_MODES = ("floor", "nearest", "ceil")
ORIENTATIONS = ("top-down", "bottom-up")


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"path": str(path), "byteCount": len(data), "sha256": sha256(data)}


def identity_matches(record: object, path: pathlib.Path, label: str) -> None:
    if not isinstance(record, dict):
        fail(f"{label}: identity must be an object")
    data = path.read_bytes()
    if record.get("byteCount") != len(data) or record.get("sha256") != sha256(data):
        fail(f"{label}: identity mismatch")


def is_git_object_id(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 40
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_snapshot(name: str, snapshot: object) -> None:
    if not isinstance(snapshot, dict):
        fail(f"{name}: source snapshot missing")
    for field in ("headCommit", "headTree", "workingTree"):
        if not is_git_object_id(snapshot.get(field)):
            fail(f"{name}: invalid {field}")
    if not isinstance(snapshot.get("dirty"), bool):
        fail(f"{name}: invalid dirty state")
    if snapshot["dirty"] != (snapshot["headTree"] != snapshot["workingTree"]):
        fail(f"{name}: dirty state does not match tree identity")
    if snapshot.get("identityAlgorithm") != "git-temporary-index-add-all-write-tree-v1":
        fail(f"{name}: unsupported source identity algorithm")


def contained_file(root: pathlib.Path, value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str):
        fail(f"{label}: path must be a string")
    path = pathlib.Path(value).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        fail(f"{label}: path escapes capture root: {path}")
        raise AssertionError from error
    if not path.is_file():
        fail(f"{label}: missing file: {path}")
    return path


def difference(lhs: bytes, rhs: bytes) -> dict[str, object]:
    if len(lhs) != len(rhs):
        return {
            "sameLength": False,
            "differentPixelCount": None,
            "differentPixelFraction": None,
            "maximumChannelDifference": None,
            "meanAbsoluteChannelDifference": None,
            "totalAbsoluteChannelDifference": None,
        }
    if len(lhs) % 4 != 0:
        fail("RGBA byte count is not divisible by four")
    different_pixels = 0
    maximum_channel_difference = 0
    total_absolute_channel_difference = 0
    for offset in range(0, len(lhs), 4):
        pixel_differs = False
        for channel in range(4):
            channel_difference = abs(lhs[offset + channel] - rhs[offset + channel])
            maximum_channel_difference = max(
                maximum_channel_difference, channel_difference
            )
            total_absolute_channel_difference += channel_difference
            pixel_differs = pixel_differs or channel_difference != 0
        different_pixels += int(pixel_differs)
    pixel_count = len(lhs) // 4
    return {
        "sameLength": True,
        "differentPixelCount": different_pixels,
        "differentPixelFraction": different_pixels / pixel_count,
        "maximumChannelDifference": maximum_channel_difference,
        "meanAbsoluteChannelDifference": total_absolute_channel_difference / len(lhs),
        "totalAbsoluteChannelDifference": total_absolute_channel_difference,
    }


def differences_equal(lhs: object, rhs: dict[str, object]) -> bool:
    if not isinstance(lhs, dict):
        return False
    for key in (
        "sameLength",
        "differentPixelCount",
        "maximumChannelDifference",
        "totalAbsoluteChannelDifference",
    ):
        if lhs.get(key) != rhs[key]:
            return False
    for key in ("differentPixelFraction", "meanAbsoluteChannelDifference"):
        left = lhs.get(key)
        right = rhs[key]
        if left is None or right is None:
            if left != right:
                return False
        elif not isinstance(left, (int, float)) or not math.isclose(
            float(left), float(right), rel_tol=0, abs_tol=1e-15
        ):
            return False
    return True


def orient(data: bytes, width: int, height: int, orientation: str) -> bytes:
    if orientation == "top-down":
        return data
    if orientation == "bottom-up":
        return reference.vertically_flip_rgba(data, width, height)
    fail(f"unsupported orientation: {orientation}")
    raise AssertionError


def summarize_candidate(
    parsed_images: dict[str, object],
    apple_frames: dict[tuple[str, int], bytes],
    premultiply_rounding: str,
    orientation: str,
) -> tuple[dict[str, object], dict[tuple[str, int], bytes]]:
    exact_frames = 0
    total_frames = 0
    different_pixels = 0
    total_absolute_difference = 0
    maximum_channel_difference = 0
    frames: dict[tuple[str, int], bytes] = {}
    for fixture_id, image in parsed_images.items():
        composed = reference.compose_frames(
            image,
            premultiply_rounding=premultiply_rounding,
        )
        for index, frame in enumerate(composed):
            candidate = orient(
                frame.premultiplied_rgba,
                image.canvas_width,
                image.canvas_height,
                orientation,
            )
            frames[(fixture_id, index)] = candidate
            result = difference(candidate, apple_frames[(fixture_id, index)])
            exact_frames += int(
                sha256(candidate) == sha256(apple_frames[(fixture_id, index)])
            )
            total_frames += 1
            different_pixels += int(result["differentPixelCount"] or 0)
            total_absolute_difference += int(
                result["totalAbsoluteChannelDifference"] or 0
            )
            maximum_channel_difference = max(
                maximum_channel_difference,
                int(result["maximumChannelDifference"] or 0),
            )
    return (
        {
            "compositionModel": reference.STRAIGHT_ALPHA_COMPOSITION_MODEL,
            "premultiplyRounding": premultiply_rounding,
            "orientation": orientation,
            "exactFrameCount": exact_frames,
            "totalFrameCount": total_frames,
            "differentPixelCount": different_pixels,
            "totalAbsoluteChannelDifference": total_absolute_difference,
            "maximumChannelDifference": maximum_channel_difference,
        },
        frames,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_directory", type=pathlib.Path)
    args = parser.parse_args()
    root = args.capture_directory.resolve()
    report_path = root / "report.json"
    if not report_path.is_file():
        fail(f"missing report: {report_path}")
    report = json.loads(report_path.read_text())
    if report.get("schemaVersion") != 1:
        fail("APNG reference report schema mismatch")
    if report.get("formalClaimEligible") is not False:
        fail("APNG reference report must not activate a formal claim")
    if report.get("sourceUnchangedDuringCapture") is not True:
        fail("source changed during APNG reference capture")
    if report.get("governingFilesUnchangedDuringCapture") is not True:
        fail("governing file changed during APNG reference capture")
    if report.get("retainedInputsUnchangedDuringCapture") is not True:
        fail("retained input changed during APNG reference capture")
    if report.get("sourceBefore") != report.get("sourceAfter"):
        fail("source before/after mismatch")
    if report.get("governingFilesBefore") != report.get("governingFilesAfter"):
        fail("governing file before/after mismatch")
    if report.get("retainedInputsBefore") != report.get("retainedInputsAfter"):
        fail("retained input before/after mismatch")

    source_before = report.get("sourceBefore")
    if not isinstance(source_before, dict):
        fail("source snapshot section is invalid")
    for name in ("Fovea", "ImageCraft", "APNGKit"):
        validate_snapshot(name, source_before.get(name))

    governing = report.get("governingFilesBefore")
    if not isinstance(governing, dict):
        fail("governing file section is invalid")
    local_governing = {
        "referenceDecoder": PERFORMANCE / "w5_apng_reference.py",
        "captureRunner": PERFORMANCE / "capture_w5_apng_reference.py",
        "validator": pathlib.Path(__file__).resolve(),
        "syntheticContract": PERFORMANCE / "test_w5_apng_reference.py",
    }
    for name, path in local_governing.items():
        identity_matches(governing.get(name), path, name)
    for name in ("sourceOracleIdentity", "sourceOracleManifest", "sourceOracleAggregate"):
        record = governing.get(name)
        if (
            not isinstance(record, dict)
            or not isinstance(record.get("byteCount"), int)
            or record["byteCount"] <= 0
            or not isinstance(record.get("sha256"), str)
            or len(record["sha256"]) != 64
        ):
            fail(f"{name}: invalid source oracle identity")

    retained_inputs = report.get("retainedInputsBefore")
    fixture_results = report.get("fixtureResults")
    if not isinstance(retained_inputs, dict) or not isinstance(fixture_results, dict):
        fail("retained input or fixture result section is invalid")
    if set(retained_inputs) != set(fixture_results):
        fail("retained input and fixture result sets differ")

    parsed_images = {}
    apple_frames: dict[tuple[str, int], bytes] = {}
    imagecraft_frames: dict[tuple[str, int], bytes] = {}
    expected_artifacts: set[pathlib.Path] = set()
    artifact_inventory = report.get("artifactInventory")
    if not isinstance(artifact_inventory, dict):
        fail("artifact inventory is invalid")

    for fixture_id, input_record in retained_inputs.items():
        input_path = root / "inputs" / f"{fixture_id}.apng"
        input_path = contained_file(root, str(input_path), f"{fixture_id} input")
        identity_matches(input_record, input_path, f"{fixture_id} input")
        expected_artifacts.add(input_path)
        image = reference.parse_apng(input_path.read_bytes())
        parsed_images[fixture_id] = image
        result = fixture_results[fixture_id]
        if not isinstance(result, dict):
            fail(f"{fixture_id}: result must be an object")
        if (
            result.get("canvasWidth") != image.canvas_width
            or result.get("canvasHeight") != image.canvas_height
            or result.get("frameCount") != len(image.frames)
            or result.get("numPlays") != image.num_plays
            or result.get("bitDepth") != image.bit_depth
            or result.get("colorType") != image.color_type
        ):
            fail(f"{fixture_id}: parsed image metadata mismatch")
        frames = result.get("frames")
        if not isinstance(frames, list) or len(frames) != len(image.frames):
            fail(f"{fixture_id}: frame result count mismatch")
        raw_subrect_bytes = 0
        composed_bytes = 0
        for index, (raw_frame, frame_result) in enumerate(zip(image.frames, frames)):
            if not isinstance(frame_result, dict) or frame_result.get("index") != index:
                fail(f"{fixture_id}: frame index mismatch")
            control = frame_result.get("control")
            expected_control = {
                "x": raw_frame.control.x_offset,
                "y": raw_frame.control.y_offset,
                "width": raw_frame.control.width,
                "height": raw_frame.control.height,
                "disposeOp": raw_frame.control.dispose_op,
                "blendOp": raw_frame.control.blend_op,
                "durationNanoseconds": raw_frame.control.duration_nanoseconds,
            }
            if control != expected_control:
                fail(f"{fixture_id}: frame control mismatch at {index}")
            paths = {
                "rawSubrectRGBA": root
                / "frames"
                / f"{fixture_id}-frame-{index:02d}-raw-subrect.rgba",
                "referenceComposedRGBA": root
                / "frames"
                / f"{fixture_id}-frame-{index:02d}-reference.rgba",
                "appleImageIORGBA": root
                / "frames"
                / f"{fixture_id}-frame-{index:02d}-AppleImageIO.rgba",
                "imageCraftRGBA": root
                / "frames"
                / f"{fixture_id}-frame-{index:02d}-ImageCraft.rgba",
            }
            loaded = {}
            for field, path in paths.items():
                contained = contained_file(root, str(path), f"{fixture_id} {index} {field}")
                identity_matches(
                    frame_result.get(field),
                    contained,
                    f"{fixture_id} {index} {field}",
                )
                expected_artifacts.add(contained)
                loaded[field] = contained.read_bytes()
            if loaded["rawSubrectRGBA"] != raw_frame.rgba:
                fail(f"{fixture_id}: raw subrect bytes mismatch at {index}")
            expected_raw_count = raw_frame.control.width * raw_frame.control.height * 4
            expected_canvas_count = image.canvas_width * image.canvas_height * 4
            if len(loaded["rawSubrectRGBA"]) != expected_raw_count:
                fail(f"{fixture_id}: raw subrect byte count mismatch at {index}")
            for field in (
                "referenceComposedRGBA",
                "appleImageIORGBA",
                "imageCraftRGBA",
            ):
                if len(loaded[field]) != expected_canvas_count:
                    fail(f"{fixture_id}: full-canvas byte count mismatch at {index}")
            apple_frames[(fixture_id, index)] = loaded["appleImageIORGBA"]
            imagecraft_frames[(fixture_id, index)] = loaded["imageCraftRGBA"]
            raw_subrect_bytes += expected_raw_count
            composed_bytes += expected_canvas_count
        if result.get("rawSubrectRGBAByteCount") != raw_subrect_bytes:
            fail(f"{fixture_id}: raw subrect total mismatch")
        if result.get("referenceComposedRGBAByteCount") != composed_bytes:
            fail(f"{fixture_id}: composed total mismatch")
        ratio = result.get("composedOverRawSubrectByteRatio")
        if not isinstance(ratio, (int, float)) or not math.isclose(
            float(ratio), composed_bytes / raw_subrect_bytes, rel_tol=0, abs_tol=1e-15
        ):
            fail(f"{fixture_id}: composed/raw ratio mismatch")

    calibration = report.get("calibration")
    if not isinstance(calibration, dict):
        fail("calibration section is invalid")
    reported_candidates = calibration.get("candidates")
    if not isinstance(reported_candidates, list) or len(reported_candidates) != 6:
        fail("calibration candidate count mismatch")
    computed_candidates = []
    candidate_frames = {}
    for premultiply_rounding in ROUNDING_MODES:
        for orientation in ORIENTATIONS:
            summary, frames = summarize_candidate(
                parsed_images,
                apple_frames,
                premultiply_rounding,
                orientation,
            )
            computed_candidates.append(summary)
            candidate_frames[(premultiply_rounding, orientation)] = frames
    computed_candidates.sort(
        key=lambda item: (
            -item["exactFrameCount"],
            item["differentPixelCount"],
            item["totalAbsoluteChannelDifference"],
            item["maximumChannelDifference"],
            item["premultiplyRounding"] != "nearest",
            item["orientation"] != "top-down",
        )
    )
    if reported_candidates != computed_candidates:
        fail("calibration candidate results mismatch")
    best = calibration.get("best")
    if best != computed_candidates[0]:
        fail("calibration best candidate mismatch")
    if best.get("compositionModel") != reference.STRAIGHT_ALPHA_COMPOSITION_MODEL:
        fail("calibration composition model mismatch")
    best_key = (
        best["premultiplyRounding"],
        best["orientation"],
    )
    best_frames = candidate_frames[best_key]
    all_reference_apple_exact = True
    all_reference_imagecraft_exact = True
    for fixture_id, result in fixture_results.items():
        image = parsed_images[fixture_id]
        for index, frame_result in enumerate(result["frames"]):
            reference_path = root / "frames" / f"{fixture_id}-frame-{index:02d}-reference.rgba"
            reference_bytes = reference_path.read_bytes()
            expected_reference = best_frames[(fixture_id, index)]
            if reference_bytes != expected_reference:
                fail(f"{fixture_id}: calibrated reference bytes mismatch at {index}")
            apple = apple_frames[(fixture_id, index)]
            imagecraft = imagecraft_frames[(fixture_id, index)]
            apple_difference = difference(reference_bytes, apple)
            imagecraft_difference = difference(reference_bytes, imagecraft)
            if not differences_equal(
                frame_result.get("referenceVersusAppleImageIO"), apple_difference
            ):
                fail(f"{fixture_id}: Apple difference mismatch at {index}")
            if not differences_equal(
                frame_result.get("referenceVersusImageCraft"), imagecraft_difference
            ):
                fail(f"{fixture_id}: ImageCraft difference mismatch at {index}")
            apple_exact = sha256(reference_bytes) == sha256(apple)
            imagecraft_exact = sha256(reference_bytes) == sha256(imagecraft)
            if frame_result.get("referenceAppleExact") != apple_exact:
                fail(f"{fixture_id}: Apple exact flag mismatch at {index}")
            if frame_result.get("referenceImageCraftExact") != imagecraft_exact:
                fail(f"{fixture_id}: ImageCraft exact flag mismatch at {index}")
            all_reference_apple_exact = all_reference_apple_exact and apple_exact
            all_reference_imagecraft_exact = (
                all_reference_imagecraft_exact and imagecraft_exact
            )

    if report.get("allReferenceAppleImageIOExact") != all_reference_apple_exact:
        fail("aggregate Apple exact flag mismatch")
    if report.get("allReferenceImageCraftExact") != all_reference_imagecraft_exact:
        fail("aggregate ImageCraft exact flag mismatch")
    expected_status = (
        "owned-reference-byte-exact"
        if all_reference_apple_exact and all_reference_imagecraft_exact
        else "owned-reference-not-byte-exact"
    )
    if report.get("status") != expected_status:
        fail("APNG reference status mismatch")

    actual_artifacts = {
        path.resolve()
        for directory in (root / "inputs", root / "frames")
        for path in directory.iterdir()
        if path.is_file()
    }
    if actual_artifacts != expected_artifacts:
        fail(
            "artifact set mismatch: "
            f"unexpected={sorted(str(path) for path in actual_artifacts - expected_artifacts)} "
            f"missing={sorted(str(path) for path in expected_artifacts - actual_artifacts)}"
        )
    expected_inventory = {
        str(path.relative_to(root)): {
            "path": str(path),
            "byteCount": path.stat().st_size,
            "sha256": sha256(path.read_bytes()),
        }
        for path in sorted(expected_artifacts)
    }
    if artifact_inventory != expected_inventory:
        fail("artifact inventory mismatch")
    print(report_path)
    print(
        f"best={best['compositionModel']}/{best['premultiplyRounding']}/"
        f"{best['orientation']} exact={best['exactFrameCount']}/{best['totalFrameCount']}"
    )


if __name__ == "__main__":
    main()
