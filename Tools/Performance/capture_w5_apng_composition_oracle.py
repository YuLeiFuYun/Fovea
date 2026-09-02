#!/usr/bin/env python3
import argparse
import importlib.util
import json
import pathlib
import platform
import plistlib
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
SUPPORT_PATH = pathlib.Path(__file__).with_name("capture_w5_animated_codec.py")
SPEC = importlib.util.spec_from_file_location("w5_source_identity_support", SUPPORT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load source identity support: {SUPPORT_PATH}")
support = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = support
SPEC.loader.exec_module(support)

IMAGECRAFT_VERSION = "local-animation-contract-v1"
APNGKIT_VERSION = "2.3.0-source-audit-candidate"
APNGKIT_COMMIT = "341383f61000e8d2e55d45db0f0756b239d0a2f1"
DELEGATE_VERSION = "1.3.0"
DELEGATE_COMMIT = "ec3014ca2621c717f758d8718ec90e84b6e774b3"
FIXTURES = {
    "APNG-OVER-NONE": {
        "relativePath": "General/over_none.apng",
        "expectedFrameCount": 3,
        "expectedCanvasWidth": 150,
        "expectedCanvasHeight": 150,
        "role": "full-canvas-none-disposal",
    },
    "APNG-OVER-BACKGROUND": {
        "relativePath": "General/over_background.apng",
        "expectedFrameCount": 3,
        "expectedCanvasWidth": 150,
        "expectedCanvasHeight": 150,
        "role": "full-canvas-background-disposal",
    },
    "APNG-OVER-PREVIOUS": {
        "relativePath": "General/over_previous.apng",
        "expectedFrameCount": 3,
        "expectedCanvasWidth": 150,
        "expectedCanvasHeight": 150,
        "role": "full-canvas-previous-disposal",
    },
    "APNG-SUBRECT-NONE": {
        "relativePath": "SpecTesting/013.png",
        "expectedFrameCount": 3,
        "expectedCanvasWidth": 128,
        "expectedCanvasHeight": 64,
        "role": "offset-subrect-over-none-disposal",
    },
    "APNG-SUBRECT-BACKGROUND": {
        "relativePath": "SpecTesting/015.png",
        "expectedFrameCount": 3,
        "expectedCanvasWidth": 128,
        "expectedCanvasHeight": 64,
        "role": "offset-subrect-over-background-disposal",
    },
    "APNG-SUBRECT-PREVIOUS-SOURCE": {
        "relativePath": "General/pia.png",
        "expectedFrameCount": 6,
        "expectedCanvasWidth": 220,
        "expectedCanvasHeight": 220,
        "role": "mixed-offset-subrect-previous-and-source-blend",
    },
}

MECHANISM_FILES = {
    "animatedImageTypes": "Sources/ImageCraftCore/AnimatedImageTypes.swift",
    "containerInspector": "Sources/ImageCraftImageIO/AnimatedContainerInspector.swift",
    "apngInspector": "Sources/ImageCraftImageIO/APNGAnimationInspector.swift",
    "animatedDecoder": "Sources/ImageCraftImageIO/ImageIOAnimatedImageDecoder.swift",
    "frameProvider": "Sources/ImageCraftImageIO/ImageIOAnimationFrameProvider.swift",
    "frameRenderer": "Sources/ImageCraftImageIO/ImageIOAnimationFrameRenderer.swift",
}


def snapshot_with_version(root: pathlib.Path, version: str) -> dict[str, object]:
    return {"version": version, **support.git_snapshot(root)}


def validate_clean_source(name: str, snapshot: dict[str, object], commit: str) -> None:
    if snapshot.get("headCommit") != commit:
        raise SystemExit(
            f"{name} commit mismatch: expected {commit}, got {snapshot.get('headCommit')}"
        )
    if snapshot.get("dirty") is not False:
        raise SystemExit(f"{name} source must be clean")
    if snapshot.get("workingTree") != snapshot.get("headTree"):
        raise SystemExit(f"{name} clean tree identity mismatch")


def source_snapshots(
    imagecraft_root: pathlib.Path,
    apngkit_root: pathlib.Path,
    delegate_root: pathlib.Path,
) -> dict[str, object]:
    return {
        "Fovea": support.git_snapshot(ROOT),
        "ImageCraft": snapshot_with_version(imagecraft_root, IMAGECRAFT_VERSION),
        "APNGKit": snapshot_with_version(apngkit_root, APNGKIT_VERSION),
        "Delegate": snapshot_with_version(delegate_root, DELEGATE_VERSION),
    }


def imagecraft_mechanism_audit(root: pathlib.Path) -> dict[str, object]:
    paths = {name: root / relative for name, relative in MECHANISM_FILES.items()}
    for name, path in paths.items():
        if not path.is_file():
            raise SystemExit(f"missing ImageCraft mechanism source {name}: {path}")
    contents = {name: path.read_text() for name, path in paths.items()}
    observations = {
        "decodedAnimationFrameDocumentedAsCompleteComposedFrame": (
            "一次按需解码得到的完整合成帧" in contents["animatedImageTypes"]
        ),
        "providerDecodesSingleRequestedIndexDirectly": (
            "in: index..<(index + 1)" in contents["frameProvider"]
            and "prefersCachedFullImage: true" in contents["frameProvider"]
        ),
        "providerWindowMapsEveryRequestedIndex": (
            "try range.map { index in" in contents["frameProvider"]
            and "ImageIOAnimationFrameRenderer.decode(" in contents["frameProvider"]
        ),
        "rendererUsesImageIORequestedIndexMaterialization": (
            "CGImageSourceCreateImageAtIndex" in contents["frameProvider"]
            and "CGImageSourceCreateThumbnailAtIndex" in contents["frameProvider"]
            and "source.image(" in contents["frameRenderer"]
            and "source.thumbnail(" in contents["frameRenderer"]
        ),
        "apngInspectorPublishesSubrectDisposalAndBlendMetadata": all(
            token in contents["apngInspector"]
            for token in (
                "rect: rect",
                "disposal: disposal",
                "blend: blend",
                "ImageAnimationFrameDescriptor",
            )
        ),
        "separateDefaultMultiFrameRequiresAlignedImageIOIndices": (
            "imageIOSourceIndicesMatchTimeline" in contents["containerInspector"]
            and "firstFrameUsesIDAT || frames.count == 1" in contents["apngInspector"]
            and "guard inspection.imageIOSourceIndicesMatchTimeline else" in contents["animatedDecoder"]
            and "throw ImageCraftError.animationUnsupported" in contents["animatedDecoder"]
        ),
        "explicitCheckpointStateObservedInProviderOrRenderer": (
            "checkpoint" in (contents["frameProvider"] + contents["frameRenderer"]).lower()
        ),
    }
    required_true = [
        "decodedAnimationFrameDocumentedAsCompleteComposedFrame",
        "providerDecodesSingleRequestedIndexDirectly",
        "providerWindowMapsEveryRequestedIndex",
        "rendererUsesImageIORequestedIndexMaterialization",
        "apngInspectorPublishesSubrectDisposalAndBlendMetadata",
        "separateDefaultMultiFrameRequiresAlignedImageIOIndices",
    ]
    missing = [name for name in required_true if observations[name] is not True]
    if missing:
        raise SystemExit(f"ImageCraft mechanism source contract changed: {missing}")
    if observations["explicitCheckpointStateObservedInProviderOrRenderer"] is not False:
        raise SystemExit("ImageCraft provider/renderer now contains checkpoint state; update the audit")
    return {
        "schemaVersion": 1,
        "files": {name: support.file_identity(path) for name, path in paths.items()},
        "observations": observations,
        "interpretationBoundary": (
            "The inspected ImageCraft layer parses subrect/disposal/blend metadata but "
            "delegates each supported requested full-frame materialization to Apple ImageIO. "
            "Multi-frame APNG with a separate default image fails closed because ImageIO "
            "source indices are not proven to match the animation timeline. The checkpoint "
            "absence assertion is limited to the bound provider and renderer files."
        ),
    }


def apple_imageio_identity() -> dict[str, object]:
    info_path = pathlib.Path(
        "/System/Library/Frameworks/ImageIO.framework/Resources/Info.plist"
    ).resolve()
    if not info_path.is_file():
        raise SystemExit(f"missing Apple ImageIO Info.plist: {info_path}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    return {
        "name": "AppleImageIO",
        "frameworkIdentifier": info.get("CFBundleIdentifier"),
        "frameworkShortVersion": info.get("CFBundleShortVersionString"),
        "frameworkBundleVersion": info.get("CFBundleVersion"),
        "frameworkPlatformBuild": info.get("DTPlatformBuild"),
        "frameworkSDKBuild": info.get("DTSDKBuild"),
        "infoPlist": support.file_identity(info_path),
        "operatingSystem": {
            "productName": support.run(["sw_vers", "-productName"], ROOT),
            "productVersion": support.run(["sw_vers", "-productVersion"], ROOT),
            "buildVersion": support.run(["sw_vers", "-buildVersion"], ROOT),
        },
        "xcode": support.run(["xcrun", "xcodebuild", "-version"], ROOT).splitlines(),
        "swift": support.run(["xcrun", "swift", "--version"], ROOT).splitlines(),
        "binaryIdentityBoundary": (
            "ImageIO executable is supplied through the dyld shared cache; the capture binds "
            "the OS build, Xcode toolchain, framework bundle metadata and Info.plist digest "
            "rather than claiming a standalone framework-binary hash."
        ),
    }


def validate_resolved_pin(package: pathlib.Path) -> None:
    resolved = json.loads((package / "Package.resolved").read_text())
    delegate = [pin for pin in resolved.get("pins", []) if pin.get("identity") == "delegate"]
    if len(delegate) != 1:
        raise SystemExit("APNG oracle Package.resolved must contain exactly one Delegate pin")
    state = delegate[0].get("state", {})
    if state.get("revision") != DELEGATE_COMMIT or state.get("version") != DELEGATE_VERSION:
        raise SystemExit("APNG oracle Delegate pin mismatch")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    output = args.output.resolve()
    support.ensure_output_location(output, ROOT)
    workspace = ROOT.parent
    imagecraft_root = workspace / "ImageCraft"
    apngkit_root = ROOT / ".artifacts/research/animation-libs/APNGKit"
    package = ROOT / "Benchmarks/ComparativeLab/APNGCompositionOracleLabPackage"
    fixture_root = apngkit_root / "Tests/APNGKitTests/Resources"

    resolve_command = [
        "xcrun",
        "swift",
        "package",
        "resolve",
        "--package-path",
        str(package),
    ]
    support.run(resolve_command, ROOT)
    validate_resolved_pin(package)
    delegate_root = package / ".build/checkouts/Delegate"
    if not delegate_root.is_dir():
        raise SystemExit(f"missing resolved Delegate checkout: {delegate_root}")

    inputs_before = {
        fixture_id: support.file_identity(fixture_root / contract["relativePath"])
        for fixture_id, contract in FIXTURES.items()
    }
    source_before = source_snapshots(imagecraft_root, apngkit_root, delegate_root)
    system_comparators_before = {"AppleImageIO": apple_imageio_identity()}
    mechanism_audit_before = imagecraft_mechanism_audit(imagecraft_root)
    validate_clean_source("APNGKit", source_before["APNGKit"], APNGKIT_COMMIT)
    validate_clean_source("Delegate", source_before["Delegate"], DELEGATE_COMMIT)
    required_imagecraft = [
        imagecraft_root / "Sources/ImageCraftCore/AnimatedImageTypes.swift",
        imagecraft_root / "Sources/ImageCraftImageIO/APNGAnimationInspector.swift",
        imagecraft_root / "Sources/ImageCraftImageIO/ImageIOAnimatedImageDecoder.swift",
    ]
    for path in required_imagecraft:
        if not path.is_file():
            raise SystemExit(f"missing ImageCraft APNG candidate source: {path}")

    source_identity = {
        "schemaVersion": 3,
        "formalClaimEligible": False,
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        "sources": source_before,
        "systemComparators": system_comparators_before,
        "imageCraftMechanismAudit": mechanism_audit_before,
        "inputs": inputs_before,
        "fixtureContract": {
            fixture_id: {
                "relativePath": contract["relativePath"],
                "expectedFrameCount": contract["expectedFrameCount"],
                "expectedCanvasWidth": contract["expectedCanvasWidth"],
                "expectedCanvasHeight": contract["expectedCanvasHeight"],
                "role": contract["role"],
            }
            for fixture_id, contract in FIXTURES.items()
        },
        "claimBoundary": [
            "correctness-only APNG disposal and blend adjudication",
            "APNGKit preRenderAllFrames is not an equivalent performance or memory policy",
            "Apple ImageIO identity is OS/framework-bound and not a declaration of authority",
            "ImageCraft animation source is dirty and unpublished",
            "subrect metadata does not imply an explicit ImageCraft checkpoint or subrect decoded-storage mechanism",
            "local macOS evidence only",
        ],
    }
    source_identity_path = output / "source-identity.json"
    source_identity_path.write_text(
        json.dumps(source_identity, indent=2, sort_keys=True) + "\n"
    )

    build_command = [
        "xcrun",
        "swift",
        "build",
        "--package-path",
        str(package),
        "-c",
        "release",
        "-Xswiftc",
        "-warnings-as-errors",
    ]
    support.run(build_command, ROOT)
    binary_directory = pathlib.Path(
        support.run(
            [
                "xcrun",
                "swift",
                "build",
                "--package-path",
                str(package),
                "-c",
                "release",
                "--show-bin-path",
            ],
            ROOT,
        )
    )
    binary = binary_directory / "W5APNGCompositionOracleLab"
    if not binary.is_file():
        raise SystemExit(f"missing APNG oracle binary: {binary}")

    commands = []
    reports = []
    for fixture_id, contract in FIXTURES.items():
        input_path = fixture_root / contract["relativePath"]
        report_path = output / f"{fixture_id}.json"
        command = [
            str(binary),
            "--fixture-id",
            fixture_id,
            "--input",
            str(input_path.resolve()),
            "--output",
            str(report_path),
            "--source-identity",
            str(source_identity_path),
        ]
        support.run(command, ROOT)
        commands.append(command)
        reports.append(str(report_path))

    inputs_after = {
        fixture_id: support.file_identity(fixture_root / contract["relativePath"])
        for fixture_id, contract in FIXTURES.items()
    }
    source_after = source_snapshots(imagecraft_root, apngkit_root, delegate_root)
    system_comparators_after = {"AppleImageIO": apple_imageio_identity()}
    mechanism_audit_after = imagecraft_mechanism_audit(imagecraft_root)
    sources_unchanged = source_before == source_after
    system_comparators_unchanged = (
        system_comparators_before == system_comparators_after
    )
    mechanism_audit_unchanged = mechanism_audit_before == mechanism_audit_after
    inputs_unchanged = inputs_before == inputs_after
    manifest = {
        "schemaVersion": 3,
        "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "reason": (
            "correctness-only local oracle; dirty unpublished ImageCraft source and "
            "APNGKit pre-render policy are not an integrated product claim"
        ),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "swift": support.run(["xcrun", "swift", "--version"], ROOT).splitlines(),
        },
        "resolveCommand": resolve_command,
        "buildCommand": build_command,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": sources_unchanged,
        "systemComparatorsBefore": system_comparators_before,
        "systemComparatorsAfter": system_comparators_after,
        "systemComparatorsUnchangedDuringCapture": system_comparators_unchanged,
        "imageCraftMechanismAuditBefore": mechanism_audit_before,
        "imageCraftMechanismAuditAfter": mechanism_audit_after,
        "imageCraftMechanismAuditUnchangedDuringCapture": mechanism_audit_unchanged,
        "inputsBefore": inputs_before,
        "inputsAfter": inputs_after,
        "inputsUnchangedDuringCapture": inputs_unchanged,
        "sourceIdentity": support.file_identity(source_identity_path),
        "labBinary": support.file_identity(binary),
        "governingFiles": {
            "captureRunner": support.file_identity(pathlib.Path(__file__).resolve()),
            "validator": support.file_identity(
                pathlib.Path(__file__).with_name("validate_w5_apng_composition_oracle.py")
            ),
            "packageManifest": support.file_identity(package / "Package.swift"),
            "packageResolved": support.file_identity(package / "Package.resolved"),
            "mechanismPlan": support.file_identity(
                ROOT / "Benchmarks/ComparativeLab/animated-player-mechanism-plan.json"
            ),
        },
        "commands": commands,
        "reports": reports,
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    if not sources_unchanged:
        raise SystemExit(f"source changed during APNG oracle capture: {manifest_path}")
    if not system_comparators_unchanged:
        raise SystemExit(
            f"system comparator changed during APNG oracle capture: {manifest_path}"
        )
    if not mechanism_audit_unchanged:
        raise SystemExit(
            f"ImageCraft mechanism audit changed during APNG oracle capture: {manifest_path}"
        )
    if not inputs_unchanged:
        raise SystemExit(f"input changed during APNG oracle capture: {manifest_path}")

    validator = pathlib.Path(__file__).with_name(
        "validate_w5_apng_composition_oracle.py"
    )
    support.run([sys.executable, str(validator), str(output)], ROOT)
    print(output / "aggregate.json")


if __name__ == "__main__":
    main()
