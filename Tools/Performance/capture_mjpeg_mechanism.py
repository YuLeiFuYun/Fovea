#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
from datetime import datetime, timezone

RELEVANT_FILES = [
    "Sources/FoveaCore/MultipartJPEGLivePlayback.swift",
    "Sources/FoveaCore/MultipartJPEGLivePlaybackTypes.swift",
    "Sources/FoveaCore/MultipartJPEGLiveDiagnostics.swift",
    "Tools/FoveaNetworkLab/MJPEGMechanismLab.swift",
    "Tools/Performance/capture_mjpeg_mechanism.py",
    "Tools/Performance/validate_mjpeg_mechanism.py",
]


def run(command: list[str], root: pathlib.Path) -> str:
    completed = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, check=False)
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        raise SystemExit(f"command failed ({completed.returncode}): {' '.join(command)}")
    return completed.stdout


def sha(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--blocks", type=int, default=6)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if args.blocks <= 0 or args.blocks > 32:
        raise SystemExit("blocks must be in 1...32")
    root = pathlib.Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        run(["xcrun", "swift", "build", "-c", "release", "--product",
             "FoveaNetworkLab", "-Xswiftc", "-warnings-as-errors"], root)
    binary = pathlib.Path(run(
        ["xcrun", "swift", "build", "-c", "release", "--show-bin-path"], root
    ).strip()) / "FoveaNetworkLab"
    if not binary.is_file():
        raise SystemExit(f"missing binary: {binary}")
    reports = []
    for block in range(args.blocks):
        path = output / f"block-{block:02d}.json"
        path.write_text(run([str(binary), "--mjpeg-mechanism"], root))
        reports.append(str(path))
    manifest = {
        "schemaVersion": 1,
        "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "formalClaimEligible": False,
        "reason": "dirty local synthetic mechanism evidence; no device, network, energy or codec-throughput claim",
        "blockCount": args.blocks,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "source": {
            "head": run(["git", "rev-parse", "HEAD"], root).strip(),
            "statusShort": run(["git", "status", "--short"], root).splitlines(),
            "relevantFiles": {name: sha(root / name) for name in RELEVANT_FILES},
            "binarySHA256": sha(binary),
        },
        "reports": reports,
    }
    (output / "capture-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    validator = pathlib.Path(__file__).with_name("validate_mjpeg_mechanism.py")
    run([sys.executable, str(validator), str(output), "--blocks", str(args.blocks)], root)
    print(output / "aggregate.json")


if __name__ == "__main__":
    main()
