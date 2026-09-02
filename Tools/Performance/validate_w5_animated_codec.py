#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import pathlib
import statistics
from collections import Counter, defaultdict

COMPARATOR_VERSIONS = {
    "ImageCraft": "local-animation-contract-v1",
    "SDWebImage": "5.21.7",
    "PINRemoteImage": "releases/p14.31",
}
EXPECTED_CLEAN_COMPARATOR_COMMITS = {
    "SDWebImage": "2de3a496eaf6df9a1312862adcfd54acd73c39c0",
    "PINRemoteImage": "c0d5cfa1947f2456ddb321a85b347b3d60d83254",
}
COMPARATORS = tuple(COMPARATOR_VERSIONS)
FORMATS = ("gif", "apng")
ENDPOINTS = ("prepare", "selectedFrame", "sequentialAllFrames")


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


def validate_source_snapshot(name: str, snapshot: object) -> dict:
    if not isinstance(snapshot, dict):
        fail(f"missing source snapshot: {name}")
    for key in ("headCommit", "headTree", "workingTree"):
        if not is_git_object_id(snapshot.get(key)):
            fail(f"{name}: invalid {key}")
    if not isinstance(snapshot.get("dirty"), bool):
        fail(f"{name}: invalid dirty state")
    if snapshot.get("identityAlgorithm") != "git-temporary-index-add-all-write-tree-v1":
        fail(f"{name}: unsupported source identity algorithm")
    status = snapshot.get("statusShort")
    if not isinstance(status, list) or any(not isinstance(line, str) for line in status):
        fail(f"{name}: invalid status snapshot")
    if snapshot["dirty"] != (snapshot["workingTree"] != snapshot["headTree"]):
        fail(f"{name}: dirty state does not match tree identity")
    return snapshot


def source_identity_for_report(name: str, source_before: dict) -> dict[str, object]:
    comparators = source_before.get("comparators")
    if not isinstance(comparators, dict):
        fail("capture manifest comparator source section is invalid")
    snapshot = validate_source_snapshot(name, comparators.get(name))
    if snapshot.get("version") != COMPARATOR_VERSIONS[name]:
        fail(f"{name}: version mismatch in source manifest")
    return {
        "name": name,
        "version": COMPARATOR_VERSIONS[name],
        "headCommit": snapshot["headCommit"],
        "workingTree": snapshot["workingTree"],
        "dirty": snapshot["dirty"],
    }


def p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)]


def validate_timing(report: dict, path: pathlib.Path, field: str, expected_samples: int) -> None:
    timing = report.get(field)
    if not isinstance(timing, dict):
        fail(f"{path}: missing {field} timing")
    samples = timing.get("samplesNanoseconds")
    if not isinstance(samples, list) or len(samples) != expected_samples:
        fail(f"{path}: {field} expected {expected_samples} samples")
    if any(not isinstance(value, int) or value <= 0 for value in samples):
        fail(f"{path}: {field} contains invalid samples")
    ordered = sorted(samples)
    median = ordered[len(ordered) // 2]
    expected_p95 = ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)]
    if timing.get("medianNanoseconds") != median or timing.get("p95Nanoseconds") != expected_p95:
        fail(f"{path}: {field} aggregate mismatch")


def rgba_difference(reference_path: pathlib.Path, candidate_path: pathlib.Path) -> dict:
    reference = reference_path.read_bytes()
    candidate = candidate_path.read_bytes()
    if len(reference) != len(candidate):
        return {"sameLength": False, "differentPixelCount": None, "maximumChannelDifference": None}
    if len(reference) % 4 != 0:
        fail(f"RGBA sidecar length is not divisible by four: {reference_path}")
    different_pixels = 0
    max_difference = 0
    total_difference = 0
    channel_count = len(reference)
    for offset in range(0, len(reference), 4):
        pixel_differs = False
        for channel in range(4):
            difference = abs(reference[offset + channel] - candidate[offset + channel])
            total_difference += difference
            max_difference = max(max_difference, difference)
            pixel_differs = pixel_differs or difference != 0
        different_pixels += int(pixel_differs)
    pixel_count = len(reference) // 4
    return {
        "sameLength": True,
        "differentPixelCount": different_pixels,
        "differentPixelFraction": different_pixels / pixel_count,
        "maximumChannelDifference": max_difference,
        "meanAbsoluteChannelDifference": total_difference / channel_count,
    }


def contained_artifact(root: pathlib.Path, value: object, label: str) -> pathlib.Path:
    if not isinstance(value, str):
        fail(f"{label}: artifact path must be a string")
    path = pathlib.Path(value).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        fail(f"{label}: artifact escapes capture directory: {path}")
        raise AssertionError from error
    if not path.is_file():
        fail(f"{label}: missing artifact: {path}")
    return path


