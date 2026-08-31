#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKSPACE = ROOT.parent
IMAGECRAFT = WORKSPACE / "ImageCraft"
AKASHIC = WORKSPACE / "Akashic"
FIXTURE_DIR = pathlib.Path(__file__).resolve().parent
DEFAULT_OUTPUT = ROOT / ".artifacts/qualification/w5-imagecraft-animation-adapter-v2-final"
STABLE_WORK = pathlib.Path(tempfile.gettempdir()) / "fovea-imagecraft-animation-adapter-v2-work"
FOVEA_IMPLEMENTATION_FILES = (
    "Package.swift",
    "Sources/FoveaCore/AnimationFrameMemory.swift",
    "Sources/FoveaCore/FoveaCompactSieveCache.swift",
    "Sources/FoveaCore/AnimationPlaybackCoordinator.swift",
    "Sources/FoveaCore/AnimationPlaybackCursor.swift",
    "Sources/FoveaCore/AnimationPlaybackDriver.swift",
    "Sources/FoveaCore/AnimationPlaybackResidentFramesSnapshot.swift",
    "Sources/FoveaCore/AnimationPlaybackRuntime.swift",
    "Sources/FoveaCore/AnimationPlaybackSession.swift",
    "Sources/FoveaCore/AnimationPlaybackTimeline.swift",
    "Sources/FoveaCore/AsyncPermitPool.swift",
    "Sources/FoveaCore/AuthorizedAnimationPlaybackAsset.swift",
    "Sources/FoveaCore/DecodeStage.swift",
    "Sources/FoveaCore/EncodedDataCoordinator.swift",
    "Sources/FoveaCore/FoveaPipeline.swift",
    "Sources/FoveaCore/FoveaPipelineInitialization.swift",
    "Sources/FoveaCore/ImageRequest.swift",
    "Sources/FoveaCore/PipelineFailure+ImageCraft.swift",
    "Sources/FoveaSystem/FoveaSystemAnimatedImage.swift",
    "Sources/FoveaSystem/FoveaSystemPipeline.swift",
)


def run(command: list[str], cwd: pathlib.Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"{completed.stdout}{completed.stderr}"
        )
    return completed


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"byteCount": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def fovea_implementation_identity() -> dict[str, object]:
    return {
        relative: file_identity(ROOT / relative)
        for relative in FOVEA_IMPLEMENTATION_FILES
    }


