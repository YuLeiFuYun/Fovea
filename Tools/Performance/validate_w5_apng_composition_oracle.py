#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import pathlib

APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"
DELEGATE_COMMIT = "ec3014ca2621c717f758d8718ec90e84b6e774b3"
FIXTURES = (
    "APNG-OVER-NONE",
    "APNG-OVER-BACKGROUND",
    "APNG-OVER-PREVIOUS",
    "APNG-SUBRECT-NONE",
    "APNG-SUBRECT-BACKGROUND",
    "APNG-SUBRECT-PREVIOUS-SOURCE",
)
COMPARATORS = {
    "ImageCraft": {
        "width": "imageCraftWidth",
        "height": "imageCraftHeight",
        "digest": "imageCraftPixelSHA256",
        "path": "imageCraftRGBAPath",
    },
    "APNGKit": {
        "width": "apngKitWidth",
        "height": "apngKitHeight",
        "digest": "apngKitPixelSHA256",
        "path": "apngKitRGBAPath",
    },
    "AppleImageIO": {
        "width": "appleImageIOWidth",
        "height": "appleImageIOHeight",
        "digest": "appleImageIOPixelSHA256",
        "path": "appleImageIORGBAPath",
    },
}
PAIRS = {
    "ImageCraftAPNGKit": (
        "ImageCraft",
        "APNGKit",
        "imageCraftVersusAPNGKit",
        "imageCraftAPNGKitAllFramesExact",
    ),
    "ImageCraftAppleImageIO": (
        "ImageCraft",
        "AppleImageIO",
        "imageCraftVersusAppleImageIO",
        "imageCraftAppleImageIOAllFramesExact",
    ),
    "APNGKitAppleImageIO": (
        "APNGKit",
        "AppleImageIO",
        "apngKitVersusAppleImageIO",
        "apngKitAppleImageIOAllFramesExact",
    ),
}


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"byteCount": len(data), "sha256": sha256(data)}


def is_git_object_id(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 40
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_snapshot(name: str, snapshot: object) -> dict:
    if not isinstance(snapshot, dict):
        fail(f"missing source snapshot: {name}")
    for key in ("headCommit", "headTree", "workingTree"):
        if not is_git_object_id(snapshot.get(key)):
            fail(f"{name}: invalid {key}")
    if snapshot.get("identityAlgorithm") != "git-temporary-index-add-all-write-tree-v1":
        fail(f"{name}: unsupported source identity algorithm")
    if not isinstance(snapshot.get("dirty"), bool):
        fail(f"{name}: invalid dirty state")
    if snapshot["dirty"] != (snapshot["workingTree"] != snapshot["headTree"]):
        fail(f"{name}: dirty state does not match tree identity")
    return snapshot


def contained_file(root: pathlib.Path, value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str):
        fail(f"{label}: path must be a string")
    path = pathlib.Path(value).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        fail(f"{label}: path escapes capture directory: {path}")
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
        }
    if len(lhs) % 4 != 0:
        fail("RGBA byte count is not divisible by four")
    different_pixels = 0
    maximum_difference = 0
    total_difference = 0
    for offset in range(0, len(lhs), 4):
        pixel_differs = False
        for channel in range(4):
            channel_difference = abs(lhs[offset + channel] - rhs[offset + channel])
            maximum_difference = max(maximum_difference, channel_difference)
            total_difference += channel_difference
            pixel_differs = pixel_differs or channel_difference != 0
        different_pixels += int(pixel_differs)
    pixel_count = len(lhs) // 4
    return {
        "sameLength": True,
        "differentPixelCount": different_pixels,
        "differentPixelFraction": different_pixels / pixel_count,
        "maximumChannelDifference": maximum_difference,
        "meanAbsoluteChannelDifference": total_difference / len(lhs),
    }


def differences_equal(reported: object, computed: dict[str, object]) -> bool:
    if not isinstance(reported, dict):
        return False
    for key in ("sameLength", "differentPixelCount", "maximumChannelDifference"):
        if reported.get(key) != computed[key]:
            return False
    for key in ("differentPixelFraction", "meanAbsoluteChannelDifference"):
        lhs = reported.get(key)
        rhs = computed[key]
        if lhs is None or rhs is None:
            if lhs != rhs:
                return False
        elif not isinstance(lhs, (float, int)) or not math.isclose(
            float(lhs), float(rhs), rel_tol=0, abs_tol=1e-15
        ):
            return False
    return True