def option_value(command: object, option: str) -> str:
    if not isinstance(command, list) or any(not isinstance(item, str) for item in command):
        fail("capture command must be a string array")
    if command.count(option) != 1:
        fail(f"capture command must contain exactly one {option}")
    index = command.index(option)
    if index + 1 >= len(command):
        fail(f"capture command is missing a value for {option}")
    return command[index + 1]


def write_json_atomic(path: pathlib.Path, payload: object) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory", type=pathlib.Path)
    parser.add_argument("--blocks", type=int, default=6)
    parser.add_argument("--samples-per-report", type=int, default=5)
    args = parser.parse_args()
    if args.blocks <= 0 or args.samples_per_report <= 0:
        fail("blocks and samples-per-report must be positive")

    root = args.output_directory.resolve()
    manifest_path = root / "capture-manifest.json"
    if not manifest_path.is_file():
        fail(f"missing capture manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schemaVersion") != 2 or manifest.get("blockCount") != args.blocks:
        fail("capture manifest schema or block count mismatch")
    if manifest.get("iterationsPerReport") != args.samples_per_report:
        fail("capture manifest sample count mismatch")
    if manifest.get("formalClaimEligible") is not False:
        fail("dirty local W5 capture must not activate a formal claim")
    if manifest.get("sourceUnchangedDuringCapture") is not True:
        fail("source changed during capture")
    if manifest.get("inputsUnchangedDuringCapture") is not True:
        fail("input changed during capture")

    source_before = manifest.get("sourceBefore")
    source_after = manifest.get("sourceAfter")
    if not isinstance(source_before, dict) or source_before != source_after:
        fail("source before/after identity mismatch")
    validate_source_snapshot("Fovea", source_before.get("Fovea"))
    comparator_sources = source_before.get("comparators")
    if not isinstance(comparator_sources, dict):
        fail("missing comparator source identities")
    for comparator in COMPARATORS:
        snapshot = validate_source_snapshot(comparator, comparator_sources.get(comparator))
        if snapshot.get("version") != COMPARATOR_VERSIONS[comparator]:
            fail(f"{comparator}: source version mismatch")
        if comparator in EXPECTED_CLEAN_COMPARATOR_COMMITS:
            expected = EXPECTED_CLEAN_COMPARATOR_COMMITS[comparator]
            if snapshot.get("headCommit") != expected:
                fail(f"{comparator}: exact commit mismatch")
            if snapshot.get("dirty") is not False:
                fail(f"{comparator}: comparator checkout must be clean")
            if snapshot.get("workingTree") != snapshot.get("headTree"):
                fail(f"{comparator}: clean comparator tree mismatch")

    inputs_before = manifest.get("inputsBefore")
    if not isinstance(inputs_before, dict) or inputs_before != manifest.get("inputsAfter"):
        fail("input before/after identity mismatch")
    for fmt in FORMATS:
        identity = inputs_before.get(fmt)
        if not isinstance(identity, dict):
            fail(f"missing {fmt} input identity")
        if not isinstance(identity.get("byteCount"), int) or identity["byteCount"] <= 0:
            fail(f"{fmt}: invalid input byte count")
        digest = identity.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            fail(f"{fmt}: invalid input digest")

    expected_orders = Counter()
    expected_commands: dict[tuple[int, str, str], dict[str, str]] = {}
    manifest_blocks = manifest.get("blocks")
    if not isinstance(manifest_blocks, list) or len(manifest_blocks) != args.blocks:
        fail("capture manifest block list mismatch")
    actual_orders = Counter()
    for entry in manifest_blocks:
        if not isinstance(entry, dict):
            fail("capture manifest block entry must be an object")
        block = entry.get("block")
        if not isinstance(block, int) or not 0 <= block < args.blocks:
            fail("capture manifest block index is invalid")
        comparator_order = list(COMPARATORS[block % 3 :] + COMPARATORS[: block % 3])
        format_order = list(FORMATS if block % 2 == 0 else reversed(FORMATS))
        expected_orders[(block, tuple(format_order), tuple(comparator_order))] += 1
        actual_orders[
            (block, tuple(entry.get("formatOrder", [])), tuple(entry.get("comparatorOrder", [])))
        ] += 1
        commands = entry.get("commands")
        if not isinstance(commands, list) or len(commands) != len(FORMATS) * len(COMPARATORS):
            fail(f"block {block}: capture command count mismatch")
        for command in commands:
            comparator = option_value(command, "--comparator")
            fmt = option_value(command, "--format")
            if comparator not in COMPARATORS or fmt not in FORMATS:
                fail(f"block {block}: unknown comparator or format in command")
            key = (block, fmt, comparator)
            if key in expected_commands:
                fail(f"block {block}: duplicate command for {fmt} {comparator}")
            expected_identity = source_identity_for_report(comparator, source_before)
            expected_commands[key] = {
                "report": option_value(command, "--output"),
                "version": option_value(command, "--comparator-version"),
                "head": option_value(command, "--source-head"),
                "tree": option_value(command, "--source-tree"),
                "dirty": option_value(command, "--source-dirty"),
            }
            if expected_commands[key]["version"] != expected_identity["version"]:
                fail(f"block {block} {fmt} {comparator}: command version mismatch")
            if expected_commands[key]["head"] != expected_identity["headCommit"]:
                fail(f"block {block} {fmt} {comparator}: command head mismatch")
            if expected_commands[key]["tree"] != expected_identity["workingTree"]:
                fail(f"block {block} {fmt} {comparator}: command tree mismatch")
            expected_dirty = "true" if expected_identity["dirty"] else "false"
            if expected_commands[key]["dirty"] != expected_dirty:
                fail(f"block {block} {fmt} {comparator}: command dirty state mismatch")
    if actual_orders != expected_orders:
        fail("capture order manifest is not the preregistered rotation")

    reports: dict[tuple[int, str, str], dict] = {}
    block_medians: dict[tuple[str, str, str], list[int]] = defaultdict(list)
    exact_digest_by_format: dict[str, str] = {}
    exact_pixel_eligibility = {name: True for name in COMPARATORS}
    timing_eligibility = {name: True for name in COMPARATORS}
    sd_differences: list[dict] = []
    artifact_inventory: dict[str, dict[str, object]] = {}
    expected_block_artifacts: set[pathlib.Path] = set()

    for block in range(args.blocks):
        block_directory = root / f"block-{block:02d}"
        for fmt in FORMATS:
            block_reports = {}
            for comparator in COMPARATORS:
                path = block_directory / f"{fmt}-{comparator}.json"
                expected_block_artifacts.add(path.resolve())
                if not path.is_file():
                    fail(f"missing report: {path}")
                report = json.loads(path.read_text())
                reports[(block, fmt, comparator)] = report
                block_reports[comparator] = report
                if report.get("schemaVersion") != 2:
                    fail(f"{path}: schemaVersion mismatch")
                expected_identity = source_identity_for_report(comparator, source_before)
                if report.get("comparator") != expected_identity:
                    fail(f"{path}: comparator identity mismatch")
                command_report = pathlib.Path(expected_commands[(block, fmt, comparator)]["report"]).resolve()
                if command_report != path.resolve():
                    fail(f"{path}: command output path mismatch")
                if report.get("format") != fmt:
                    fail(f"{path}: format mismatch")
                input_identity = inputs_before[fmt]
                if (
                    report.get("inputByteCount") != input_identity["byteCount"]
                    or report.get("inputSHA256") != input_identity["sha256"]
                ):
                    fail(f"{path}: input identity mismatch")
                if report.get("frameCount") != 24 or report.get("selectedFrameIndex") != 12:
                    fail(f"{path}: frame contract mismatch")
                if report.get("selectedFrameWidth") != 256 or report.get("selectedFrameHeight") != 256:
                    fail(f"{path}: selected frame dimensions mismatch")
                if report.get("normalizedAdditionalRepeatCount") != 2:
                    fail(f"{path}: normalized loop mismatch")
                durations = report.get("frameDurationsNanoseconds")
                if not isinstance(durations, list) or len(durations) != 24:
                    fail(f"{path}: duration vector mismatch")
                rgba_path = contained_artifact(
                    root,
                    report.get("selectedFrameRGBAPath"),
                    f"{path}: RGBA sidecar",
                )
                expected_block_artifacts.add(rgba_path)
                rgba_data = rgba_path.read_bytes()
                if len(rgba_data) != 256 * 256 * 4:
                    fail(f"{path}: RGBA sidecar size mismatch")
                if sha256(rgba_data) != report.get("selectedFramePixelSHA256"):
                    fail(f"{path}: RGBA digest mismatch")
                for endpoint in ENDPOINTS:
                    validate_timing(report, path, endpoint, args.samples_per_report)
                    block_medians[(fmt, comparator, endpoint)].append(
                        report[endpoint]["medianNanoseconds"]
                    )
                artifact_inventory[str(path.relative_to(root))] = file_identity(path)
                artifact_inventory[str(rgba_path.relative_to(root))] = file_identity(rgba_path)

            imagecraft = block_reports["ImageCraft"]
            sd = block_reports["SDWebImage"]
            reference_digest = imagecraft["selectedFramePixelSHA256"]
            for comparator, report in block_reports.items():
                exact_pixel_eligibility[comparator] = (
                    exact_pixel_eligibility[comparator]
                    and report["selectedFramePixelSHA256"] == reference_digest
                )
            if fmt in exact_digest_by_format and exact_digest_by_format[fmt] != reference_digest:
                fail(f"block {block} {fmt}: reference pixel digest drift")
            exact_digest_by_format[fmt] = reference_digest
            reference_durations = imagecraft["frameDurationsNanoseconds"]
            for comparator, report in block_reports.items():
                timing_eligibility[comparator] = (
                    timing_eligibility[comparator]
                    and not any(
                        abs(a - b) > 1_000
                        for a, b in zip(
                            reference_durations,
                            report["frameDurationsNanoseconds"],
                        )
                    )
                )
            sd_differences.append(
                {
                    "block": block,
                    "format": fmt,
                    **rgba_difference(
                        pathlib.Path(imagecraft["selectedFrameRGBAPath"]),
                        pathlib.Path(sd["selectedFrameRGBAPath"]),
                    ),
                }
            )

    actual_block_artifacts = {
        path.resolve()
        for block in range(args.blocks)
        for path in (root / f"block-{block:02d}").iterdir()
        if path.is_file()
    }
    if actual_block_artifacts != expected_block_artifacts:
        unexpected = sorted(str(path) for path in actual_block_artifacts - expected_block_artifacts)
        missing = sorted(str(path) for path in expected_block_artifacts - actual_block_artifacts)
        fail(f"capture artifact set mismatch: unexpected={unexpected} missing={missing}")

    manifest_identity = file_identity(manifest_path)
    aggregate = {
        "schemaVersion": 2,
        "formalClaimEligible": False,
        "sourceManifest": "capture-manifest.json",
        "sourceManifestIdentity": manifest_identity,
        "sourceIdentity": {
            "Fovea": source_before["Fovea"],
            "comparators": {
                name: source_identity_for_report(name, source_before) for name in COMPARATORS
            },
            "sourceUnchangedDuringCapture": True,
        },
        "artifactInventory": dict(sorted(artifact_inventory.items())),
        "blockCount": args.blocks,
        "samplesPerReport": args.samples_per_report,
        "exactPixelEligibility": exact_pixel_eligibility,
        "timelineEligibilityWithinTolerance": timing_eligibility,
        "timingToleranceNanoseconds": 1_000,
        "formats": {},
        "sdWebImageVisualDifference": {
            "maximumChannelDifference": max(item["maximumChannelDifference"] for item in sd_differences),
            "maximumDifferentPixelFraction": max(item["differentPixelFraction"] for item in sd_differences),
            "maximumMeanAbsoluteChannelDifference": max(
                item["meanAbsoluteChannelDifference"] for item in sd_differences
            ),
            "blocks": sd_differences,
        },
    }
    for fmt in FORMATS:
        format_result = {"comparators": {}, "exactPixelPairRatios": {}}
        for comparator in COMPARATORS:
            endpoint_result = {}
            for endpoint in ENDPOINTS:
                values = block_medians[(fmt, comparator, endpoint)]
                endpoint_result[endpoint] = {
                    "blockMediansNanoseconds": values,
                    "medianOfBlockMediansNanoseconds": statistics.median(values),
                    "p95OfBlockMediansNanoseconds": p95(values),
                }
            format_result["comparators"][comparator] = endpoint_result
        if exact_pixel_eligibility["PINRemoteImage"] and timing_eligibility["PINRemoteImage"]:
            for endpoint in ENDPOINTS:
                ic = format_result["comparators"]["ImageCraft"][endpoint][
                    "medianOfBlockMediansNanoseconds"
                ]
                pin = format_result["comparators"]["PINRemoteImage"][endpoint][
                    "medianOfBlockMediansNanoseconds"
                ]
                format_result["exactPixelPairRatios"][endpoint] = {
                    "ImageCraftOverPINRemoteImage": ic / pin,
                }
        aggregate["formats"][fmt] = format_result

    aggregate_path = root / "aggregate.json"
    write_json_atomic(aggregate_path, aggregate)
    print(aggregate_path)
    for fmt in FORMATS:
        ratios = aggregate["formats"][fmt]["exactPixelPairRatios"]
        if ratios:
            print(
                f"{fmt}: IC/PIN prepare={ratios['prepare']['ImageCraftOverPINRemoteImage']:.3f} "
                f"frame={ratios['selectedFrame']['ImageCraftOverPINRemoteImage']:.3f} "
                f"sequence={ratios['sequentialAllFrames']['ImageCraftOverPINRemoteImage']:.3f}"
            )
        else:
            print(f"{fmt}: PIN is not eligible for the exact-pixel pair")
    print(
        "SD exact-pixel gate: failed; max channel diff="
        f"{aggregate['sdWebImageVisualDifference']['maximumChannelDifference']}"
    )


if __name__ == "__main__":
    main()
