#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import select
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
COMPONENT_PINS = ROOT / "docs/project-memory/component-pins.json"


def run(
    command: list[str],
    *,
    cwd: Path = ROOT,
    timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
        env=ENV,
    )


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_akashic_repository() -> Path:
    configured = ENV.get("FOVEA_AKASHIC_REPOSITORY")
    candidates = []
    if configured:
        candidates.append(Path(configured).expanduser())
    candidates.extend((ROOT / ".build/checkouts/Akashic", ROOT.parent / "Akashic"))
    for candidate in candidates:
        candidate = candidate.resolve()
        if (candidate / ".git").exists():
            return candidate
    raise RuntimeError(
        "resolved Akashic checkout is required; run swift package resolve or set FOVEA_AKASHIC_REPOSITORY"
    )


def generation_contention() -> dict[str, object]:
    lock = json.loads(COMPONENT_PINS.read_text())
    expected_commit = lock["components"]["Akashic"]["revision"]
    repository = resolve_akashic_repository()
    head = run(["git", "rev-parse", "HEAD"], cwd=repository)
    if head.returncode != 0 or head.stdout.strip() != expected_commit:
        raise RuntimeError(
            f"Akashic HEAD must equal locked commit {expected_commit}; observed={head.stdout.strip()}"
        )
    status = run(["git", "status", "--porcelain"], cwd=repository)
    if status.returncode != 0 or status.stdout.strip():
        raise RuntimeError("Akashic working tree must be clean for generation contention evidence")

    verification = run(
        [str(repository / "scripts/verify-store-generation-contention.py")],
        cwd=repository,
        timeout=240,
    )
    if verification.returncode != 0:
        raise RuntimeError(
            "Akashic generation contention failed:\n"
            + verification.stdout
            + verification.stderr
        )
    evidence = repository / ".artifacts/store-generation/contention.json"
    if not evidence.is_file():
        raise RuntimeError("Akashic generation contention artifact is missing")
    report = json.loads(evidence.read_text())
    if report.get("verifiedCommit") != expected_commit or report.get("status") != "passed":
        raise RuntimeError("Akashic generation contention artifact is stale or failing")
    if report.get("participants", 0) < 2 or len(report.get("uniqueGenerationIdentifiers", [])) != 1:
        raise RuntimeError("Akashic generation contention did not converge to one generation")
    return {
        **report,
        "component": "Akashic",
        "componentCommit": expected_commit,
        "evidenceSHA256": digest(evidence),
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
    first_acquired = first_line == "acquired"
    if not first_acquired:
        errors.append("first writer did not report acquisition")

    second = run([str(probe), "writer", str(root), "0"], timeout=10)
    second_rejected = second.returncode != 0 and "writerAlreadyActive" in second.stderr
    if not second_rejected:
        errors.append(
            "second writer was not rejected: "
            f"exit={second.returncode} stdout={second.stdout.strip()} stderr={second.stderr.strip()}"
        )

    first_remaining_stdout, first_stderr = first.communicate(timeout=10)
    if first.returncode != 0:
        errors.append(f"first writer exit={first.returncode} stderr={first_stderr.strip()}")
    if first_remaining_stdout.strip():
        errors.append(f"first writer produced unexpected output: {first_remaining_stdout.strip()}")

    third = run([str(probe), "writer", str(root), "0"], timeout=10)
    reacquired_after_exit = third.returncode == 0 and third.stdout.strip() == "acquired"
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
    try:
        generation = generation_contention()
    except (OSError, RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        print(str(error))
        return 1

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

    with tempfile.TemporaryDirectory(prefix="fovea-store-writer-") as temporary:
        writer = writer_exclusion(probe, Path(temporary) / "writer")
    status = "passed" if writer["status"] == "passed" else "failed"
    head = run(["git", "rev-parse", "HEAD"])
    report = {
        "schemaVersion": 3,
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


if __name__ == "__main__":
    raise SystemExit(main())