def option_value(command: object, option: str) -> str:
    if not isinstance(command, list) or any(not isinstance(item, str) for item in command):
        fail("APNG oracle command must be a string array")
    if command.count(option) != 1:
        fail(f"APNG oracle command must contain exactly one {option}")
    index = command.index(option)
    if index + 1 >= len(command):
        fail(f"APNG oracle command is missing a value for {option}")
    return command[index + 1]


def write_json_atomic(path: pathlib.Path, payload: object) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def adjudication(pair_exact: dict[str, bool]) -> str:
    exact = {name for name, value in pair_exact.items() if value}
    if len(exact) == 3:
        return "all-three-exact"
    if exact == {"ImageCraftAppleImageIO"}:
        return "imagecraft-and-apple-exact-apngkit-differs"
    if exact == {"APNGKitAppleImageIO"}:
        return "apngkit-and-apple-exact-imagecraft-differs"
    if exact == {"ImageCraftAPNGKit"}:
        return "imagecraft-and-apngkit-exact-apple-differs"
    if not exact:
        return "no-exact-pair"
    return "mixed-exactness"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory", type=pathlib.Path)
    args = parser.parse_args()
    root = args.output_directory.resolve()

    manifest_path = root / "capture-manifest.json"
    identity_path = root / "source-identity.json"
    if not manifest_path.is_file() or not identity_path.is_file():
        fail("missing APNG oracle capture manifest or source identity")
    manifest = json.loads(manifest_path.read_text())
    identity = json.loads(identity_path.read_text())
    if manifest.get("schemaVersion") != 3 or identity.get("schemaVersion") != 3:
        fail("APNG oracle capture schema mismatch")
    if manifest.get("formalClaimEligible") is not False:
        fail("APNG oracle must not activate a formal claim")
    if manifest.get("sourceUnchangedDuringCapture") is not True:
        fail("source changed during APNG oracle capture")
    if manifest.get("inputsUnchangedDuringCapture") is not True:
        fail("input changed during APNG oracle capture")
    if manifest.get("systemComparatorsUnchangedDuringCapture") is not True:
        fail("system comparator changed during APNG oracle capture")
    if manifest.get("imageCraftMechanismAuditUnchangedDuringCapture") is not True:
        fail("ImageCraft mechanism audit changed during APNG oracle capture")
    if manifest.get("sourceBefore") != manifest.get("sourceAfter"):
        fail("source before/after mismatch")
    if manifest.get("inputsBefore") != manifest.get("inputsAfter"):
        fail("input before/after mismatch")
    if manifest.get("systemComparatorsBefore") != manifest.get("systemComparatorsAfter"):
        fail("system comparator before/after mismatch")
    if manifest.get("imageCraftMechanismAuditBefore") != manifest.get(
        "imageCraftMechanismAuditAfter"
    ):
        fail("ImageCraft mechanism audit before/after mismatch")
    if identity.get("sources") != manifest.get("sourceBefore"):
        fail("source identity document does not match capture source")
    if identity.get("inputs") != manifest.get("inputsBefore"):
        fail("source identity document does not match capture inputs")
    if identity.get("systemComparators") != manifest.get("systemComparatorsBefore"):
        fail("source identity document does not match system comparators")
    if identity.get("imageCraftMechanismAudit") != manifest.get(
        "imageCraftMechanismAuditBefore"
    ):
        fail("source identity document does not match ImageCraft mechanism audit")

    mechanism_audit = identity.get("imageCraftMechanismAudit")
    if not isinstance(mechanism_audit, dict) or mechanism_audit.get("schemaVersion") != 1:
        fail("ImageCraft mechanism audit is invalid")
    mechanism_files = mechanism_audit.get("files")
    observations = mechanism_audit.get("observations")
    if not isinstance(mechanism_files, dict) or len(mechanism_files) != 6:
        fail("ImageCraft mechanism audit file set is invalid")
    for name, file_record in mechanism_files.items():
        if (
            not isinstance(name, str)
            or not isinstance(file_record, dict)
            or not isinstance(file_record.get("byteCount"), int)
            or file_record["byteCount"] <= 0
            or not isinstance(file_record.get("sha256"), str)
            or len(file_record["sha256"]) != 64
        ):
            fail("ImageCraft mechanism audit file identity is invalid")
    required_observations = (
        "decodedAnimationFrameDocumentedAsCompleteComposedFrame",
        "providerDecodesSingleRequestedIndexDirectly",
        "providerWindowMapsEveryRequestedIndex",
        "rendererUsesImageIORequestedIndexMaterialization",
        "apngInspectorPublishesSubrectDisposalAndBlendMetadata",
        "separateDefaultMultiFrameRequiresAlignedImageIOIndices",
    )
    if not isinstance(observations, dict) or any(
        observations.get(name) is not True for name in required_observations
    ):
        fail("ImageCraft mechanism audit required observation is false")
    if observations.get("explicitCheckpointStateObservedInProviderOrRenderer") is not False:
        fail("ImageCraft mechanism audit unexpectedly observes checkpoint state")

    system_comparators = identity.get("systemComparators")
    if not isinstance(system_comparators, dict):
        fail("source identity system comparators are invalid")
    apple_identity = system_comparators.get("AppleImageIO")
    if not isinstance(apple_identity, dict):
        fail("Apple ImageIO system identity is missing")
    if apple_identity.get("frameworkIdentifier") != "com.apple.ImageIO":
        fail("Apple ImageIO framework identifier mismatch")
    for field in ("frameworkShortVersion", "frameworkBundleVersion"):
        if not isinstance(apple_identity.get(field), str) or not apple_identity[field]:
            fail(f"Apple ImageIO {field} is invalid")
    info_plist = apple_identity.get("infoPlist")
    if (
        not isinstance(info_plist, dict)
        or not isinstance(info_plist.get("byteCount"), int)
        or info_plist["byteCount"] <= 0
        or not isinstance(info_plist.get("sha256"), str)
        or len(info_plist["sha256"]) != 64
    ):
        fail("Apple ImageIO Info.plist identity is invalid")
    operating_system = apple_identity.get("operatingSystem")
    if not isinstance(operating_system, dict) or any(
        not isinstance(operating_system.get(field), str) or not operating_system[field]
        for field in ("productName", "productVersion", "buildVersion")
    ):
        fail("Apple ImageIO operating system identity is invalid")
    if (
        not isinstance(apple_identity.get("xcode"), list)
        or not apple_identity["xcode"]
        or not isinstance(apple_identity.get("swift"), list)
        or not apple_identity["swift"]
    ):
        fail("Apple ImageIO toolchain identity is invalid")

    identity_file = file_identity(identity_path)
    manifest_identity = manifest.get("sourceIdentity")
    if not isinstance(manifest_identity, dict):
        fail("capture manifest source identity is missing")
    if (
        manifest_identity.get("byteCount") != identity_file["byteCount"]
        or manifest_identity.get("sha256") != identity_file["sha256"]
    ):
        fail("source identity document digest mismatch")

    sources = identity.get("sources")
    if not isinstance(sources, dict):
        fail("source identity sources are invalid")
    for name in ("Fovea", "ImageCraft", "APNGKit", "Delegate"):
        validate_snapshot(name, sources.get(name))
    if sources["APNGKit"].get("headCommit") != APNGKIT_COMMIT:
        fail("APNGKit exact commit mismatch")
    if sources["APNGKit"].get("dirty") is not False:
        fail("APNGKit must be clean")
    if sources["Delegate"].get("headCommit") != DELEGATE_COMMIT:
        fail("Delegate exact commit mismatch")
    if sources["Delegate"].get("dirty") is not False:
        fail("Delegate must be clean")

    reports = manifest.get("reports")
    commands = manifest.get("commands")
    if not isinstance(reports, list) or len(reports) != len(FIXTURES):
        fail("APNG oracle report list mismatch")
    if not isinstance(commands, list) or len(commands) != len(FIXTURES):
        fail("APNG oracle command list mismatch")
    if len(set(reports)) != len(reports):
        fail("APNG oracle report list contains duplicates")

    command_by_fixture: dict[str, list[str]] = {}
    for command in commands:
        fixture_id = option_value(command, "--fixture-id")
        if fixture_id not in FIXTURES or fixture_id in command_by_fixture:
            fail(f"APNG oracle command fixture is invalid or duplicated: {fixture_id}")
        command_by_fixture[fixture_id] = command

    inputs = identity.get("inputs")
    contracts = identity.get("fixtureContract")
    if not isinstance(inputs, dict) or not isinstance(contracts, dict):
        fail("APNG oracle input or fixture contract is invalid")
    fixture_results: dict[str, object] = {}
    artifact_inventory: dict[str, dict[str, object]] = {}
    expected_artifacts: set[pathlib.Path] = set()

    for fixture_id in FIXTURES:
        report_path = root / f"{fixture_id}.json"
        if str(report_path) not in reports:
            fail(f"missing report registration: {fixture_id}")
        command = command_by_fixture.get(fixture_id)
        if command is None:
            fail(f"missing command registration: {fixture_id}")
        if pathlib.Path(option_value(command, "--output")).resolve() != report_path:
            fail(f"{fixture_id}: command output path mismatch")
        if pathlib.Path(option_value(command, "--source-identity")).resolve() != identity_path:
            fail(f"{fixture_id}: command source identity path mismatch")
        expected_artifacts.add(report_path)
        if not report_path.is_file():
            fail(f"missing report: {report_path}")
        report = json.loads(report_path.read_text())
        if report.get("schemaVersion") != 3 or report.get("fixtureID") != fixture_id:
            fail(f"{fixture_id}: report schema or identity mismatch")

        expected_input = inputs.get(fixture_id)
        if not isinstance(expected_input, dict):
            fail(f"{fixture_id}: missing input identity")
        if option_value(command, "--input") != expected_input.get("path"):
            fail(f"{fixture_id}: command input path mismatch")
        if (
            report.get("inputByteCount") != expected_input.get("byteCount")
            or report.get("inputSHA256") != expected_input.get("sha256")
        ):
            fail(f"{fixture_id}: input identity mismatch")
        if pathlib.Path(report.get("sourceIdentityPath", "")).resolve() != identity_path:
            fail(f"{fixture_id}: source identity path mismatch")
        if (
            report.get("sourceIdentityByteCount") != identity_file["byteCount"]
            or report.get("sourceIdentitySHA256") != identity_file["sha256"]
        ):
            fail(f"{fixture_id}: source identity digest mismatch")

        contract = contracts.get(fixture_id)
        if not isinstance(contract, dict):
            fail(f"{fixture_id}: fixture contract missing")
        expected_frame_count = contract.get("expectedFrameCount")
        imagecraft = report.get("imageCraft")
        apngkit = report.get("apngKit")
        apple = report.get("appleImageIO")
        if not isinstance(imagecraft, dict) or not isinstance(apngkit, dict) or not isinstance(apple, dict):
            fail(f"{fixture_id}: comparator metadata missing")
        if any(
            comparator.get("frameCount") != expected_frame_count
            for comparator in (imagecraft, apngkit, apple)
        ):
            fail(f"{fixture_id}: frame count mismatch")

        imagecraft_durations = imagecraft.get("frameDurationsNanoseconds")
        apngkit_durations = apngkit.get("frameDurationsNanoseconds")
        if (
            not isinstance(imagecraft_durations, list)
            or not isinstance(apngkit_durations, list)
            or len(imagecraft_durations) != expected_frame_count
            or len(apngkit_durations) != expected_frame_count
        ):
            fail(f"{fixture_id}: duration vector mismatch")
        tolerance = report.get("timelineToleranceNanoseconds")
        if not isinstance(tolerance, int) or tolerance < 0:
            fail(f"{fixture_id}: invalid timeline tolerance")
        computed_timeline = (
            imagecraft.get("normalizedAdditionalRepeatCount")
            == apngkit.get("normalizedAdditionalRepeatCount")
            and all(abs(a - b) <= tolerance for a, b in zip(imagecraft_durations, apngkit_durations))
        )
        if report.get("timelineEligible") != computed_timeline:
            fail(f"{fixture_id}: timeline eligibility mismatch")

        frames = report.get("frames")
        if not isinstance(frames, list) or len(frames) != expected_frame_count:
            fail(f"{fixture_id}: frame report count mismatch")
        pair_exact_counts = {pair: 0 for pair in PAIRS}
        pair_max_channel = {pair: 0 for pair in PAIRS}
        pair_max_fraction = {pair: 0.0 for pair in PAIRS}
        total_imagecraft_subrect_bytes = 0
        total_imagecraft_decoded_bytes = 0
        full_canvas_decoded_frames = 0
        frame_summaries = []

        for expected_index, frame in enumerate(frames):
            if not isinstance(frame, dict) or frame.get("index") != expected_index:
                fail(f"{fixture_id}: frame index mismatch")
            descriptor_rect = frame.get("imageCraftDescriptorRect")
            if not isinstance(descriptor_rect, dict):
                fail(f"{fixture_id}: ImageCraft descriptor rect missing at frame {expected_index}")
            rect_values = [descriptor_rect.get(name) for name in ("x", "y", "width", "height")]
            if any(not isinstance(value, int) for value in rect_values):
                fail(f"{fixture_id}: ImageCraft descriptor rect invalid at frame {expected_index}")
            rect_x, rect_y, rect_width, rect_height = rect_values
            canvas_width = contract.get("expectedCanvasWidth")
            canvas_height = contract.get("expectedCanvasHeight")
            if (
                rect_x < 0
                or rect_y < 0
                or rect_width <= 0
                or rect_height <= 0
                or rect_x + rect_width > canvas_width
                or rect_y + rect_height > canvas_height
            ):
                fail(f"{fixture_id}: ImageCraft descriptor rect escapes canvas at frame {expected_index}")
            if frame.get("imageCraftDisposal") not in {"none", "background", "previous"}:
                fail(f"{fixture_id}: ImageCraft disposal invalid at frame {expected_index}")
            if frame.get("imageCraftBlend") not in {"source", "over"}:
                fail(f"{fixture_id}: ImageCraft blend invalid at frame {expected_index}")
            expected_subrect_bytes = rect_width * rect_height * 4
            expected_decoded_bytes = canvas_width * canvas_height * 4
            if frame.get("imageCraftSubrectRGBAByteCount") != expected_subrect_bytes:
                fail(f"{fixture_id}: ImageCraft subrect byte count mismatch at frame {expected_index}")
            if frame.get("imageCraftDecodedRGBAByteCount") != expected_decoded_bytes:
                fail(f"{fixture_id}: ImageCraft decoded byte count mismatch at frame {expected_index}")
            if frame.get("imageCraftDecodedIsFullCanvas") is not True:
                fail(f"{fixture_id}: ImageCraft decoded frame is not full canvas at frame {expected_index}")
            total_imagecraft_subrect_bytes += expected_subrect_bytes
            total_imagecraft_decoded_bytes += expected_decoded_bytes
            full_canvas_decoded_frames += 1
            comparator_bytes: dict[str, bytes] = {}
            comparator_digests: dict[str, str] = {}
            for comparator_name, fields in COMPARATORS.items():
                width = frame.get(fields["width"])
                height = frame.get(fields["height"])
                if (
                    width != contract.get("expectedCanvasWidth")
                    or height != contract.get("expectedCanvasHeight")
                ):
                    fail(
                        f"{fixture_id}: {comparator_name} canvas mismatch at frame {expected_index}"
                    )
                sidecar = contained_file(
                    root,
                    frame.get(fields["path"]),
                    f"{fixture_id} frame {expected_index} {comparator_name}",
                )
                expected_artifacts.add(sidecar)
                rgba = sidecar.read_bytes()
                if len(rgba) != width * height * 4:
                    fail(
                        f"{fixture_id}: {comparator_name} RGBA byte count mismatch at frame {expected_index}"
                    )
                digest = sha256(rgba)
                if digest != frame.get(fields["digest"]):
                    fail(
                        f"{fixture_id}: {comparator_name} RGBA digest mismatch at frame {expected_index}"
                    )
                comparator_bytes[comparator_name] = rgba
                comparator_digests[comparator_name] = digest
                artifact_inventory[str(sidecar.relative_to(root))] = file_identity(sidecar)

            frame_pairs: dict[str, object] = {}
            for pair_name, (lhs, rhs, report_field, _) in PAIRS.items():
                computed = difference(comparator_bytes[lhs], comparator_bytes[rhs])
                if not differences_equal(frame.get(report_field), computed):
                    fail(f"{fixture_id}: {pair_name} difference mismatch at frame {expected_index}")
                is_exact = comparator_digests[lhs] == comparator_digests[rhs]
                pair_exact_counts[pair_name] += int(is_exact)
                pair_max_channel[pair_name] = max(
                    pair_max_channel[pair_name],
                    int(computed["maximumChannelDifference"] or 0),
                )
                pair_max_fraction[pair_name] = max(
                    pair_max_fraction[pair_name],
                    float(computed["differentPixelFraction"] or 0),
                )
                frame_pairs[pair_name] = {"exact": is_exact, "difference": computed}
            frame_summaries.append(
                {
                    "index": expected_index,
                    "imageCraftDescriptorRect": descriptor_rect,
                    "imageCraftDisposal": frame["imageCraftDisposal"],
                    "imageCraftBlend": frame["imageCraftBlend"],
                    "imageCraftSubrectRGBAByteCount": expected_subrect_bytes,
                    "imageCraftDecodedRGBAByteCount": expected_decoded_bytes,
                    "pairs": frame_pairs,
                }
            )

        pair_all_exact = {
            pair_name: pair_exact_counts[pair_name] == expected_frame_count
            for pair_name in PAIRS
        }
        for pair_name, (_, _, _, report_field) in PAIRS.items():
            if report.get(report_field) != pair_all_exact[pair_name]:
                fail(f"{fixture_id}: {pair_name} all-frame exactness mismatch")
        artifact_inventory[str(report_path.relative_to(root))] = file_identity(report_path)
        fixture_results[fixture_id] = {
            "role": contract.get("role"),
            "frameCount": expected_frame_count,
            "timelineEligible": computed_timeline,
            "pairExactFrameCounts": pair_exact_counts,
            "pairAllFramesExact": pair_all_exact,
            "pairMaximumChannelDifference": pair_max_channel,
            "pairMaximumDifferentPixelFraction": pair_max_fraction,
            "adjudication": adjudication(pair_all_exact),
            "imageCraftResourceObservation": {
                "fullCanvasDecodedFrameCount": full_canvas_decoded_frames,
                "totalFrameCount": expected_frame_count,
                "allDecodedFramesAreFullCanvas": (
                    full_canvas_decoded_frames == expected_frame_count
                ),
                "totalMetadataSubrectRGBAByteCount": total_imagecraft_subrect_bytes,
                "totalDecodedRGBAByteCount": total_imagecraft_decoded_bytes,
                "decodedOverMetadataSubrectByteRatio": (
                    total_imagecraft_decoded_bytes / total_imagecraft_subrect_bytes
                ),
                "explicitImageCraftCheckpointStateObserved": False,
                "randomAccessCompositionDelegatedToAppleImageIO": True,
            },
            "frames": frame_summaries,
        }

    actual_artifacts = {
        path.resolve()
        for path in root.iterdir()
        if path.is_file()
        and path.name not in {"source-identity.json", "capture-manifest.json", "aggregate.json"}
    }
    if actual_artifacts != expected_artifacts:
        fail(
            "APNG oracle artifact set mismatch: "
            f"unexpected={sorted(str(path) for path in actual_artifacts - expected_artifacts)} "
            f"missing={sorted(str(path) for path in expected_artifacts - actual_artifacts)}"
        )

    aggregate = {
        "schemaVersion": 3,
        "formalClaimEligible": False,
        "sourceIdentity": file_identity(identity_path),
        "captureManifest": file_identity(manifest_path),
        "sourceUnchangedDuringCapture": True,
        "inputsUnchangedDuringCapture": True,
        "systemComparatorsUnchangedDuringCapture": True,
        "systemComparators": system_comparators,
        "imageCraftMechanismAudit": mechanism_audit,
        "artifactInventory": dict(sorted(artifact_inventory.items())),
        "fixtureResults": fixture_results,
        "allFixturesTimelineEligible": all(
            result["timelineEligible"] for result in fixture_results.values()
        ),
        "allFixturesPairExact": {
            pair_name: all(
                result["pairAllFramesExact"][pair_name]
                for result in fixture_results.values()
            )
            for pair_name in PAIRS
        },
        "claimBoundary": identity.get("claimBoundary"),
    }
    aggregate_path = root / "aggregate.json"
    write_json_atomic(aggregate_path, aggregate)
    print(aggregate_path)
    for fixture_id, result in fixture_results.items():
        counts = result["pairExactFrameCounts"]
        print(
            f"{fixture_id}: timeline={result['timelineEligible']} "
            f"IC/APNGKit={counts['ImageCraftAPNGKit']}/{result['frameCount']} "
            f"IC/Apple={counts['ImageCraftAppleImageIO']}/{result['frameCount']} "
            f"APNGKit/Apple={counts['APNGKitAppleImageIO']}/{result['frameCount']} "
            f"adjudication={result['adjudication']}"
        )


if __name__ == "__main__":
    main()
