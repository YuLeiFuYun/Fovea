#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV = os.environ.copy()
if not ENV.get("DEVELOPER_DIR"):
    selection = subprocess.run(
        [str(ROOT / "scripts/select-xcode.sh")],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env=ENV,
    )
    if selection.returncode != 0:
        raise SystemExit(selection.stderr.strip() or "unable to select Xcode")
    ENV["DEVELOPER_DIR"] = selection.stdout.strip()
ARTIFACT = ROOT / ".artifacts/store-generation/contention.json"
PARTICIPANTS = 12
FINGERPRINT = "fovea-store-contention-v1"


def run(command: list[str], timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
        env=ENV,
    )


def generation_contention(probe: Path, root: Path) -> dict[str, object]:
    processes = [
        subprocess.Popen(
            [str(probe), "generation", str(root), FINGERPRINT, "75"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=ENV,
        )
        for _ in range(PARTICIPANTS)
    ]
    identifiers: list[str] = []
    errors: list[str] = []
    for process in processes:
        stdout, stderr = process.communicate(timeout=30)
        if process.returncode != 0:
            errors.append(f"exit={process.returncode} stderr={stderr.strip()}")
        elif stdout.strip():
            identifiers.append(stdout.strip())
        else:
            errors.append("probe returned an empty identifier")

    unique = sorted(set(identifiers))
    passed = not errors and len(identifiers) == PARTICIPANTS and len(unique) == 1
    return {
        "participants": PARTICIPANTS,
        "successfulParticipants": len(identifiers),
        "uniqueGenerationIdentifiers": unique,
        "errors": errors,
        "status": "passed" if passed else "failed",
    }


def writer_exclusion(probe: Path, root: Path) -> dict[str, object]:
    errors: list[str] = []
    first = subprocess.Popen(
        [str(probe), "writer", str(root), "1200"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=ENV,
    )
    assert first.stdout is not None
    ready, _, _ = select.select([first.stdout], [], [], 10)
    first_line = first.stdout.readline().strip() if ready else ""
    first_acquired = first_line.startswith("acquired:")
    if not first_acquired:
        errors.append("first writer did not report acquisition")

    second = run([str(probe), "writer", str(root), "0"], timeout=10)
    second_rejected = (
        second.returncode != 0 and "writerAlreadyActive" in second.stderr
    )
    if not second_rejected:
        errors.append(
            "second writer was not rejected: "
            f"exit={second.returncode} stdout={second.stdout.strip()} stderr={second.stderr.strip()}"
        )

    first_remaining_stdout, first_stderr = first.communicate(timeout=10)
    if first.returncode != 0:
        errors.append(
            f"first writer exit={first.returncode} stderr={first_stderr.strip()}"
        )
    if first_remaining_stdout.strip():
        errors.append(f"first writer produced unexpected output: {first_remaining_stdout.strip()}")

    third = run([str(probe), "writer", str(root), "0"], timeout=10)
    reacquired_after_exit = third.returncode == 0 and third.stdout.startswith("acquired:")
    if not reacquired_after_exit:
        errors.append(
            "writer lease was not reacquired after owner exit: "
            f"exit={third.returncode} stdout={third.stdout.strip()} stderr={third.stderr.strip()}"
        )

    passed = first_acquired and second_rejected and reacquired_after_exit and not errors
    return {
        "firstWriterAcquired": first_acquired,
        "secondWriterRejected": second_rejected,
        "reacquiredAfterOwnerExit": reacquired_after_exit,
        "errors": errors,
        "status": "passed" if passed else "failed",
    }


def main() -> int:
    build = run(["xcrun", "swift", "build", "--product", "FoveaStoreProbe"])
    if build.returncode != 0:
        print(build.stdout)
        print(build.stderr)
        return build.returncode

    bin_path = run(["xcrun", "swift", "build", "--show-bin-path"])
    if bin_path.returncode != 0:
        print(bin_path.stdout)
        print(bin_path.stderr)
        return bin_path.returncode
    probe = Path(bin_path.stdout.strip()) / "FoveaStoreProbe"
    if not probe.is_file():
        print(f"probe binary missing: {probe}")
        return 1

    temporary = Path(tempfile.mkdtemp(prefix="fovea-store-contention-"))
    try:
        generation = generation_contention(probe, temporary / "generation")
        writer = writer_exclusion(probe, temporary / "writer")
        status = (
            "passed"
            if generation["status"] == "passed" and writer["status"] == "passed"
            else "failed"
        )
        head = run(["git", "rev-parse", "HEAD"])
        report = {
            "schemaVersion": 2,
            "verifiedCommit": head.stdout.strip(),
            "participants": generation["participants"],
            "uniqueGenerationIdentifiers": generation["uniqueGenerationIdentifiers"],
            "generationSelection": generation,
            "writerExclusion": writer,
            "status": status,
        }
        ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
        ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            f"Store persistence contention {status}: "
            f"generation={generation['status']} writer={writer['status']}"
        )
        print(f"Artifact: {ARTIFACT.relative_to(ROOT)}")
        return 0 if status == "passed" else 1
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
