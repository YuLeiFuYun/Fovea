#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

COMPARATORS = ["ImageCraft", "SDWebImage", "PINRemoteImage"]
FORMATS = ["gif", "apng"]
COMPARATOR_VERSIONS = {
    "ImageCraft": "local-animation-contract-v1",
    "SDWebImage": "5.21.7",
    "PINRemoteImage": "releases/p14.31",
}
EXPECTED_CLEAN_COMPARATOR_COMMITS = {
    "SDWebImage": "2de3a496eaf6df9a1312862adcfd54acd73c39c0",
    "PINRemoteImage": "c0d5cfa1947f2456ddb321a85b347b3d60d83254",
}
REQUIRED_IMAGECRAFT_ANIMATION_FILES = [
    "Sources/ImageCraftCore/AnimatedImageTypes.swift",
    "Sources/ImageCraftImageIO/APNGAnimationInspector.swift",
    "Sources/ImageCraftImageIO/AnimatedContainerInspector.swift",
    "Sources/ImageCraftImageIO/AnimationDecodedByteBudget.swift",
    "Sources/ImageCraftImageIO/GIFAnimationInspector.swift",
    "Sources/ImageCraftImageIO/ImageIOAnimatedImageDecoder.swift",
    "Sources/ImageCraftImageIO/ImageIOAnimationFrameProvider.swift",
    "Sources/ImageCraftImageIO/ImageIOAnimationFrameRenderer.swift",
]


