#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent


def load_module(name: str, path: pathlib.Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


support = load_module(
    "w5_apng_reference_capture_support",
    PERFORMANCE / "capture_w5_animated_codec.py",
)
reference = load_module(
    "w5_apng_owned_reference",
    PERFORMANCE / "w5_apng_reference.py",
)

ROUNDING_MODES = ("floor", "nearest", "ceil")
ORIENTATIONS = ("top-down", "bottom-up")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
        raise SystemExit("RGBA byte count is not divisible by four")
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


def orient(data: bytes, width: int, height: int, orientation: str) -> bytes:
    if orientation == "top-down":
        return data
    if orientation == "bottom-up":
        return reference.vertically_flip_rgba(data, width, height)
    raise SystemExit(f"unsupported orientation: {orientation}")


def contained_file(root: pathlib.Path, value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str):
        raise SystemExit(f"{label}: path must be a string")
    path = pathlib.Path(value).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise SystemExit(f"{label}: path escapes evidence root: {path}") from error
    if not path.is_file():
        raise SystemExit(f"{label}: missing file: {path}")
    return path


def descriptor_tuple(frame: dict) -> tuple[int, int, int, int, str, str]:
    rect = frame.get("imageCraftDescriptorRect")
    if not isinstance(rect, dict):
        raise SystemExit("missing ImageCraft descriptor rect")
    return (
        int(rect["x"]),
        int(rect["y"]),
        int(rect["width"]),
        int(rect["height"]),
        str(frame["imageCraftDisposal"]),
        str(frame["imageCraftBlend"]),
    )


def control_tuple(control) -> tuple[int, int, int, int, str, str]:
    disposal = {0: "none", 1: "background", 2: "previous"}[control.dispose_op]
    blend = {0: "source", 1: "over"}[control.blend_op]
    return (
        control.x_offset,
        control.y_offset,
        control.width,
        control.height,
        disposal,
        blend,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--oracle-evidence",
        type=pathlib.Path,
        default=ROOT / ".artifacts/performance/w5-apng-composition-oracle-v5",
    )
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    oracle_root = args.oracle_evidence.resolve()
    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)

    oracle_validator = PERFORMANCE / "validate_w5_apng_composition_oracle.py"
    completed = subprocess.run(
        [sys.executable, str(oracle_validator), str(oracle_root)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        raise SystemExit("source APNG oracle evidence failed validation")

    source_identity_path = oracle_root / "source-identity.json"
    capture_manifest_path = oracle_root / "capture-manifest.json"
    aggregate_path = oracle_root / "aggregate.json"
    source_identity = json.loads(source_identity_path.read_text())
    oracle_manifest = json.loads(capture_manifest_path.read_text())
    oracle_aggregate = json.loads(aggregate_path.read_text())
    if source_identity.get("schemaVersion") != 3:
        raise SystemExit("source APNG oracle identity schema mismatch")
    fixture_contracts = source_identity.get("fixtureContract")
    inputs = source_identity.get("inputs")
    if not isinstance(fixture_contracts, dict) or not isinstance(inputs, dict):
        raise SystemExit("source APNG oracle fixture contract is invalid")

    apngkit_root = pathlib.Path(
        source_identity["sources"]["APNGKit"]["root"]
    ).resolve()
    imagecraft_root = pathlib.Path(
        source_identity["sources"]["ImageCraft"]["root"]
    ).resolve()
    source_before = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(imagecraft_root),
        "APNGKit": support.git_snapshot(apngkit_root),
    }
    governing_before = {
        "referenceDecoder": support.file_identity(PERFORMANCE / "w5_apng_reference.py"),
        "captureRunner": support.file_identity(pathlib.Path(__file__).resolve()),
        "validator": support.file_identity(
            PERFORMANCE / "validate_w5_apng_reference.py"
        ),
        "syntheticContract": support.file_identity(
            PERFORMANCE / "test_w5_apng_reference.py"
        ),
        "sourceOracleIdentity": support.file_identity(source_identity_path),
        "sourceOracleManifest": support.file_identity(capture_manifest_path),
        "sourceOracleAggregate": support.file_identity(aggregate_path),
    }

    inputs_directory = output / "inputs"
    inputs_directory.mkdir(parents=True)
    retained_inputs: dict[str, dict[str, object]] = {}
    parsed_images = {}
    source_reports = {}
    source_sidecars = {}
    total_frame_count = 0

    for fixture_id, contract in fixture_contracts.items():
        input_record = inputs.get(fixture_id)
        if not isinstance(input_record, dict):
            raise SystemExit(f"missing source input identity: {fixture_id}")
        source_input = pathlib.Path(str(input_record["path"])).resolve()
        source_bytes = source_input.read_bytes()
        if (
            len(source_bytes) != input_record.get("byteCount")
            or sha256(source_bytes) != input_record.get("sha256")
        ):
            raise SystemExit(f"source input bytes changed: {fixture_id}")
        retained_input = inputs_directory / f"{fixture_id}.apng"
        retained_input.write_bytes(source_bytes)
        retained_inputs[fixture_id] = support.file_identity(retained_input)
        image = reference.parse_apng(source_bytes)
        parsed_images[fixture_id] = image
        report_path = oracle_root / f"{fixture_id}.json"
        report = json.loads(report_path.read_text())
        source_reports[fixture_id] = report
        frames = report.get("frames")
        if not isinstance(frames, list) or len(frames) != len(image.frames):
            raise SystemExit(f"frame count mismatch against source oracle: {fixture_id}")
        if (
            image.canvas_width != contract.get("expectedCanvasWidth")
            or image.canvas_height != contract.get("expectedCanvasHeight")
            or len(image.frames) != contract.get("expectedFrameCount")
        ):
            raise SystemExit(f"parsed APNG contract mismatch: {fixture_id}")
        if [frame.control.duration_nanoseconds for frame in image.frames] != report[
            "imageCraft"
        ]["frameDurationsNanoseconds"]:
            raise SystemExit(f"timeline mismatch against source oracle: {fixture_id}")
        for index, (raw_frame, source_frame) in enumerate(zip(image.frames, frames)):
            if control_tuple(raw_frame.control) != descriptor_tuple(source_frame):
                raise SystemExit(
                    f"raw APNG control mismatch: {fixture_id} frame {index}"
                )
            apple = contained_file(
                oracle_root,
                source_frame.get("appleImageIORGBAPath"),
                f"{fixture_id} frame {index} AppleImageIO",
            ).read_bytes()
            imagecraft = contained_file(
                oracle_root,
                source_frame.get("imageCraftRGBAPath"),
                f"{fixture_id} frame {index} ImageCraft",
            ).read_bytes()
            source_sidecars[(fixture_id, index)] = {
                "AppleImageIO": apple,
                "ImageCraft": imagecraft,
            }
            total_frame_count += 1

    calibration_candidates = []
    composed_candidates = {}
    for premultiply_rounding in ROUNDING_MODES:
        for orientation in ORIENTATIONS:
            key = (premultiply_rounding, orientation)
            exact_frames = 0
            different_pixels = 0
            total_absolute_difference = 0
            maximum_channel_difference = 0
            candidate_frames = {}
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
                    candidate_frames[(fixture_id, index)] = candidate
                    apple = source_sidecars[(fixture_id, index)]["AppleImageIO"]
                    result = difference(candidate, apple)
                    if sha256(candidate) == sha256(apple):
                        exact_frames += 1
                    different_pixels += int(result["differentPixelCount"] or 0)
                    total_absolute_difference += int(
                        result["totalAbsoluteChannelDifference"] or 0
                    )
                    maximum_channel_difference = max(
                        maximum_channel_difference,
                        int(result["maximumChannelDifference"] or 0),
                    )
            composed_candidates[key] = candidate_frames
            calibration_candidates.append(
                {
                    "compositionModel": reference.STRAIGHT_ALPHA_COMPOSITION_MODEL,
                    "premultiplyRounding": premultiply_rounding,
                    "orientation": orientation,
                    "exactFrameCount": exact_frames,
                    "totalFrameCount": total_frame_count,
                    "differentPixelCount": different_pixels,
                    "totalAbsoluteChannelDifference": total_absolute_difference,
                    "maximumChannelDifference": maximum_channel_difference,
                }
            )

    calibration_candidates.sort(
        key=lambda item: (
            -item["exactFrameCount"],
            item["differentPixelCount"],
            item["totalAbsoluteChannelDifference"],
            item["maximumChannelDifference"],
            item["premultiplyRounding"] != "nearest",
            item["orientation"] != "top-down",
        )
    )
    best = calibration_candidates[0]
    best_key = (
        best["premultiplyRounding"],
        best["orientation"],
    )
    best_frames = composed_candidates[best_key]
    tied_best = [
        item
        for item in calibration_candidates
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

    frame_directory = output / "frames"
    frame_directory.mkdir()
    fixture_results = {}
    artifact_inventory = {}
    all_reference_apple_exact = True
    all_reference_imagecraft_exact = True
    for fixture_id, image in parsed_images.items():
        report = source_reports[fixture_id]
        frame_results = []
        raw_subrect_bytes = 0
        composed_bytes = 0
        for index, (raw_frame, source_frame) in enumerate(
            zip(image.frames, report["frames"])
        ):
            raw_path = frame_directory / f"{fixture_id}-frame-{index:02d}-raw-subrect.rgba"
            reference_path = (
                frame_directory / f"{fixture_id}-frame-{index:02d}-reference.rgba"
            )
            apple_path = frame_directory / f"{fixture_id}-frame-{index:02d}-AppleImageIO.rgba"
            imagecraft_path = frame_directory / f"{fixture_id}-frame-{index:02d}-ImageCraft.rgba"
            raw_path.write_bytes(raw_frame.rgba)
            reference_bytes = best_frames[(fixture_id, index)]
            reference_path.write_bytes(reference_bytes)
            apple_bytes = source_sidecars[(fixture_id, index)]["AppleImageIO"]
            imagecraft_bytes = source_sidecars[(fixture_id, index)]["ImageCraft"]
            apple_path.write_bytes(apple_bytes)
            imagecraft_path.write_bytes(imagecraft_bytes)
            raw_subrect_bytes += len(raw_frame.rgba)
            composed_bytes += len(reference_bytes)
            reference_apple_exact = sha256(reference_bytes) == sha256(apple_bytes)
            reference_imagecraft_exact = sha256(reference_bytes) == sha256(
                imagecraft_bytes
            )
            all_reference_apple_exact = (
                all_reference_apple_exact and reference_apple_exact
            )
            all_reference_imagecraft_exact = (
                all_reference_imagecraft_exact and reference_imagecraft_exact
            )
            frame_results.append(
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
                    "rawSubrectRGBA": support.file_identity(raw_path),
                    "referenceComposedRGBA": support.file_identity(reference_path),
                    "appleImageIORGBA": support.file_identity(apple_path),
                    "imageCraftRGBA": support.file_identity(imagecraft_path),
                    "referenceVersusAppleImageIO": difference(
                        reference_bytes, apple_bytes
                    ),
                    "referenceVersusImageCraft": difference(
                        reference_bytes, imagecraft_bytes
                    ),
                    "referenceAppleExact": reference_apple_exact,
                    "referenceImageCraftExact": reference_imagecraft_exact,
                }
            )
            for path in (raw_path, reference_path, apple_path, imagecraft_path):
                artifact_inventory[str(path.relative_to(output))] = support.file_identity(
                    path
                )
        fixture_results[fixture_id] = {
            "role": fixture_contracts[fixture_id]["role"],
            "canvasWidth": image.canvas_width,
            "canvasHeight": image.canvas_height,
            "frameCount": len(image.frames),
            "numPlays": image.num_plays,
            "bitDepth": image.bit_depth,
            "colorType": image.color_type,
            "rawSubrectRGBAByteCount": raw_subrect_bytes,
            "referenceComposedRGBAByteCount": composed_bytes,
            "composedOverRawSubrectByteRatio": composed_bytes / raw_subrect_bytes,
            "frames": frame_results,
        }

    for fixture_id, record in retained_inputs.items():
        path = inputs_directory / f"{fixture_id}.apng"
        artifact_inventory[str(path.relative_to(output))] = support.file_identity(path)

    source_after = {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": support.git_snapshot(imagecraft_root),
        "APNGKit": support.git_snapshot(apngkit_root),
    }
    governing_after = {
        "referenceDecoder": support.file_identity(PERFORMANCE / "w5_apng_reference.py"),
        "captureRunner": support.file_identity(pathlib.Path(__file__).resolve()),
        "validator": support.file_identity(
            PERFORMANCE / "validate_w5_apng_reference.py"
        ),
        "syntheticContract": support.file_identity(
            PERFORMANCE / "test_w5_apng_reference.py"
        ),
        "sourceOracleIdentity": support.file_identity(source_identity_path),
        "sourceOracleManifest": support.file_identity(capture_manifest_path),
        "sourceOracleAggregate": support.file_identity(aggregate_path),
    }
    retained_inputs_after = {
        fixture_id: support.file_identity(inputs_directory / f"{fixture_id}.apng")
        for fixture_id in retained_inputs
    }
    sources_unchanged = source_before == source_after
    governing_unchanged = governing_before == governing_after
    inputs_unchanged = retained_inputs == retained_inputs_after

    report = {
        "schemaVersion": 1,
        "formalClaimEligible": False,
        "status": (
            "owned-reference-byte-exact"
            if all_reference_apple_exact and all_reference_imagecraft_exact
            else "owned-reference-not-byte-exact"
        ),
        "sourceOracle": {
            "root": str(oracle_root),
            "sourceIdentity": governing_before["sourceOracleIdentity"],
            "captureManifest": governing_before["sourceOracleManifest"],
            "aggregate": governing_before["sourceOracleAggregate"],
            "validatedBeforeCapture": True,
            "schemaVersions": {
                "identity": source_identity["schemaVersion"],
                "manifest": oracle_manifest["schemaVersion"],
                "aggregate": oracle_aggregate["schemaVersion"],
            },
        },
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": sources_unchanged,
        "governingFilesBefore": governing_before,
        "governingFilesAfter": governing_after,
        "governingFilesUnchangedDuringCapture": governing_unchanged,
        "retainedInputsBefore": retained_inputs,
        "retainedInputsAfter": retained_inputs_after,
        "retainedInputsUnchangedDuringCapture": inputs_unchanged,
        "calibration": {
            "best": best,
            "tiedBest": tied_best,
            "candidates": calibration_candidates,
            "interpretation": (
                "The APNG canvas uses the fixed straight-alpha exact-numerator floor "
                "composition model. Calibration selects only final premultiplication "
                "rounding and row orientation against already source-bound Apple ImageIO "
                "bytes; it does not alter parsed frame controls or input pixels."
            ),
        },
        "allReferenceAppleImageIOExact": all_reference_apple_exact,
        "allReferenceImageCraftExact": all_reference_imagecraft_exact,
        "fixtureResults": fixture_results,
        "artifactInventory": dict(sorted(artifact_inventory.items())),
        "claimBoundary": [
            "isolated Python executable specification, not production ImageCraft code",
            "calibrated byte layout against source-bound local Apple ImageIO evidence",
            "no peak-memory, energy, thermal, player, network, or physical-device claim",
            "raw subrect bytes and explicit disposal state demonstrate implementation feasibility only",
        ],
    }
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if not sources_unchanged:
        raise SystemExit(f"source changed during APNG reference capture: {report_path}")
    if not governing_unchanged:
        raise SystemExit(f"governing file changed during APNG reference capture: {report_path}")
    if not inputs_unchanged:
        raise SystemExit(f"retained input changed during APNG reference capture: {report_path}")

    validator = PERFORMANCE / "validate_w5_apng_reference.py"
    support.run([sys.executable, str(validator), str(output)], ROOT)
    print(report_path)


if __name__ == "__main__":
    main()
