#!/usr/bin/env python3
"""Run bounded, change-aware Fovea verification profiles.

The maximal qualification matrix remains in scripts/verify.sh. This orchestrator
handles the default smart gate and the deterministic premerge/release profiles.
Unknown changes fail closed by escalating to premerge rather than being skipped.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import shlex
import subprocess
import sys
import threading
import time
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / ".artifacts/verification"
PROFILE_CHOICES = ("iteration", "smart", "premerge", "release", "workbench-smoke")
_ACTIVE_PROCESS_GROUPS: set[int] = set()
_ACTIVE_PROCESS_GROUPS_LOCK = threading.Lock()
_RUN_ARTIFACTS: Path | None = None


def register_process_group(identifier: int) -> None:
    with _ACTIVE_PROCESS_GROUPS_LOCK:
        _ACTIVE_PROCESS_GROUPS.add(identifier)


def unregister_process_group(identifier: int) -> None:
    with _ACTIVE_PROCESS_GROUPS_LOCK:
        _ACTIVE_PROCESS_GROUPS.discard(identifier)


def process_group_exists(identifier: int) -> bool:
    try:
        os.killpg(identifier, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_group(identifier: int) -> None:
    try:
        os.killpg(identifier, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 5
    while process_group_exists(identifier) and time.monotonic() < deadline:
        time.sleep(0.1)
    if not process_group_exists(identifier):
        return
    try:
        os.killpg(identifier, signal.SIGKILL)
    except ProcessLookupError:
        pass


def terminate_active_process_groups() -> None:
    with _ACTIVE_PROCESS_GROUPS_LOCK:
        groups = tuple(_ACTIVE_PROCESS_GROUPS)
    for identifier in groups:
        terminate_process_group(identifier)


def verification_signal_handler(signum: int, _frame: object) -> None:
    terminate_active_process_groups()
    raise SystemExit(128 + signum)


def install_signal_handlers() -> None:
    signal.signal(signal.SIGINT, verification_signal_handler)
    signal.signal(signal.SIGTERM, verification_signal_handler)


@dataclass(frozen=True)
class Phase:
    name: str
    command: tuple[str, ...]
    timeout: int = 900


@dataclass
class PhaseResult:
    name: str
    command: list[str]
    return_code: int
    elapsed_seconds: float
    log: str


@dataclass(frozen=True)
class SourceState:
    head_commit: str
    working_tree: str
    dirty: bool


def active_artifacts() -> Path:
    return _RUN_ARTIFACTS or ARTIFACTS


def verification_run_id(now: dt.datetime | None = None) -> str:
    instant = now or dt.datetime.now(dt.timezone.utc)
    return f"{instant.strftime('%Y%m%dT%H%M%S.%fZ')}-{os.getpid()}"


def create_run_artifacts() -> Path:
    global _RUN_ARTIFACTS
    if _RUN_ARTIFACTS is not None:
        raise RuntimeError("verification run artifacts are already initialized")
    path = ARTIFACTS / "runs" / verification_run_id()
    path.mkdir(parents=True, exist_ok=False)
    _RUN_ARTIFACTS = path
    return path


def reset_run_artifacts() -> None:
    global _RUN_ARTIFACTS
    _RUN_ARTIFACTS = None


def acquire_verification_lock() -> int:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    lock_path = ARTIFACTS / "run.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        try:
            os.lseek(descriptor, 0, os.SEEK_SET)
            owner = os.read(descriptor, 4096).decode(errors="replace").strip()
        finally:
            os.close(descriptor)
        detail = f" ({owner})" if owner else ""
        raise RuntimeError(f"another Fovea verification profile is already running{detail}") from error
    os.ftruncate(descriptor, 0)
    payload = (
        f"pid={os.getpid()}\n"
        f"startedAt={dt.datetime.now(dt.timezone.utc).isoformat()}\n"
    ).encode()
    os.write(descriptor, payload)
    os.fsync(descriptor)
    return descriptor


def release_verification_lock(descriptor: int) -> None:
    fcntl.flock(descriptor, fcntl.LOCK_UN)
    os.close(descriptor)


def atomic_write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_report_artifacts(report: dict[str, object]) -> None:
    artifact_directory = ROOT / str(report["artifactDirectory"])
    resolved_artifacts = artifact_directory.resolve()
    seen_logs: set[Path] = set()
    for item in report["phases"]:
        if not isinstance(item, dict):
            raise RuntimeError("verification report phase entry must be an object")
        log_path = (ROOT / str(item["log"])).resolve()
        try:
            log_path.relative_to(resolved_artifacts)
        except ValueError as error:
            raise RuntimeError("verification phase log escapes its run directory") from error
        if log_path in seen_logs:
            raise RuntimeError("verification report contains a duplicate phase log")
        seen_logs.add(log_path)
        if log_path.stat().st_size != int(item["logByteCount"]):
            raise RuntimeError(f"verification phase log byte count changed: {item['name']}")
        if file_sha256(log_path) != str(item["logSha256"]):
            raise RuntimeError(f"verification phase log digest changed: {item['name']}")


def command_output(command: list[str], *, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def working_tree_identity() -> str:
    with tempfile.TemporaryDirectory(prefix="fovea-verification-index-") as temporary:
        index = Path(temporary) / "index"
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(index)
        subprocess.run(
            ["git", "read-tree", "HEAD"],
            cwd=ROOT, env=env, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["git", "add", "-A", "--", "."],
            cwd=ROOT, env=env, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return command_output(["git", "write-tree"], env=env)


def source_state() -> SourceState:
    return SourceState(
        head_commit=command_output(["git", "rev-parse", "HEAD"]),
        working_tree=working_tree_identity(),
        dirty=bool(command_output(["git", "status", "--porcelain"])),
    )


def repository_relative(path: Path) -> Path:
    return path.resolve().relative_to(ROOT.resolve())


def candidate_baseline_path(value: str, *, require_existing: bool) -> Path:
    path = Path(value)
    if not path.is_absolute():
        path = ROOT / path
    resolved_parent = path.parent.resolve()
    try:
        resolved_parent.relative_to(ROOT.resolve())
    except ValueError as error:
        raise ValueError("candidate baseline must remain inside the repository") from error
    resolved = resolved_parent / path.name
    if require_existing:
        metadata = resolved.lstat()
        if resolved.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ValueError("candidate baseline must be a single-link regular file")
    elif resolved.exists() or resolved.is_symlink():
        metadata = resolved.lstat()
        if resolved.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ValueError("candidate baseline destination must be a single-link regular file")
    return resolved


def write_candidate_baseline(value: str, state: SourceState) -> Path:
    path = candidate_baseline_path(value, require_existing=False)
    relative = str(repository_relative(path))
    ignored = subprocess.run(
        ["git", "check-ignore", "-q", "--", relative],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if ignored.returncode != 0:
        raise ValueError("candidate baseline destination must be ignored by Git")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "headCommit": state.head_commit,
        "workingTree": state.working_tree,
        "dirty": state.dirty,
    }
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)
    return path


def load_candidate_baseline(value: str, *, current_head: str) -> tuple[Path, dict[str, object]]:
    path = candidate_baseline_path(value, require_existing=True)
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid candidate baseline: {error}") from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise ValueError("candidate baseline requires schemaVersion 1")
    head = str(payload.get("headCommit") or "")
    tree = str(payload.get("workingTree") or "")
    if head != current_head:
        raise ValueError("candidate baseline HEAD differs from the current repository HEAD")
    if re.fullmatch(r"[0-9a-f]{40,64}", tree) is None:
        raise ValueError("candidate baseline working-tree identity is malformed")
    probe = subprocess.run(
        ["git", "cat-file", "-e", f"{tree}^{{tree}}"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if probe.returncode != 0:
        raise ValueError("candidate baseline working-tree object is unavailable")
    return path, payload


def changed_files_between_trees(previous_tree: str, current_tree: str) -> list[str]:
    diff = subprocess.run(
        [
            "git", "diff", "--no-renames", "--name-only",
            "--diff-filter=ACMRDT", previous_tree, current_tree, "--",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if diff.returncode != 0:
        raise RuntimeError(diff.stderr.strip() or "unable to diff candidate baseline")
    return sorted({line for line in diff.stdout.splitlines() if line})


def changed_files(base: str | None) -> list[str]:
    dirty = bool(command_output(["git", "status", "--porcelain"]))
    if base is None:
        if dirty:
            base = "HEAD"
        else:
            parent = subprocess.run(
                ["git", "rev-parse", "HEAD^"], cwd=ROOT, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
            )
            base = parent.stdout.strip() if parent.returncode == 0 else "HEAD"
    paths: set[str] = set()
    diff = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "--diff-filter=ACMRDT", base, "--"],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if diff.returncode != 0:
        raise RuntimeError(diff.stderr.strip() or f"unable to diff verification base {base}")
    paths.update(line for line in diff.stdout.splitlines() if line)
    untracked = command_output(["git", "ls-files", "--others", "--exclude-standard"])
    paths.update(line for line in untracked.splitlines() if line)
    return sorted(paths)


def classify(paths: list[str]) -> dict[str, object]:
    categories: set[str] = set()
    unknown: list[str] = []
    test_filters: set[str] = set()
    model_scripts: set[str] = set()

    for path in paths:
        if not (ROOT / path).exists():
            categories.add("deleted")
        if path.startswith("Sources/"):
            categories.add("source")
        elif path.startswith("Tests/"):
            categories.add("tests")
            if path.endswith(".swift"):
                test_filters.add(Path(path).stem)
        elif path.startswith("Examples/FoveaWorkbenchApp/"):
            categories.add("workbench")
            if any(token in path for token in ("View", "Screen", "Style", "Assets.xcassets")):
                categories.add("visual")
        elif path.startswith("ConformanceKits/PersistentStoreProvider/"):
            categories.add("provider-conformance")
            categories.add("tooling")
        elif path.startswith("ConformanceKits/ImageCodec/"):
            categories.add("codec-conformance")
            categories.add("tooling")
        elif path == "ConformanceKits/_support.py":
            categories.add("provider-conformance")
            categories.add("codec-conformance")
            categories.add("tooling")
        elif path in {
            "ConformanceKits/current-contracts.json",
            "ConformanceKits/compatibility-matrix.json",
        }:
            categories.add("provider-conformance")
            categories.add("codec-conformance")
            categories.add("governance")
        elif path.startswith("Fixtures/QualifiedStoreProvider/"):
            categories.add("provider-conformance")
        elif path.startswith("Fixtures/ImageIOCodec/"):
            categories.add("codec-conformance")
        elif path.startswith("Benchmarks/CacheLab/"):
            categories.add("cache-lab")
        elif path.startswith("Benchmarks/"):
            categories.add("benchmark")
        elif path.startswith("Tools/"):
            categories.add("tooling")
            if path.startswith("Tools/Performance/") or "Lab/" in path:
                categories.add("benchmark")
        elif path.startswith("docs/") or path.endswith(".md"):
            categories.add("docs")
        elif path.startswith(".github/"):
            categories.add("governance")
        elif path in {"Package.swift", "Package.resolved"} or path.startswith(".swiftpm/"):
            categories.add("dependencies")
            categories.add("provider-conformance")
            categories.add("codec-conformance")
        elif path.startswith("scripts/"):
            categories.add("tooling")
            name = Path(path).name
            if name.startswith(("model-check-", "analyze-")) and name.endswith(".py"):
                model_scripts.add(path)
            known_prefixes = (
                "verify", "check-", "validate-", "run-", "test-", "capture-", "model-check-",
                "analyze-", "audit-", "render-", "generate-", "prepare-", "select-", "write-",
                "ios_example_", "lint-", "prove-",
            )
            if name in {
                "verify-ios-example.py",
                "audit-workbench-visuals.py",
                "ios_example_process.py",
                "ios_example_reporting.py",
                "ios_example_visual.py",
                "ios_example_xcode.py",
                "validate-ios-example-report.py",
            }:
                categories.add("workbench-tooling")
            if not name.startswith(known_prefixes):
                categories.add("unknown-tooling")
        elif path.startswith(("evidence/", ".swift-format", "CONTRIBUTING")):
            categories.add("governance")
        else:
            unknown.append(path)

    provider_seam_paths = (
        "Sources/FoveaAdvancedSystem/",
        "Sources/FoveaPersistence/FoveaPersistentStoreBundle.swift",
        "Sources/FoveaSystem/FoveaSystemPipeline.swift",
    )
    if any(
        path == provider_seam_paths[1]
        or path == provider_seam_paths[2]
        or path.startswith(provider_seam_paths[0])
        for path in paths
    ):
        categories.add("provider-conformance")

    codec_seam_paths = (
        "Sources/FoveaCore/DecodeStage.swift",
        "Sources/FoveaCore/FoveaPipeline.swift",
        "Sources/FoveaSystem/FoveaSystemPipeline.swift",
        "Tests/FoveaTests/ImageCodecConformanceTests.swift",
    )
    if any(path in codec_seam_paths for path in paths):
        categories.add("codec-conformance")

    network_tokens = ("HTTP", "Transport", "Network", "URLSession", "Redirect")
    storage_tokens = ("Storage", "Persistence", "Cache", "Manifest", "File", "Disk")
    if any(any(token in path for token in network_tokens) for path in paths):
        categories.add("network")
    if any(any(token in path for token in storage_tokens) for path in paths):
        categories.add("storage")
    if unknown:
        categories.add("unknown")

    return {
        "changedFiles": paths,
        "categories": sorted(categories),
        "unknownFiles": unknown,
        "testFilters": sorted(test_filters),
        "modelScripts": sorted(model_scripts),
    }



def iteration_test_filters(paths: list[str]) -> list[str]:
    """Map a narrow working-set change to executable test clusters.

    The iteration profile is intentionally fail-closed: source changes without a
    known mapping are escalated to the smart profile instead of being silently
    under-tested.
    """
    filters: set[str] = set()
    for path in paths:
        if path.startswith("Tests/") and path.endswith(".swift"):
            filters.add(Path(path).stem)
        if path.startswith("Sources/FoveaHTTP/") or any(
            token in path for token in ("URLSessionTransport", "RedirectPolicy", "HTTP")
        ):
            filters.update(("URLSessionTransportTests", "HTTP"))
        if path.startswith(("Sources/FoveaUIKit/", "Sources/FoveaSwiftUI/")):
            filters.update((
                "PlatformImageViewTests", "SwiftUIStateTests",
                "SwiftUIViewRenderingTests", "ProgressivePresentationHostTests",
            ))
        if path.startswith("Sources/FoveaCore/"):
            filters.update(("PipelineTests", "ProgressiveImageLoadingTests"))
            if any(token in path for token in ("ImageCraft", "Decode", "Codec", "PipelineFailure")):
                filters.update((
                    "ImageCodecContractTests", "ImageCodecConformanceTests",
                    "ImageDecoderTests", "PipelineFailureTests",
                ))
        if path.startswith(("Sources/FoveaPersistence/", "Sources/FoveaStorage/")):
            filters.update(("StagingAndStorageTests", "Persistent"))
        if path.startswith(("Sources/FoveaCache/", "Sources/FoveaMemory/")):
            filters.update(("Cache", "Memory"))
        if path.startswith("Sources/FoveaSystem/"):
            filters.update(("FoveaSystem", "PipelineTests"))
    explicit = os.environ.get("FOVEA_ITERATION_FILTER", "").strip()
    if explicit:
        filters.add(explicit)
    return sorted(filters)


def iteration_static_phases(impact: dict[str, object]) -> list[Phase]:
    categories = set(impact["categories"])
    paths = list(impact["changedFiles"])
    phases: list[Phase] = [
        Phase("sensitive-material", ("python3", "scripts/check-sensitive-material.py"), 120),
    ]
    if any(path.endswith(".swift") for path in paths):
        phases.append(Phase("swift-format", ("python3", "scripts/lint-fovea-swift-format.py"), 180))
    if categories & {"source", "tests", "benchmark"}:
        phases.append(Phase("architecture", ("python3", "scripts/check-architecture-boundaries.py"), 120))
    changed_python = [path for path in paths if path.endswith(".py") and (ROOT / path).is_file()]
    if changed_python:
        phases.append(Phase("python-syntax", ("python3", "-m", "py_compile", *changed_python), 120))
    if "docs" in categories:
        phases.append(Phase("docs", ("python3", "scripts/check-docs.py"), 180))
    if any(path.startswith("docs/project-memory/") for path in paths):
        phases.append(Phase("project-memory", ("python3", "scripts/check-project-memory.py"), 120))
    if "dependencies" in categories:
        phases.extend((
            Phase("component-pins", ("python3", "scripts/check-component-pins.py"), 120),
            Phase(
                "imagecraft-animation-pin-readiness",
                ("python3", "scripts/check-imagecraft-animation-pin-readiness.py"),
                120,
            ),
            Phase(
                "imagecraft-animation-pin-readiness-contract",
                ("python3", "scripts/test-imagecraft-animation-pin-readiness.py"),
                120,
            ),
            Phase("supply-chain", ("python3", "scripts/check-supply-chain.py"), 180),
        ))
    elif any(
        path in {
            "docs/project-memory/component-pins.json",
            "docs/research/w5-imagecraft-animation-adapter-qualification-2026-08.json",
            "scripts/check-imagecraft-animation-pin-readiness.py",
            "scripts/test-imagecraft-animation-pin-readiness.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "imagecraft-animation-pin-readiness",
                ("python3", "scripts/check-imagecraft-animation-pin-readiness.py"),
                120,
            )
        )
        phases.append(
            Phase(
                "imagecraft-animation-pin-readiness-contract",
                ("python3", "scripts/test-imagecraft-animation-pin-readiness.py"),
                120,
            )
        )
    if categories & {"provider-conformance", "codec-conformance"}:
        phases.append(Phase(
            "cross-repository-conformance-kits",
            ("python3", "scripts/check-cross-repository-conformance-kits.py"), 120,
        ))
    if any("test-traceability" in path or "current-required-ids" in path for path in paths):
        phases.append(Phase("traceability", ("python3", "scripts/check-test-traceability.py"), 180))
    if any(
        path in {
            "Benchmarks/ComparativeLab/animated-image-plan.json",
            "Benchmarks/ComparativeLab/animated-player-mechanism-plan.json",
            "Benchmarks/ComparativeLab/apng-checkpoint-plan.json",
            "Benchmarks/ComparativeLab/apng-tile-checkpoint-plan.json",
            "Benchmarks/ComparativeLab/apng-compressed-checkpoint-plan.json",
            "docs/research/animated-image-library-registry-2026-08.json",
            "docs/research/animated-image-mechanism-matrix-2026-08.json",
            "docs/research/animated-image-source-audit-2026-08.md",
            "docs/research/w5-imagecraft-animation-adapter-qualification-2026-08.json",
            "docs/research/w5-apng-semantic-replay-2026-08.json",
            "scripts/check-animated-image-library-registry.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "animated-image-library-registry",
                ("python3", "scripts/check-animated-image-library-registry.py"),
                120,
            )
        )
    if any("progressive-presentation" in path for path in paths):
        phases.append(Phase(
            "progressive-presentation-evidence",
            (
                "python3", "scripts/validate-progressive-presentation-evidence.py",
                "docs/research/progressive-presentation-simulator-evidence-2026-08.json",
            ), 180,
        ))
    if any(
        path.startswith(
            "Benchmarks/ComparativeLab/AnimatedCodecLabPackage/"
        )
        or path in {
            "Tools/Performance/capture_w5_animated_codec.py",
            "Tools/Performance/validate_w5_animated_codec.py",
            "Tools/Performance/test_w5_animated_codec_identity.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-animated-codec-identity-contract",
                ("python3", "Tools/Performance/test_w5_animated_codec_identity.py"),
                120,
            )
        )
    if any(
        path.startswith(
            "Benchmarks/ComparativeLab/APNGCompositionOracleLabPackage/"
        )
        or path in {
            "Tools/Performance/capture_w5_apng_composition_oracle.py",
            "Tools/Performance/validate_w5_apng_composition_oracle.py",
            "Tools/Performance/test_w5_apng_composition_oracle.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-apng-composition-oracle-contract",
                ("python3", "Tools/Performance/test_w5_apng_composition_oracle.py"),
                120,
            )
        )
    if any(
        path in {
            "Tools/Performance/w5_apng_reference.py",
            "Tools/Performance/capture_w5_apng_reference.py",
            "Tools/Performance/validate_w5_apng_reference.py",
            "Tools/Performance/test_w5_apng_reference.py",
            "Tools/Performance/test_w5_apng_reference_capture.py",
        }
        for path in paths
    ):
        phases.extend(
            [
                Phase(
                    "w5-apng-reference-core",
                    ("python3", "Tools/Performance/test_w5_apng_reference.py"),
                    120,
                ),
                Phase(
                    "w5-apng-reference-capture-contract",
                    (
                        "python3",
                        "Tools/Performance/test_w5_apng_reference_capture.py",
                    ),
                    120,
                ),
            ]
        )
    if any(
        path in {
            "Benchmarks/ComparativeLab/apng-checkpoint-plan.json",
            "Tools/Performance/w5_apng_checkpoint_model.py",
            "Tools/Performance/test_w5_apng_checkpoint_model.py",
            "Tools/Performance/capture_w5_apng_checkpoint_model.py",
            "Tools/Performance/validate_w5_apng_checkpoint_model.py",
            "Tools/Performance/test_w5_apng_checkpoint_capture.py",
        }
        for path in paths
    ):
        phases.extend(
            [
                Phase(
                    "w5-apng-checkpoint-model-core",
                    (
                        "python3",
                        "Tools/Performance/test_w5_apng_checkpoint_model.py",
                    ),
                    120,
                ),
                Phase(
                    "w5-apng-checkpoint-capture-contract",
                    (
                        "python3",
                        "Tools/Performance/test_w5_apng_checkpoint_capture.py",
                    ),
                    120,
                ),
            ]
        )
    if any(
        path in {
            "scripts/run-w5-animated-simulator-lab.py",
            "scripts/test-w5-animated-simulator-runner.py",
            "scripts/validate-w5-animated-timing.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-animated-simulator-runner-contract",
                ("python3", "scripts/test-w5-animated-simulator-runner.py"),
                120,
            )
        )
    if any(
        path in {
            "Sources/FoveaCore/AnimationPlaybackDriver.swift",
            "Sources/FoveaAppKit/FoveaAnimationDisplayLinkDriver.swift",
            "Sources/FoveaAppKit/FoveaAnimatedImageViewPresenter.swift",
            "Sources/FoveaAppKit/FoveaImageView.swift",
            "Tools/FoveaAnimationMacLab/FoveaAnimationMacLabMain.swift",
            "Tools/Performance/capture_w5_appkit_display_link.py",
            "Tools/Performance/test_w5_appkit_display_link_capture.py",
            "Tools/Performance/capture_w5_appkit_callback_timing.py",
            "Tools/Performance/test_w5_appkit_callback_timing_capture.py",
            "Tools/Performance/capture_w5_appkit_refresh_timing.py",
            "Tools/Performance/test_w5_appkit_refresh_timing_capture.py",
            "Tools/Performance/capture_w5_appkit_resource_proxy.py",
            "Tools/Performance/test_w5_appkit_resource_proxy_capture.py",
            "Tests/FoveaTests/AnimationPlaybackDriverTests.swift",
            "Tests/FoveaTests/AnimatedPlatformPresenterTests.swift",
            "Benchmarks/ComparativeLab/animated-player-mechanism-plan.json",
            "docs/research/w5-appkit-display-link-physical-2026-08.json",
            "docs/research/w5-appkit-refresh-timing-physical-2026-08.json",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-appkit-display-link-capture-contract",
                ("python3", "Tools/Performance/test_w5_appkit_display_link_capture.py"),
                120,
            )
        )
        phases.append(
            Phase(
                "w5-appkit-callback-timing-capture-contract",
                ("python3", "Tools/Performance/test_w5_appkit_callback_timing_capture.py"),
                120,
            )
        )
        phases.append(
            Phase(
                "w5-appkit-refresh-timing-capture-contract",
                ("python3", "Tools/Performance/test_w5_appkit_refresh_timing_capture.py"),
                120,
            )
        )
        phases.append(
            Phase(
                "w5-appkit-resource-proxy-capture-contract",
                ("python3", "Tools/Performance/test_w5_appkit_resource_proxy_capture.py"),
                120,
            )
        )
    if any(
        path in {
            "Benchmarks/ComparativeLab/apng-semantic-replay-plan.json",
            "Benchmarks/ComparativeLab/animated-player-mechanism-plan.json",
            "Tools/Performance/w5_apng_checkpoint_model.py",
            "Tools/Performance/test_w5_apng_checkpoint_model.py",
            "Tools/Performance/w5_yyimage_semantic_replay_oracle.py",
            "Tools/Performance/test_w5_yyimage_semantic_replay_oracle.py",
            "docs/research/w5-apng-semantic-replay-2026-08.json",
            "docs/research/animated-image-library-registry-2026-08.json",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-apng-semantic-replay-oracle",
                (
                    "python3",
                    "Tools/Performance/test_w5_yyimage_semantic_replay_oracle.py",
                ),
                120,
            )
        )
    if any(
        path in {
            "Benchmarks/ComparativeLab/apng-tile-checkpoint-plan.json",
            "Tools/Performance/w5_apng_tile_checkpoint_model.py",
            "Tools/Performance/test_w5_apng_tile_checkpoint_model.py",
            "Tools/Performance/capture_w5_apng_tile_checkpoint_model.py",
            "Tools/Performance/validate_w5_apng_tile_checkpoint_model.py",
            "Tools/Performance/test_w5_apng_tile_checkpoint_capture.py",
        }
        for path in paths
    ):
        phases.extend(
            [
                Phase(
                    "w5-apng-tile-checkpoint-model-core",
                    (
                        "python3",
                        "Tools/Performance/test_w5_apng_tile_checkpoint_model.py",
                    ),
                    120,
                ),
                Phase(
                    "w5-apng-tile-checkpoint-capture-contract",
                    (
                        "python3",
                        "Tools/Performance/test_w5_apng_tile_checkpoint_capture.py",
                    ),
                    120,
                ),
            ]
        )
    if any(
        path in {
            "Benchmarks/ComparativeLab/apng-compressed-checkpoint-plan.json",
            "Tools/Performance/w5_apng_compressed_checkpoint_model.py",
            "Tools/Performance/test_w5_apng_compressed_checkpoint_model.py",
            "Tools/Performance/capture_w5_apng_compressed_checkpoint_model.py",
            "Tools/Performance/validate_w5_apng_compressed_checkpoint_model.py",
            "Tools/Performance/test_w5_apng_compressed_checkpoint_capture.py",
        }
        for path in paths
    ):
        phases.extend(
            [
                Phase(
                    "w5-apng-compressed-checkpoint-model-core",
                    (
                        "python3",
                        "Tools/Performance/test_w5_apng_compressed_checkpoint_model.py",
                    ),
                    120,
                ),
                Phase(
                    "w5-apng-compressed-checkpoint-capture-contract",
                    (
                        "python3",
                        "Tools/Performance/test_w5_apng_compressed_checkpoint_capture.py",
                    ),
                    120,
                ),
            ]
        )
    if any(
        path in {
            "Tools/Performance/capture_w5_apng_compressed_checkpoint_interop.py",
            "Tools/Performance/validate_w5_apng_compressed_checkpoint_interop.py",
            "Tools/Performance/test_w5_apng_compressed_checkpoint_interop.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-apng-compressed-checkpoint-interop-contract",
                (
                    "python3",
                    "Tools/Performance/test_w5_apng_compressed_checkpoint_interop.py",
                ),
                180,
            )
        )
    if any(
        path in {
            "Tools/Performance/capture_w5_apng_owned_swift_playback.py",
            "Tools/Performance/validate_w5_apng_owned_swift_playback.py",
            "Tools/Performance/test_w5_apng_owned_swift_playback.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-apng-owned-swift-playback-contract",
                (
                    "python3",
                    "Tools/Performance/test_w5_apng_owned_swift_playback.py",
                ),
                180,
            )
        )
    if any(
        path in {
            "Tools/Performance/capture_w5_apng_public_decoder_playback.py",
            "Tools/Performance/validate_w5_apng_public_decoder_playback.py",
            "Tools/Performance/test_w5_apng_public_decoder_playback.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-apng-public-decoder-playback-contract",
                (
                    "python3",
                    "Tools/Performance/test_w5_apng_public_decoder_playback.py",
                ),
                180,
            )
        )
    if any(
        path in {
            "Tools/Performance/capture_w5_apng_public_decoder_mac_performance.py",
            "Tools/Performance/validate_w5_apng_public_decoder_mac_performance.py",
            "Tools/Performance/test_w5_apng_public_decoder_mac_performance.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-apng-public-decoder-mac-performance-contract",
                (
                    "python3",
                    "Tools/Performance/test_w5_apng_public_decoder_mac_performance.py",
                ),
                180,
            )
        )
    if any(
        path in {
            "Tools/Performance/capture_w5_apng_imageio_cache_divergence.py",
            "Tools/Performance/validate_w5_apng_imageio_cache_divergence.py",
            "Tools/Performance/test_w5_apng_imageio_cache_divergence.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-apng-imageio-cache-divergence-contract",
                (
                    "python3",
                    "Tools/Performance/test_w5_apng_imageio_cache_divergence.py",
                ),
                180,
            )
        )
    if any(
        path.startswith("Sources/FoveaUIKit/")
        or path in {
            "docs/public-api-budget.json",
            "scripts/check-foveauikit-api-budget.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "foveauikit-api-budget",
                ("python3", "scripts/check-foveauikit-api-budget.py"),
                120,
            )
        )
    if any(
        path.startswith("Tools/AnimationAdapterQualification/")
        or path in {
            "Sources/FoveaCore/PipelineFailure+ImageCraft.swift",
            "Benchmarks/ComparativeLab/animated-player-mechanism-plan.json",
            "docs/research/w5-imagecraft-animation-adapter-qualification-2026-08.json",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "w5-imagecraft-animation-adapter-contract",
                (
                    "python3",
                    "Tools/AnimationAdapterQualification/test_imagecraft_animation_adapter_qualification.py",
                ),
                120,
            )
        )
    if any(
        path in {
            "scripts/check-tooling-syntax.py",
            "scripts/run-verification-profile.py",
        }
        for path in paths
    ):
        phases.extend(
            [
                Phase(
                    "tooling-contract",
                    ("python3", "scripts/check-tooling-syntax.py", "--quick"),
                    120,
                ),
                Phase(
                    "candidate-baseline-contract",
                    ("python3", "scripts/test-verification-candidate-baseline.py"),
                    120,
                ),
            ]
        )
    if any(
        path in {
            "scripts/component_candidate_sandbox.py",
            "scripts/test-component-candidate-sandbox.py",
            "scripts/verify-component-candidate-clean-copy.py",
            "scripts/run-verification-profile.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "component-candidate-sandbox-contract",
                ("python3", "scripts/test-component-candidate-sandbox.py"),
                120,
            )
        )
    unique: dict[str, Phase] = {}
    for phase in phases:
        unique.setdefault(phase.name, phase)
    return list(unique.values())

def static_phases(include_docs: bool) -> list[Phase]:
    phases = [
        Phase("toolchain", ("python3", "scripts/check-swift-toolchain.py"), 120),
        Phase("project-memory", ("python3", "scripts/check-project-memory.py"), 120),
        Phase("workload-registry", ("python3", "scripts/check-workload-registry.py"), 120),
        Phase("actions-governance", ("python3", "scripts/check-actions-budget-governance.py"), 120),
        Phase("architecture", ("python3", "scripts/check-architecture-boundaries.py"), 120),
        Phase("component-pins", ("python3", "scripts/check-component-pins.py"), 120),
        Phase(
            "imagecraft-animation-pin-readiness",
            ("python3", "scripts/check-imagecraft-animation-pin-readiness.py"),
            120,
        ),
        Phase(
            "imagecraft-animation-pin-readiness-contract",
            ("python3", "scripts/test-imagecraft-animation-pin-readiness.py"),
            120,
        ),
        Phase(
            "cross-repository-conformance-kits",
            ("python3", "scripts/check-cross-repository-conformance-kits.py"),
            120,
        ),
        Phase("traceability", ("python3", "scripts/check-test-traceability.py"), 180),
        Phase(
            "progressive-presentation-evidence",
            (
                "python3",
                "scripts/validate-progressive-presentation-evidence.py",
                "docs/research/progressive-presentation-simulator-evidence-2026-08.json",
            ),
            180,
        ),
        Phase("tooling-contract", ("python3", "scripts/check-tooling-syntax.py"), 240),
        Phase(
            "animated-image-library-registry",
            ("python3", "scripts/check-animated-image-library-registry.py"),
            120,
        ),
        Phase(
            "w5-animated-codec-identity-contract",
            ("python3", "Tools/Performance/test_w5_animated_codec_identity.py"),
            120,
        ),
        Phase(
            "w5-apng-composition-oracle-contract",
            ("python3", "Tools/Performance/test_w5_apng_composition_oracle.py"),
            120,
        ),
        Phase(
            "w5-apng-reference-core",
            ("python3", "Tools/Performance/test_w5_apng_reference.py"),
            120,
        ),
        Phase(
            "w5-apng-reference-capture-contract",
            ("python3", "Tools/Performance/test_w5_apng_reference_capture.py"),
            120,
        ),
        Phase(
            "w5-apng-checkpoint-model-core",
            ("python3", "Tools/Performance/test_w5_apng_checkpoint_model.py"),
            120,
        ),
        Phase(
            "w5-apng-checkpoint-capture-contract",
            ("python3", "Tools/Performance/test_w5_apng_checkpoint_capture.py"),
            120,
        ),
        Phase(
            "w5-animated-simulator-runner-contract",
            ("python3", "scripts/test-w5-animated-simulator-runner.py"),
            120,
        ),
        Phase(
            "w5-appkit-display-link-capture-contract",
            ("python3", "Tools/Performance/test_w5_appkit_display_link_capture.py"),
            120,
        ),
        Phase(
            "w5-appkit-callback-timing-capture-contract",
            ("python3", "Tools/Performance/test_w5_appkit_callback_timing_capture.py"),
            120,
        ),
        Phase(
            "w5-appkit-refresh-timing-capture-contract",
            ("python3", "Tools/Performance/test_w5_appkit_refresh_timing_capture.py"),
            120,
        ),
        Phase(
            "w5-appkit-resource-proxy-capture-contract",
            ("python3", "Tools/Performance/test_w5_appkit_resource_proxy_capture.py"),
            120,
        ),
        Phase(
            "w5-apng-semantic-replay-oracle",
            (
                "python3",
                "Tools/Performance/test_w5_yyimage_semantic_replay_oracle.py",
            ),
            120,
        ),
        Phase(
            "w5-apng-tile-checkpoint-model-core",
            ("python3", "Tools/Performance/test_w5_apng_tile_checkpoint_model.py"),
            120,
        ),
        Phase(
            "w5-apng-tile-checkpoint-capture-contract",
            ("python3", "Tools/Performance/test_w5_apng_tile_checkpoint_capture.py"),
            120,
        ),
        Phase(
            "w5-apng-compressed-checkpoint-model-core",
            ("python3", "Tools/Performance/test_w5_apng_compressed_checkpoint_model.py"),
            120,
        ),
        Phase(
            "w5-apng-compressed-checkpoint-capture-contract",
            ("python3", "Tools/Performance/test_w5_apng_compressed_checkpoint_capture.py"),
            120,
        ),
        Phase(
            "w5-apng-compressed-checkpoint-interop-contract",
            ("python3", "Tools/Performance/test_w5_apng_compressed_checkpoint_interop.py"),
            180,
        ),
        Phase(
            "w5-apng-owned-swift-playback-contract",
            ("python3", "Tools/Performance/test_w5_apng_owned_swift_playback.py"),
            180,
        ),
        Phase(
            "w5-apng-public-decoder-playback-contract",
            ("python3", "Tools/Performance/test_w5_apng_public_decoder_playback.py"),
            180,
        ),
        Phase(
            "w5-apng-public-decoder-mac-performance-contract",
            (
                "python3",
                "Tools/Performance/test_w5_apng_public_decoder_mac_performance.py",
            ),
            180,
        ),
        Phase(
            "w5-apng-imageio-cache-divergence-contract",
            (
                "python3",
                "Tools/Performance/test_w5_apng_imageio_cache_divergence.py",
            ),
            180,
        ),
        Phase(
            "foveauikit-api-budget",
            ("python3", "scripts/check-foveauikit-api-budget.py"),
            120,
        ),
        Phase(
            "w5-imagecraft-animation-adapter-contract",
            (
                "python3",
                "Tools/AnimationAdapterQualification/test_imagecraft_animation_adapter_qualification.py",
            ),
            120,
        ),
        Phase(
            "candidate-baseline-contract",
            ("python3", "scripts/test-verification-candidate-baseline.py"),
            120,
        ),
        Phase(
            "component-candidate-sandbox-contract",
            ("python3", "scripts/test-component-candidate-sandbox.py"),
            120,
        ),
        Phase("sensitive-material", ("python3", "scripts/check-sensitive-material.py"), 120),
        Phase("supply-chain", ("python3", "scripts/check-supply-chain.py"), 180),
        Phase("swift-format", ("python3", "scripts/lint-fovea-swift-format.py"), 180),
    ]
    if include_docs:
        phases.extend(
            [
                Phase("docs", ("python3", "scripts/check-docs.py"), 180),
                Phase("engineering-knowledge", ("python3", "scripts/check-engineering-knowledge.py"), 180),
                Phase("reference-provenance", ("python3", "scripts/check-reference-provenance.py"), 120),
            ]
        )
    return phases


def run_phase(phase: Phase, env: dict[str, str]) -> PhaseResult:
    artifacts = active_artifacts()
    artifacts.mkdir(parents=True, exist_ok=True)
    log_path = artifacts / f"{phase.name}.log"
    started = time.monotonic()
    process: subprocess.Popen[str] | None = None
    spawn_error: OSError | None = None
    for attempt in range(2):
        try:
            process = subprocess.Popen(
                list(phase.command), cwd=ROOT, env=env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            break
        except OSError as error:
            spawn_error = error
            if attempt == 0 and error.errno in {errno.EPERM, errno.EAGAIN}:
                time.sleep(0.25)
                continue
            break
    if process is None:
        elapsed = time.monotonic() - started
        message = f"phase process creation failed: {spawn_error}\n"
        log_path.write_text(message)
        print(f"[failed] {phase.name} ({elapsed:.1f}s)")
        print(message.rstrip(), file=sys.stderr)
        return PhaseResult(
            phase.name, list(phase.command), 126, elapsed, str(log_path.relative_to(ROOT))
        )
    register_process_group(process.pid)
    try:
        try:
            output, _ = process.communicate(timeout=phase.timeout)
            return_code = process.returncode
        except subprocess.TimeoutExpired as error:
            terminate_process_group(process.pid)
            trailing, _ = process.communicate()
            output = (error.output or "") + (trailing or "")
            output += f"\nphase timed out after {phase.timeout} seconds\n"
            return_code = 124
    finally:
        unregister_process_group(process.pid)
    elapsed = time.monotonic() - started
    log_path.write_text(output)
    status = "passed" if return_code == 0 else "failed"
    print(f"[{status}] {phase.name} ({elapsed:.1f}s)")
    if output and return_code != 0:
        print("\n".join(output.splitlines()[-80:]), file=sys.stderr)
    return PhaseResult(phase.name, list(phase.command), return_code, elapsed, str(log_path.relative_to(ROOT)))


def run_parallel(phases: Iterable[Phase], env: dict[str, str]) -> list[PhaseResult]:
    phase_list = list(phases)
    workers = min(4, max(1, len(phase_list)))
    results: list[PhaseResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(run_phase, phase, env): phase for phase in phase_list}
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
    return sorted(results, key=lambda item: item.name)


def phase_plan(profile: str, impact: dict[str, object]) -> tuple[str, list[Phase], list[str]]:
    categories = set(impact["categories"])
    reasons: list[str] = []
    effective = profile
    iteration_requires_smart = (
        categories & {"unknown", "unknown-tooling", "deleted", "dependencies", "governance"}
        or any(
            path.startswith(("ConformanceKits/", "Fixtures/"))
            for path in impact["changedFiles"]
        )
    )
    if effective == "iteration" and iteration_requires_smart:
        effective = "smart"
        reasons.append("iteration change requires broader smart verification")
    if effective == "smart" and ("unknown" in categories or "unknown-tooling" in categories):
        effective = "premerge"
        reasons.append("unknown change path escalated to premerge")
    if effective == "smart" and "deleted" in categories:
        effective = "premerge"
        reasons.append("deleted path escalated to premerge")

    phases: list[Phase] = []
    include_docs = effective != "smart" or "docs" in categories or "governance" in categories
    if effective in {"premerge", "release"}:
        phases.append(
            Phase(
                "verification-capacity",
                ("python3", "scripts/check-verification-capacity.py"),
                60,
            )
        )
    if effective == "iteration":
        phases.extend(iteration_static_phases(impact))
    else:
        phases.extend(static_phases(include_docs))

    if "dependencies" in categories or effective in {"premerge", "release"}:
        phases.append(Phase("package-resolve", ("xcrun", "swift", "package", "resolve"), 600))

    if effective == "iteration":
        filters = iteration_test_filters(list(impact["changedFiles"]))
        if "source" in categories and not filters:
            effective = "smart"
            reasons.append("unmapped source change escalated from iteration to smart")
            return phase_plan(effective, impact)
        if filters:
            expression = "|".join(re.escape(item) for item in filters)
            phases.append(Phase(
                "impacted-tests",
                ("xcrun", "swift", "test", "--filter", expression),
                900,
            ))
        if "benchmark" in categories:
            phases.append(Phase(
                "comparative-core-tests",
                ("xcrun", "swift", "test", "--package-path", "Benchmarks/ComparativeLab"),
                600,
            ))
        if "cache-lab" in categories:
            phases.append(Phase(
                "cache-lab",
                ("xcrun", "swift", "test", "--package-path", "Benchmarks/CacheLab"),
                900,
            ))
    elif effective == "smart":
        filters = list(impact["testFilters"])
        if "source" in categories or "dependencies" in categories:
            phases.append(Phase("root-tests", ("python3", "scripts/run-swift-strict.py", "test"), 1800))
        elif filters:
            expression = "|".join(re.escape(item) for item in filters)
            phases.append(Phase("impacted-tests", ("xcrun", "swift", "test", "--filter", expression), 900))
        if "cache-lab" in categories or "benchmark" in categories:
            phases.append(Phase("cache-lab", ("xcrun", "swift", "test", "--package-path", "Benchmarks/CacheLab"), 900))
        if "network" in categories:
            phases.extend(
                [
                    Phase("http-conformance", ("python3", "scripts/run-http-conformance.py"), 600),
                    Phase("loopback-network", ("python3", "scripts/run-loopback-network-lab.py"), 900),
                ]
            )
        if "storage" in categories:
            phases.append(Phase("metadata-sanitizer", ("python3", "scripts/test-image-metadata.py"), 300))
        for script in impact["modelScripts"]:
            phases.append(Phase(f"model-{Path(script).stem}", ("python3", script), 600))
        if "workbench" in categories:
            phases.append(
                Phase(
                    "workbench-unit",
                    (
                        "python3", "scripts/verify-ios-example.py", "--skip-ui",
                        "--skip-visual", "--skip-live-network", "--skip-release-build",
                    ),
                    900,
                )
            )
    elif effective == "premerge":
        phases.extend(
            [
                Phase("cache-lab", ("xcrun", "swift", "test", "--package-path", "Benchmarks/CacheLab"), 900),
                Phase("root-tests", ("python3", "scripts/run-swift-strict.py", "test"), 2400),
                Phase("loopback-network", ("python3", "scripts/run-loopback-network-lab.py"), 900),
            ]
        )
        if categories & {"source", "dependencies"}:
            phases.append(Phase("release-build", ("python3", "scripts/run-swift-strict.py", "build", "-c", "release"), 1800))
        if categories & {"workbench", "workbench-tooling"}:
            phases.append(
                Phase(
                    "workbench-smoke",
                    (
                        "python3", "scripts/verify-ios-example.py", "--ui-smoke",
                        "--skip-visual", "--skip-live-network",
                        "--reuse-release-derived-data",
                    ),
                    1500,
                )
            )
    elif effective == "release":
        phases.extend(
            [
                Phase("qualification-certificate", ("python3", "scripts/check-qualification-certificate.py"), 120),
                Phase("cache-lab", ("xcrun", "swift", "test", "--package-path", "Benchmarks/CacheLab"), 900),
                Phase("root-tests", ("python3", "scripts/run-swift-strict.py", "test"), 2400),
                Phase("loopback-network", ("python3", "scripts/run-loopback-network-lab.py"), 900),
                Phase("production-coverage", ("python3", "scripts/run-production-coverage.py"), 1800),
                Phase("release-build", ("python3", "scripts/run-swift-strict.py", "build", "-c", "release"), 1800),
                Phase(
                    "workbench-build-unit",
                    ("python3", "scripts/verify-ios-example.py", "--skip-ui", "--skip-visual", "--skip-live-network"),
                    1500,
                ),
            ]
        )
    elif effective == "workbench-smoke":
        phases.append(
            Phase(
                "workbench-smoke",
                (
                    "python3", "scripts/verify-ios-example.py", "--ui-smoke",
                    "--skip-visual", "--skip-live-network",
                    "--skip-release-build", "--reuse-release-derived-data",
                ),
                1500,
            )
        )
    else:
        raise ValueError(f"unsupported profile: {effective}")

    if effective != "iteration" and "provider-conformance" in categories:
        phases.append(
            Phase(
                "persistent-store-provider-conformance",
                (
                    "python3",
                    "ConformanceKits/PersistentStoreProvider/v1/run.py",
                    "--provider-package-path",
                    "Fixtures/QualifiedStoreProvider",
                    "--provider-product",
                    "QualifiedStoreProviderFixture",
                    "--factory-source",
                    "Fixtures/QualifiedStoreProvider/ConformanceFactory.swift",
                    "--timeout",
                    "900",
                ),
                1_200,
            )
        )
    if effective != "iteration" and "codec-conformance" in categories:
        phases.append(
            Phase(
                "image-codec-conformance",
                (
                    "python3",
                    "ConformanceKits/ImageCodec/v1/run.py",
                    "--codec-package-path",
                    "Fixtures/ImageIOCodec",
                    "--codec-product",
                    "ImageIOCodecFixture",
                    "--factory-source",
                    "Fixtures/ImageIOCodec/ConformanceFactory.swift",
                    "--timeout",
                    "900",
                ),
                1_200,
            )
        )

    deduplicated: dict[str, Phase] = {}
    for phase in phases:
        deduplicated.setdefault(phase.name, phase)
    return effective, list(deduplicated.values()), reasons


def write_report(
    requested: str,
    effective: str,
    verification_base: str | None,
    impact: dict[str, object],
    reasons: list[str],
    results: list[PhaseResult],
    started: float,
    source_before: SourceState,
    source_after: SourceState,
    candidate_baseline: dict[str, object] | None = None,
) -> Path:
    artifacts = active_artifacts()
    artifacts.mkdir(parents=True, exist_ok=True)
    source_unchanged = source_before == source_after
    phases_passed = all(item.return_code == 0 for item in results)
    run_id = artifacts.name if _RUN_ARTIFACTS is not None else None
    report = {
        "schemaVersion": 3,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "runID": run_id,
        "artifactDirectory": str(artifacts.relative_to(ROOT)),
        "requestedProfile": requested,
        "effectiveProfile": effective,
        "verificationBase": verification_base,
        "candidateBaseline": candidate_baseline,
        "headCommit": source_after.head_commit,
        "verifiedTree": source_after.working_tree,
        "dirty": source_after.dirty,
        "sourceUnchangedDuringRun": source_unchanged,
        "status": "passed" if phases_passed and source_unchanged else "failed",
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "impact": impact,
        "escalationReasons": reasons,
        "phases": [
            {
                "name": item.name,
                "command": item.command,
                "returnCode": item.return_code,
                "elapsedSeconds": round(item.elapsed_seconds, 3),
                "log": item.log,
                "logByteCount": (ROOT / item.log).stat().st_size,
                "logSha256": file_sha256(ROOT / item.log),
            }
            for item in results
        ],
    }
    validate_report_artifacts(report)
    path = artifacts / ("report.json" if _RUN_ARTIFACTS is not None else "latest.json")
    atomic_write_json(path, report)
    if json.loads(path.read_text()) != report:
        raise RuntimeError("verification run report failed its write-back check")
    if _RUN_ARTIFACTS is not None:
        latest = ARTIFACTS / "latest.json"
        atomic_write_json(latest, report)
        if latest.read_bytes() != path.read_bytes():
            raise RuntimeError("latest verification report differs from its run report")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a bounded Fovea verification profile.")
    parser.add_argument("--profile", choices=PROFILE_CHOICES, default="smart")
    parser.add_argument("--base", default=os.environ.get("FOVEA_VERIFY_BASE") or os.environ.get("FOVEA_BASE_COMMIT"))
    parser.add_argument(
        "--candidate-baseline",
        default=os.environ.get("FOVEA_VERIFY_CANDIDATE_BASELINE"),
        help="compute impact from a captured working-tree identity instead of HEAD",
    )
    parser.add_argument(
        "--capture-candidate-baseline",
        help="write the current HEAD and working-tree identity, then exit",
    )
    parser.add_argument("--plan", action="store_true", help="print the impact plan without executing phases")
    args = parser.parse_args()

    started = time.monotonic()
    install_signal_handlers()
    lock_descriptor: int | None = None
    try:
        if args.capture_candidate_baseline:
            source = source_state()
            path = write_candidate_baseline(args.capture_candidate_baseline, source)
            print(f"Captured Fovea candidate baseline: {repository_relative(path)}")
            return 0
        lock_descriptor = acquire_verification_lock()
        run_artifacts = create_run_artifacts()
        source_before = source_state()
        baseline_record: dict[str, object] | None = None
        if args.candidate_baseline:
            baseline_path, baseline_payload = load_candidate_baseline(
                args.candidate_baseline,
                current_head=source_before.head_commit,
            )
            baseline_record = {
                "path": str(repository_relative(baseline_path)),
                "headCommit": baseline_payload["headCommit"],
                "workingTree": baseline_payload["workingTree"],
            }
            paths = changed_files_between_trees(
                str(baseline_payload["workingTree"]),
                source_before.working_tree,
            )
        else:
            paths = changed_files(args.base)
        impact = classify(paths)
        effective, phases, reasons = phase_plan(args.profile, impact)
        atomic_write_json(run_artifacts / "impact.json", impact)
        atomic_write_json(ARTIFACTS / "impact.json", impact)
        print(f"Fovea verification run: {run_artifacts.name}")
        print(f"Fovea verification profile: requested={args.profile} effective={effective}")
        print(f"Changed files: {len(paths)}; categories={','.join(impact['categories']) or 'none'}")
        if reasons:
            print("Escalation: " + "; ".join(reasons))
        for phase in phases:
            print(f"  - {phase.name}: {shlex.join(phase.command)}")
        if args.plan:
            return 0

        env = os.environ.copy()
        env["DEVELOPER_DIR"] = command_output([str(ROOT / "scripts/select-xcode.sh")])
        static_names = {phase.name for phase in static_phases(include_docs=True)}
        static_names.update({
            "python-syntax", "comparative-core-tests",
            "progressive-presentation-evidence",
        })
        preflight = [phase for phase in phases if phase.name == "verification-capacity"]
        parallel = [
            phase for phase in phases
            if phase.name in static_names and phase.name != "verification-capacity"
        ]
        sequential = [
            phase for phase in phases
            if phase.name not in static_names and phase.name != "verification-capacity"
        ]
        results: list[PhaseResult] = []
        for phase in preflight:
            result = run_phase(phase, env)
            results.append(result)
            if result.return_code != 0:
                source_after = source_state()
                report = write_report(
                    args.profile, effective, args.base, impact, reasons, results, started,
                    source_before, source_after, baseline_record,
                )
                print(f"Verification failed: {report.relative_to(ROOT)}", file=sys.stderr)
                return 1
        results.extend(run_parallel(parallel, env))
        if any(item.return_code != 0 for item in results):
            source_after = source_state()
            report = write_report(
                args.profile, effective, args.base, impact, reasons, results, started,
                source_before, source_after, baseline_record,
            )
            print(f"Verification failed: {report.relative_to(ROOT)}", file=sys.stderr)
            return 1
        for phase in sequential:
            result = run_phase(phase, env)
            results.append(result)
            if result.return_code != 0:
                break
        source_after = source_state()
        report = write_report(
            args.profile, effective, args.base, impact, reasons, results, started,
            source_before, source_after, baseline_record,
        )
        if any(item.return_code != 0 for item in results) or source_after != source_before:
            print(f"Verification failed: {report.relative_to(ROOT)}", file=sys.stderr)
            return 1
        print(
            f"Fovea {effective} verification passed in {time.monotonic() - started:.1f}s: "
            f"{report.relative_to(ROOT)}"
        )
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"Verification planning failed: {error}", file=sys.stderr)
        return 1
    finally:
        reset_run_artifacts()
        if lock_descriptor is not None:
            release_verification_lock(lock_descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
