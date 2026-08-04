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
import json
import os
import re
import signal
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
                "verify", "check-", "validate-", "run-", "test-", "model-check-",
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
            Phase("supply-chain", ("python3", "scripts/check-supply-chain.py"), 180),
        ))
    if categories & {"provider-conformance", "codec-conformance"}:
        phases.append(Phase(
            "cross-repository-conformance-kits",
            ("python3", "scripts/check-cross-repository-conformance-kits.py"), 120,
        ))
    if any("test-traceability" in path or "current-required-ids" in path for path in paths):
        phases.append(Phase("traceability", ("python3", "scripts/check-test-traceability.py"), 180))
    if any("progressive-presentation" in path for path in paths):
        phases.append(Phase(
            "progressive-presentation-evidence",
            (
                "python3", "scripts/validate-progressive-presentation-evidence.py",
                "docs/research/progressive-presentation-simulator-evidence-2026-08.json",
            ), 180,
        ))
    if any(
        path in {
            "scripts/check-tooling-syntax.py",
            "scripts/run-verification-profile.py",
        }
        for path in paths
    ):
        phases.append(
            Phase(
                "tooling-contract",
                ("python3", "scripts/check-tooling-syntax.py", "--quick"),
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
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    log_path = ARTIFACTS / f"{phase.name}.log"
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
    if profile == "iteration" and iteration_requires_smart:
        effective = "smart"
        reasons.append("iteration change requires broader smart verification")
    if profile == "smart" and ("unknown" in categories or "unknown-tooling" in categories):
        effective = "premerge"
        reasons.append("unknown change path escalated to premerge")
    if profile == "smart" and "deleted" in categories:
        effective = "premerge"
        reasons.append("deleted path escalated to premerge")

    phases: list[Phase] = []
    include_docs = effective != "smart" or "docs" in categories or "governance" in categories
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
) -> Path:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    source_unchanged = source_before == source_after
    phases_passed = all(item.return_code == 0 for item in results)
    report = {
        "schemaVersion": 2,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "requestedProfile": requested,
        "effectiveProfile": effective,
        "verificationBase": verification_base,
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
            }
            for item in results
        ],
    }
    path = ARTIFACTS / "latest.json"
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a bounded Fovea verification profile.")
    parser.add_argument("--profile", choices=PROFILE_CHOICES, default="smart")
    parser.add_argument("--base", default=os.environ.get("FOVEA_VERIFY_BASE") or os.environ.get("FOVEA_BASE_COMMIT"))
    parser.add_argument("--plan", action="store_true", help="print the impact plan without executing phases")
    args = parser.parse_args()

    started = time.monotonic()
    install_signal_handlers()
    try:
        source_before = source_state()
        paths = changed_files(args.base)
        impact = classify(paths)
        effective, phases, reasons = phase_plan(args.profile, impact)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (ARTIFACTS / "impact.json").write_text(json.dumps(impact, indent=2, sort_keys=True) + "\n")
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
        parallel = [phase for phase in phases if phase.name in static_names]
        sequential = [phase for phase in phases if phase.name not in static_names]
        results = run_parallel(parallel, env)
        if any(item.return_code != 0 for item in results):
            source_after = source_state()
            report = write_report(
                args.profile, effective, args.base, impact, reasons, results, started,
                source_before, source_after,
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
            source_before, source_after,
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


if __name__ == "__main__":
    raise SystemExit(main())