def working_tree_identity(root: pathlib.Path) -> str:
    with tempfile.TemporaryDirectory(prefix="fovea-adapter-index-") as temporary:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(pathlib.Path(temporary) / "index")
        subprocess.run(
            ["git", "read-tree", "HEAD"],
            cwd=root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        subprocess.run(["git", "add", "-A", "--", "."], cwd=root, env=env, check=True)
        return subprocess.check_output(["git", "write-tree"], cwd=root, env=env, text=True).strip()


def snapshot(root: pathlib.Path) -> dict[str, object]:
    return {
        "headCommit": run(["git", "rev-parse", "HEAD"], root).stdout.strip(),
        "workingTree": working_tree_identity(root),
        "statusShort": run(["git", "status", "--short"], root).stdout.splitlines(),
    }


def copy_package_source(
    source: pathlib.Path,
    destination: pathlib.Path,
    entries: tuple[str, ...],
) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for name in entries:
        src = source / name
        if not src.exists():
            continue
        dst = destination / name
        if src.is_dir():
            shutil.copytree(
                src,
                dst,
                ignore=shutil.ignore_patterns(
                    ".git", ".build", ".artifacts", ".swiftpm", "__pycache__"
                ),
                copy_function=shutil.copyfile,
            )
        else:
            shutil.copyfile(src, dst)


def reset_overlay_package(destination: pathlib.Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for child in destination.iterdir():
        if child.name == ".build":
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def patch_fovea_package(path: pathlib.Path) -> None:
    text = path.read_text()
    imagecraft = re.sub(
        r'\.package\(\s*url: "https://github\.com/YuLeiFuYun/ImageCraft\.git",\s*revision: "[0-9a-f]+"\s*\)',
        '.package(path: "../ImageCraft")',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if imagecraft == text:
        raise RuntimeError("ImageCraft dependency pattern not found")
    akashic = re.sub(
        r'\.package\(\s*url: "https://github\.com/YuLeiFuYun/Akashic\.git",\s*revision: "[0-9a-f]+"\s*\)',
        '.package(path: "../Akashic")',
        imagecraft,
        count=1,
        flags=re.MULTILINE,
    )
    if akashic == imagecraft:
        raise RuntimeError("Akashic dependency pattern not found")
    path.write_text(akashic)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    output = args.output.resolve()
    allowed = (ROOT / ".artifacts/qualification").resolve()
    try:
        output.relative_to(allowed)
    except ValueError as error:
        raise SystemExit(f"output must remain under {allowed}") from error
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    sources_before = {name: snapshot(path) for name, path in {
        "Fovea": ROOT,
        "ImageCraft": IMAGECRAFT,
        "Akashic": AKASHIC,
    }.items()}
    fovea_implementation_before = fovea_implementation_identity()
    adapter_fixture = FIXTURE_DIR / "ImageCraftAnimationPlaybackPreparer.swift.fixture"
    test_fixture = FIXTURE_DIR / "ImageCraftAnimationPlaybackQualificationMain.swift.fixture"
    fixtures = {
        "adapter": {"sha256": sha256(adapter_fixture), "byteCount": adapter_fixture.stat().st_size},
        "test": {"sha256": sha256(test_fixture), "byteCount": test_fixture.stat().st_size},
    }
    governing_paths = {
        "runner": pathlib.Path(__file__).resolve(),
        "validator": FIXTURE_DIR / "validate_imagecraft_animation_adapter_qualification.py",
        "tamperContract": FIXTURE_DIR / "test_imagecraft_animation_adapter_qualification.py",
        "formatterConfig": ROOT / ".swift-format",
    }
    governing = {
        name: {"sha256": sha256(path), "byteCount": path.stat().st_size}
        for name, path in governing_paths.items()
    }

    work = STABLE_WORK
    work.mkdir(parents=True, exist_ok=True)
    overlay_fovea = work / "Fovea"
    overlay_imagecraft = work / "ImageCraft"
    overlay_akashic = work / "Akashic"
    adapter_target = overlay_fovea / "Sources/FoveaSystem/ImageCraftAnimationPlaybackPreparer.swift"
    qualification_dir = overlay_fovea / "Tools/ImageCraftAnimationAdapterQualification"
    test_target = qualification_dir / "main.swift"
    overlay_identity = {
        "sourceWorkingTrees": {
            name: value["workingTree"] for name, value in sources_before.items()
        },
        "fixtures": fixtures,
    }
    identity_path = work / ".source-identity.json"
    reuse_overlay = False
    if identity_path.is_file():
        try:
            reuse_overlay = json.loads(identity_path.read_text()) == overlay_identity
        except (json.JSONDecodeError, OSError):
            reuse_overlay = False
    reuse_overlay = reuse_overlay and adapter_target.is_file() and test_target.is_file()

    if not reuse_overlay:
        for package in (overlay_fovea, overlay_imagecraft, overlay_akashic):
            reset_overlay_package(package)
        copy_package_source(
            ROOT,
            overlay_fovea,
            ("Package.swift", ".swift-format", "Sources", "Tests", "Tools", "Examples"),
        )
        copy_package_source(
            IMAGECRAFT, overlay_imagecraft, ("Package.swift", "Sources", "Tests")
        )
        copy_package_source(
            AKASHIC, overlay_akashic, ("Package.swift", "Sources", "Tests")
        )
        patch_fovea_package(overlay_fovea / "Package.swift")
        qualification_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(adapter_fixture, adapter_target)
        shutil.copyfile(test_fixture, test_target)
        package_path = overlay_fovea / "Package.swift"
        package_text = package_path.read_text()
        target = '''
        .executableTarget(
            name: "ImageCraftAnimationAdapterQualification",
            dependencies: [
                "FoveaCore", "FoveaSystem",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ],
            path: "Tools/ImageCraftAnimationAdapterQualification",
            swiftSettings: concurrencySettings
        ),
'''
        marker = "    ],\n    swiftLanguageModes: [.v6]"
        if marker not in package_text:
            raise RuntimeError("Fovea target-list marker not found")
        package_path.write_text(package_text.replace(marker, target + marker, 1))
        identity_path.write_text(json.dumps(overlay_identity, sort_keys=True) + "\n")

    format_result = run(
        ["xcrun", "swift-format", "lint", "--strict", str(adapter_target), str(test_target)],
        overlay_fovea,
        check=False,
    )
    test_command = [
        "xcrun", "swift", "run",
        "-Xswiftc", "-warnings-as-errors",
        "ImageCraftAnimationAdapterQualification",
    ]
    test_result = run(test_command, overlay_fovea, check=False)
    log = output / "qualification.log"
    log.write_text(test_result.stdout + test_result.stderr)
    format_log = output / "format.log"
    format_log.write_text(format_result.stdout + format_result.stderr)

    sources_after = {name: snapshot(path) for name, path in {
        "Fovea": ROOT,
        "ImageCraft": IMAGECRAFT,
        "Akashic": AKASHIC,
    }.items()}
    fovea_implementation_after = fovea_implementation_identity()
    report = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-IMAGECRAFT-ANIMATION-ADAPTER-OVERLAY-QUALIFICATION-V2",
        "generatedAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "sourcesBefore": sources_before,
        "sourcesAfter": sources_after,
        "sourcesUnchangedDuringRun": sources_before == sources_after,
        "foveaImplementationBefore": fovea_implementation_before,
        "foveaImplementationAfter": fovea_implementation_after,
        "foveaImplementationUnchangedDuringRun": (
            fovea_implementation_before == fovea_implementation_after
        ),
        "fixtureIdentity": fixtures,
        "governingFiles": governing,
        "overlay": {
            "productionPackageModified": False,
            "productionImageCraftPinChanged": False,
            "usesCopiedFoveaSource": True,
            "usesCopiedImageCraftSource": True,
            "usesCopiedAkashicSource": True,
        },
        "format": {
            "returnCode": format_result.returncode,
            "log": "format.log",
            "sha256": sha256(format_log),
        },
        "qualification": {
            "command": test_command,
            "returnCode": test_result.returncode,
            "log": "qualification.log",
            "sha256": sha256(log),
        },
        "claimBoundary": [
            "isolated local source-overlay qualification only",
            "does not modify or publish the production Fovea ImageCraft pin",
            "does not establish physical-device timing, memory, energy, thermal, or release readiness",
            "adapter timing normalization remains explicit and caller-versioned",
            "automatic whole-track admission requires preparer-supplied resident-decoded, provider-retained, and predecode-peak byte upper bounds; decoded pixels plus provider-retained state share the Fovea animation resident-memory budget",
            "ImageCraft provider ranges are chunked to the decoder maximum-frame-window contract",
            "automatic animation predecode shares FoveaSystem global decode working-set and decode-concurrency admission with static decode",
        ],
    }
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    succeeded = (
        format_result.returncode == 0
        and test_result.returncode == 0
        and sources_before == sources_after
        and fovea_implementation_before == fovea_implementation_after
    )
    if succeeded:
        shutil.rmtree(work)
    print(report_path)
    return 0 if succeeded else 1


if __name__ == "__main__":
    raise SystemExit(main())