def run(
    command: list[str],
    cwd: pathlib.Path,
    *,
    env: dict[str, str] | None = None,
) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        raise SystemExit(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout.strip()


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_identity(path: pathlib.Path) -> dict[str, object]:
    return {
        "path": str(path),
        "byteCount": path.stat().st_size,
        "sha256": file_sha256(path),
    }


def working_tree_identity(root: pathlib.Path) -> str:
    with tempfile.TemporaryDirectory(prefix="w5-animation-source-index-") as temporary:
        index = pathlib.Path(temporary) / "index"
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(index)
        run(["git", "read-tree", "HEAD"], root, env=env)
        run(["git", "add", "-A", "--", "."], root, env=env)
        return run(["git", "write-tree"], root, env=env)


def git_snapshot(root: pathlib.Path) -> dict[str, object]:
    head = run(["git", "rev-parse", "HEAD"], root)
    head_tree = run(["git", "rev-parse", "HEAD^{tree}"], root)
    working_tree = working_tree_identity(root)
    return {
        "root": str(root.resolve()),
        "headCommit": head,
        "headTree": head_tree,
        "workingTree": working_tree,
        "dirty": working_tree != head_tree,
        "statusShort": run(["git", "status", "--short"], root).splitlines(),
        "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
    }


def source_snapshots(
    fovea_root: pathlib.Path,
    imagecraft_root: pathlib.Path,
    comparator_roots: dict[str, pathlib.Path],
) -> dict[str, object]:
    return {
        "Fovea": git_snapshot(fovea_root),
        "comparators": {
            "ImageCraft": {
                "version": COMPARATOR_VERSIONS["ImageCraft"],
                **git_snapshot(imagecraft_root),
            },
            **{
                name: {
                    "version": COMPARATOR_VERSIONS[name],
                    **git_snapshot(root),
                }
                for name, root in comparator_roots.items()
            },
        },
    }


def validate_source_contract(
    source: dict[str, object],
    imagecraft_root: pathlib.Path,
) -> None:
    comparators = source["comparators"]
    if not isinstance(comparators, dict):
        raise SystemExit("invalid comparator source snapshot")
    for relative in REQUIRED_IMAGECRAFT_ANIMATION_FILES:
        path = imagecraft_root / relative
        if not path.is_file():
            raise SystemExit(f"missing ImageCraft animation candidate source: {path}")
    for name, expected_commit in EXPECTED_CLEAN_COMPARATOR_COMMITS.items():
        snapshot = comparators.get(name)
        if not isinstance(snapshot, dict):
            raise SystemExit(f"missing comparator source snapshot: {name}")
        if snapshot.get("headCommit") != expected_commit:
            raise SystemExit(
                f"{name} commit mismatch: expected {expected_commit}, "
                f"got {snapshot.get('headCommit')}"
            )
        if snapshot.get("dirty") is not False:
            raise SystemExit(f"{name} comparator checkout must be clean")
        if snapshot.get("workingTree") != snapshot.get("headTree"):
            raise SystemExit(f"{name} clean tree identity mismatch")


def comparator_identity_arguments(
    comparator: str,
    source: dict[str, object],
) -> list[str]:
    comparators = source["comparators"]
    if not isinstance(comparators, dict):
        raise SystemExit("invalid comparator source snapshot")
    snapshot = comparators.get(comparator)
    if not isinstance(snapshot, dict):
        raise SystemExit(f"missing comparator source snapshot: {comparator}")
    return [
        "--comparator-version",
        str(snapshot["version"]),
        "--source-head",
        str(snapshot["headCommit"]),
        "--source-tree",
        str(snapshot["workingTree"]),
        "--source-dirty",
        "true" if snapshot["dirty"] else "false",
    ]


def ensure_output_location(output: pathlib.Path, fovea_root: pathlib.Path) -> None:
    output = output.resolve()
    allowed = (fovea_root.resolve() / ".artifacts/performance").resolve()
    try:
        output.relative_to(allowed)
    except ValueError as error:
        raise SystemExit(f"output must be under {allowed}") from error
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f"output directory must be empty: {output}")
    output.mkdir(parents=True, exist_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gif", required=True, type=pathlib.Path)
    parser.add_argument("--apng", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--blocks", type=int, default=6)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=2)
    args = parser.parse_args()
    if args.blocks <= 0 or args.iterations <= 0 or args.warmups < 0:
        raise SystemExit("invalid blocks, iterations, or warmups")

    fovea_root = pathlib.Path(__file__).resolve().parents[2]
    workspace = fovea_root.parent
    imagecraft_root = workspace / "ImageCraft"
    lab_package = fovea_root / "Benchmarks/ComparativeLab/AnimatedCodecLabPackage"
    output = args.output.resolve()
    ensure_output_location(output, fovea_root)

    comparator_roots = {
        "SDWebImage": fovea_root / ".artifacts/comparators/sources/SDWebImage",
        "PINRemoteImage": fovea_root / ".artifacts/comparators/sources/PINRemoteImage",
    }
    inputs = {"gif": args.gif.resolve(), "apng": args.apng.resolve()}
    for fmt, path in inputs.items():
        if not path.is_file():
            raise SystemExit(f"missing {fmt} input: {path}")
    input_before = {fmt: file_identity(path) for fmt, path in inputs.items()}
    source_before = source_snapshots(fovea_root, imagecraft_root, comparator_roots)
    validate_source_contract(source_before, imagecraft_root)

    build_command = [
        "xcrun",
        "swift",
        "build",
        "--package-path",
        str(lab_package),
        "-c",
        "release",
        "-Xswiftc",
        "-warnings-as-errors",
    ]
    run(build_command, fovea_root)
    binary_directory = pathlib.Path(
        run(
            [
                "xcrun",
                "swift",
                "build",
                "--package-path",
                str(lab_package),
                "-c",
                "release",
                "--show-bin-path",
            ],
            fovea_root,
        )
    )
    binary = binary_directory / "W5AnimatedCodecLab"
    if not binary.is_file():
        raise SystemExit(f"missing lab binary: {binary}")

    blocks = []
    for block in range(args.blocks):
        comparator_order = COMPARATORS[block % 3 :] + COMPARATORS[: block % 3]
        format_order = FORMATS if block % 2 == 0 else list(reversed(FORMATS))
        block_directory = output / f"block-{block:02d}"
        block_directory.mkdir(parents=True, exist_ok=True)
        commands = []
        for fmt in format_order:
            for comparator in comparator_order:
                report = block_directory / f"{fmt}-{comparator}.json"
                command = [
                    str(binary),
                    "--comparator",
                    comparator,
                    "--format",
                    fmt,
                    "--input",
                    str(inputs[fmt]),
                    "--output",
                    str(report),
                    "--frame-index",
                    "12",
                    "--iterations",
                    str(args.iterations),
                    "--warmups",
                    str(args.warmups),
                    *comparator_identity_arguments(comparator, source_before),
                ]
                run(command, fovea_root)
                commands.append(command)
        blocks.append(
            {
                "block": block,
                "formatOrder": format_order,
                "comparatorOrder": comparator_order,
                "commands": commands,
            }
        )

    input_after = {fmt: file_identity(path) for fmt, path in inputs.items()}
    source_after = source_snapshots(fovea_root, imagecraft_root, comparator_roots)
    sources_unchanged = source_before == source_after
    inputs_unchanged = input_before == input_after
    manifest = {
        "schemaVersion": 2,
        "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "reason": (
            "dirty local macOS codec-only directional evidence; the ImageCraft animation "
            "candidate is unpublished and Fovea player physical-device gates are incomplete"
        ),
        "blockCount": args.blocks,
        "iterationsPerReport": args.iterations,
        "warmupsPerReport": args.warmups,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "swift": run(["xcrun", "swift", "--version"], fovea_root).splitlines(),
        },
        "inputsBefore": input_before,
        "inputsAfter": input_after,
        "inputsUnchangedDuringCapture": inputs_unchanged,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": sources_unchanged,
        "labBinary": file_identity(binary),
        "governingFiles": {
            "captureRunner": file_identity(pathlib.Path(__file__).resolve()),
            "validator": file_identity(pathlib.Path(__file__).with_name("validate_w5_animated_codec.py")),
            "plan": file_identity(
                fovea_root / "Benchmarks/ComparativeLab/animated-image-plan.json"
            ),
            "packageManifest": file_identity(lab_package / "Package.swift"),
            "packageResolved": file_identity(lab_package / "Package.resolved"),
        },
        "buildCommand": build_command,
        "blocks": blocks,
    }
    manifest_path = output / "capture-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    if not sources_unchanged:
        raise SystemExit(f"source changed during W5 capture: {manifest_path}")
    if not inputs_unchanged:
        raise SystemExit(f"input changed during W5 capture: {manifest_path}")

    validator = pathlib.Path(__file__).with_name("validate_w5_animated_codec.py")
    run(
        [
            sys.executable,
            str(validator),
            str(output),
            "--blocks",
            str(args.blocks),
            "--samples-per-report",
            str(args.iterations),
        ],
        fovea_root,
    )
    print(output / "aggregate.json")


if __name__ == "__main__":
    main()
