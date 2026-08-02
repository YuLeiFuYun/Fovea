#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from cache_lab_host_monitor import (
    POLICY_ID,
    POLICY_SCHEMA_VERSION,
    aggregate_monitors,
    compiler_processes,
    run_monitored,
    summarized_processes,
    wait_for_quiescence,
)

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Benchmarks/CacheLab"
ARTIFACT_ROOT = ROOT / ".artifacts/cache-lab"


def run(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: int = 1200,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        print(result.stdout[-30000:], file=sys.stderr)
        raise SystemExit(result.returncode)
    return result


def environment() -> dict[str, str]:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = run(
            [str(ROOT / "scripts/select-xcode.sh")], timeout=120
        ).stdout.strip()
    return env


def git_identity(repository: Path, *, dependency_mode: str) -> dict[str, Any]:
    repository = repository.resolve()
    head = run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"], timeout=120
    ).stdout.strip()
    status = run(
        ["git", "-C", str(repository), "status", "--porcelain=v1", "-z"],
        timeout=120,
    ).stdout
    digest = hashlib.sha256()
    digest.update(b"cache-lab-source-tree-v2\0")
    digest.update(head.encode())
    digest.update(
        subprocess.run(
            ["git", "diff", "--binary", "HEAD"],
            cwd=repository,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
    )
    untracked = run(
        [
            "git",
            "-C",
            str(repository),
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
        ],
        timeout=120,
    ).stdout.split("\0")
    for relative in sorted(value for value in untracked if value):
        path = repository / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    return {
        "commit": head,
        "sourceTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": bool(status),
        "dependencyMode": dependency_mode,
    }


def akashic_identity() -> dict[str, Any]:
    workspace_state = PACKAGE / ".build/workspace-state.json"
    state = json.loads(workspace_state.read_text())
    dependencies = state.get("object", {}).get("dependencies", [])
    dependency = next(
        (
            item
            for item in dependencies
            if item.get("packageRef", {}).get("identity", "").lower() == "akashic"
        ),
        None,
    )
    if dependency is None:
        raise SystemExit("Cache Lab workspace does not resolve Akashic")
    resolution = dependency.get("state", {})
    mode = resolution.get("name")
    if mode == "edited":
        repository = Path(resolution["path"])
        dependency_mode = "edited"
    elif mode == "sourceControlCheckout":
        repository = PACKAGE / ".build/checkouts" / dependency["subpath"]
        dependency_mode = "source-control-checkout"
    else:
        raise SystemExit(f"unsupported Akashic dependency mode: {mode!r}")
    identity = git_identity(repository, dependency_mode=dependency_mode)
    based_on = dependency.get("basedOn") or dependency
    checkout = based_on.get("state", {}).get("checkoutState", {})
    revision = checkout.get("revision")
    if isinstance(revision, str):
        identity["declaredRevision"] = revision
    return identity


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def atomic_json_write(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def build_runner(env: dict[str, str], stem: str) -> Path:
    build = run(
        [
            "xcrun",
            "swift",
            "build",
            "--package-path",
            str(PACKAGE),
            "-c",
            "release",
            "--product",
            "CacheLabRunner",
        ],
        env=env,
        timeout=1800,
    )
    (ARTIFACT_ROOT / f"{stem}-build.log").write_text(build.stdout)
    binary_directory = run(
        [
            "xcrun",
            "swift",
            "build",
            "--package-path",
            str(PACKAGE),
            "-c",
            "release",
            "--show-bin-path",
        ],
        env=env,
        timeout=300,
    ).stdout.strip()
    runner = Path(binary_directory) / "CacheLabRunner"
    if not runner.is_file():
        raise SystemExit(f"CacheLabRunner was not produced at {runner}")
    return runner


def calibration_preflight() -> dict[str, Any]:
    external = compiler_processes()
    return {
        "requiredCleanSamples": 0,
        "observedConsecutiveCleanSamples": 1 if not external else 0,
        "observedSamples": 1,
        "sampleIntervalMilliseconds": 1000,
        "timeoutSeconds": 0,
        "passed": not external,
        "externalProcesses": summarized_processes(external),
    }


def common_environment(env: dict[str, str]) -> dict[str, str]:
    result = env.copy()
    result["FOVEA_CACHE_LAB_IDENTITY"] = json.dumps(
        git_identity(ROOT, dependency_mode="root-worktree"),
        sort_keys=True,
        separators=(",", ":"),
    )
    result["FOVEA_CACHE_LAB_AKASHIC_IDENTITY"] = json.dumps(
        akashic_identity(), sort_keys=True, separators=(",", ":")
    )
    result["FOVEA_CACHE_LAB_PLAN_DIGEST"] = canonical_digest(
        ROOT / "Benchmarks/CacheLab/cache-plan.json"
    )
    result["FOVEA_CLAIM_FAMILY_DIGEST"] = canonical_digest(
        ROOT / "Benchmarks/statistical-claim-families.json"
    )
    return result


def expected_source_identity(env: dict[str, str]) -> dict[str, str]:
    return {
        "Fovea": env["FOVEA_CACHE_LAB_IDENTITY"],
        "Akashic": env["FOVEA_CACHE_LAB_AKASHIC_IDENTITY"],
        "LRUCache": "cb5b2bd0da83ad29c0bec762d39f41c8ad0eaf3e",
        "PINCache": "2fb85948463292c2e824148cf17dc62a4c217a94",
        "PINOperation": "a74f978733bdaf982758bfa23d70a189f4b4c1b6",
    }


def validate_runner_report(
    report: dict[str, Any],
    *,
    env: dict[str, str],
    expected_mode: str,
    repetition: int | None,
) -> None:
    if report.get("schemaVersion") != 4 or report.get("planID") != "FOVEA-CACHE-LAB-V4":
        raise RuntimeError("runner report identity mismatch")
    if report.get("executionMode") != expected_mode:
        raise RuntimeError("runner report mode mismatch")
    if report.get("benchmarkScope") != "all" or report.get("provisional") is not False:
        raise RuntimeError("formal runner report scope/provisional mismatch")
    if report.get("sourceIdentity") != expected_source_identity(env):
        raise RuntimeError("runner report source identities differ across process blocks")
    if report.get("experimentPlanDigest") != env["FOVEA_CACHE_LAB_PLAN_DIGEST"]:
        raise RuntimeError("runner report plan digest mismatch")
    if report.get("claimFamilyDigest") != env["FOVEA_CLAIM_FAMILY_DIGEST"]:
        raise RuntimeError("runner report claim-family digest mismatch")
    runs = report.get("runs")
    correctness = report.get("diskCorrectness")
    if expected_mode == "formal-correctness":
        if runs != [] or not isinstance(correctness, list) or len(correctness) != 3:
            raise RuntimeError("correctness process report is incomplete")
    else:
        if correctness != [] or not isinstance(runs, list) or len(runs) != 1:
            raise RuntimeError("formal process block report is incomplete")
        if runs[0].get("repetition") != repetition:
            raise RuntimeError("formal process block repetition mismatch")


def wait_for_clean_host(
    *,
    clean_samples: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    return wait_for_quiescence(
        required_clean_samples=clean_samples,
        sample_interval_seconds=1.0,
        timeout_seconds=timeout_seconds,
    )


def run_calibration(
    *,
    runner: Path,
    env: dict[str, str],
    repetitions: int,
    scope: str,
    stem: str,
) -> int:
    preflight = calibration_preflight()
    final_raw = ARTIFACT_ROOT / f"{stem}-raw-results.json"
    final_log = ARTIFACT_ROOT / f"{stem}-runner.log"
    pending_raw = ARTIFACT_ROOT / f".{stem}-raw-results-{os.getpid()}.json"
    pending_log = ARTIFACT_ROOT / f".{stem}-runner-{os.getpid()}.log"
    for pending in (pending_raw, pending_log):
        pending.unlink(missing_ok=True)
    return_code, monitor = run_monitored(
        [
            str(runner),
            "--repetitions",
            str(repetitions),
            "--output",
            str(pending_raw),
            "--scope",
            scope,
        ],
        cwd=ROOT,
        env=env,
        log_path=pending_log,
        timeout_seconds=7200,
        sample_interval_seconds=1.0,
        abort_on_contamination=False,
    )
    evidence = {
        "schemaVersion": POLICY_SCHEMA_VERSION,
        "policyID": POLICY_ID,
        "runnerExecution": {
            "directBinary": True,
            "buildExcludedFromMeasurement": True,
            "completed": return_code == 0,
            "processModel": "single-calibration-process",
        },
        "preflight": preflight,
        "monitor": monitor,
        "quiescentHostBound": (
            preflight["passed"]
            and return_code == 0
            and not monitor["contaminated"]
            and not monitor["timedOut"]
        ),
    }
    atomic_json_write(ARTIFACT_ROOT / f"{stem}-host-execution.json", evidence)
    if return_code != 0:
        pending_raw.unlink(missing_ok=True)
        if pending_log.exists():
            os.replace(pending_log, ARTIFACT_ROOT / f"{stem}-failed-runner.log")
        return return_code
    report = json.loads(pending_raw.read_text())
    if report.get("schemaVersion") != 4 or report.get("executionMode") != "calibration":
        raise SystemExit("calibration runner produced an unexpected report")
    report["hostExecutionEvidence"] = evidence
    atomic_json_write(pending_raw, report)
    os.replace(pending_raw, final_raw)
    os.replace(pending_log, final_log)
    analyze_report(final_raw, ARTIFACT_ROOT / f"{stem}-analysis.json", env)
    print(final_log.read_text(errors="replace"), end="")
    return 0


def incomplete_formal_evidence(
    *,
    preflight: dict[str, Any],
    correctness: dict[str, Any] | None,
    accepted_blocks: list[dict[str, Any]],
    rejected_attempts: list[dict[str, Any]],
    recovery_preflights: list[dict[str, Any]],
) -> dict[str, Any]:
    accepted_monitors: list[dict[str, Any]] = []
    if correctness is not None:
        accepted_monitors.append(correctness["monitor"])
    accepted_monitors.extend(item["monitor"] for item in accepted_blocks)
    return {
        "schemaVersion": POLICY_SCHEMA_VERSION,
        "policyID": POLICY_ID,
        "runnerExecution": {
            "directBinary": True,
            "buildExcludedFromMeasurement": True,
            "completed": False,
            "processModel": "independent-process-per-resampling-unit",
            "acceptedBlockCount": len(accepted_blocks),
        },
        "preflight": preflight,
        "correctness": correctness,
        "acceptedBlocks": accepted_blocks,
        "rejectedAttempts": rejected_attempts,
        "recoveryPreflights": recovery_preflights,
        "monitor": aggregate_monitors(accepted_monitors),
        "quiescentHostBound": False,
    }


def analyze_report(raw: Path, output: Path, env: dict[str, str]) -> None:
    result = run(
        [
            "python3",
            "scripts/analyze-cache-lab.py",
            "--input",
            str(raw),
            "--output",
            str(output),
        ],
        env=env,
        timeout=600,
    )
    print(result.stdout, end="")


def run_formal_campaign(
    *,
    runner: Path,
    env: dict[str, str],
    repetitions: int,
    clean_samples: int,
    quiescence_timeout: float,
    maximum_attempts: int,
    campaign_timeout: float,
) -> int:
    stem = "formal"
    host_sidecar = ARTIFACT_ROOT / "formal-host-execution.json"
    final_raw = ARTIFACT_ROOT / "formal-raw-results.json"
    final_log = ARTIFACT_ROOT / "formal-runner.log"
    pending_raw = ARTIFACT_ROOT / f".formal-raw-results-{os.getpid()}.json"
    pending_log = ARTIFACT_ROOT / f".formal-runner-{os.getpid()}.log"
    campaign_directory = ARTIFACT_ROOT / f".formal-campaign-{os.getpid()}"
    shutil.rmtree(campaign_directory, ignore_errors=True)
    campaign_directory.mkdir(parents=True)
    pending_raw.unlink(missing_ok=True)
    pending_log.unlink(missing_ok=True)

    started = time.monotonic()
    attempts_used = 0
    rejected_attempts: list[dict[str, Any]] = []
    recovery_preflights: list[dict[str, Any]] = []
    accepted_evidence: list[dict[str, Any]] = []
    accepted_reports: list[dict[str, Any]] = []
    correctness_evidence: dict[str, Any] | None = None
    correctness_report: dict[str, Any] | None = None
    combined_log_parts: list[str] = []

    preflight = wait_for_clean_host(
        clean_samples=clean_samples,
        timeout_seconds=quiescence_timeout,
    )
    if not preflight["passed"]:
        atomic_json_write(
            host_sidecar,
            incomplete_formal_evidence(
                preflight=preflight,
                correctness=None,
                accepted_blocks=[],
                rejected_attempts=[],
                recovery_preflights=[],
            ),
        )
        shutil.rmtree(campaign_directory, ignore_errors=True)
        print("Cache Lab formal campaign could not establish initial host quiescence.", file=sys.stderr)
        return 75

    def campaign_expired() -> bool:
        return (
            attempts_used >= maximum_attempts
            or time.monotonic() - started >= campaign_timeout
        )

    def recover_quiescence() -> bool:
        while not campaign_expired():
            item = wait_for_clean_host(
                clean_samples=clean_samples,
                timeout_seconds=min(
                    quiescence_timeout,
                    max(1.0, campaign_timeout - (time.monotonic() - started)),
                ),
            )
            recovery_preflights.append(item)
            if item["passed"]:
                return True
        return False

    def execute_attempt(
        *,
        phase: str,
        repetition: int | None,
        attempt: int,
    ) -> tuple[dict[str, Any] | None, dict[str, Any], str, int]:
        suffix = "correctness" if phase == "correctness" else f"block-{repetition:02d}"
        raw_path = campaign_directory / f"{suffix}-attempt-{attempt}.json"
        log_path = campaign_directory / f"{suffix}-attempt-{attempt}.log"
        command = [
            str(runner),
            "--formal",
            "--repetitions",
            "1",
            "--scope",
            "all",
            "--output",
            str(raw_path),
        ]
        if phase == "correctness":
            command.append("--correctness-only")
        else:
            command.extend(["--formal-block-index", str(repetition)])
        return_code, monitor = run_monitored(
            command,
            cwd=ROOT,
            env=env,
            log_path=log_path,
            timeout_seconds=900,
            sample_interval_seconds=1.0,
            abort_on_contamination=True,
        )
        log_text = log_path.read_text(errors="replace") if log_path.exists() else ""
        report = json.loads(raw_path.read_text()) if return_code == 0 and raw_path.is_file() else None
        raw_path.unlink(missing_ok=True)
        log_path.unlink(missing_ok=True)
        return report, monitor, log_text, return_code

    try:
        correctness_attempt = 0
        while correctness_report is None:
            if campaign_expired():
                break
            correctness_attempt += 1
            attempts_used += 1
            report, monitor, log_text, return_code = execute_attempt(
                phase="correctness",
                repetition=None,
                attempt=correctness_attempt,
            )
            if return_code == 0 and report is not None:
                validate_runner_report(
                    report,
                    env=env,
                    expected_mode="formal-correctness",
                    repetition=None,
                )
                correctness_report = report
                correctness_evidence = {
                    "attempt": correctness_attempt,
                    "monitor": monitor,
                }
                combined_log_parts.append("=== formal correctness ===\n" + log_text)
                break
            rejected_attempts.append(
                {
                    "phase": "correctness",
                    "attempt": correctness_attempt,
                    "monitor": monitor,
                }
            )
            if not monitor["abortedForContamination"]:
                print(log_text[-30000:], file=sys.stderr)
                return return_code or 1
            if not recover_quiescence():
                break

        if correctness_report is not None:
            for repetition in range(repetitions):
                block_attempt = 0
                while True:
                    if campaign_expired():
                        break
                    block_attempt += 1
                    attempts_used += 1
                    report, monitor, log_text, return_code = execute_attempt(
                        phase="block",
                        repetition=repetition,
                        attempt=block_attempt,
                    )
                    if return_code == 0 and report is not None:
                        validate_runner_report(
                            report,
                            env=env,
                            expected_mode="formal-block",
                            repetition=repetition,
                        )
                        accepted_reports.append(report)
                        accepted_evidence.append(
                            {
                                "repetition": repetition,
                                "attempt": block_attempt,
                                "monitor": monitor,
                            }
                        )
                        combined_log_parts.append(
                            f"=== formal block {repetition} ===\n" + log_text
                        )
                        break
                    rejected_attempts.append(
                        {
                            "phase": "block",
                            "repetition": repetition,
                            "attempt": block_attempt,
                            "monitor": monitor,
                        }
                    )
                    if not monitor["abortedForContamination"]:
                        print(log_text[-30000:], file=sys.stderr)
                        return return_code or 1
                    if not recover_quiescence():
                        break
                if len(accepted_reports) != repetition + 1:
                    break

        completed = (
            correctness_report is not None
            and correctness_evidence is not None
            and len(accepted_reports) == repetitions
        )
        if not completed:
            evidence = incomplete_formal_evidence(
                preflight=preflight,
                correctness=correctness_evidence,
                accepted_blocks=accepted_evidence,
                rejected_attempts=rejected_attempts,
                recovery_preflights=recovery_preflights,
            )
            atomic_json_write(host_sidecar, evidence)
            print(
                "Cache Lab formal campaign ended before collecting every clean process block.",
                file=sys.stderr,
            )
            return 75

        accepted_monitors = [correctness_evidence["monitor"]] + [
            item["monitor"] for item in accepted_evidence
        ]
        aggregate_monitor = aggregate_monitors(accepted_monitors)
        evidence = {
            "schemaVersion": POLICY_SCHEMA_VERSION,
            "policyID": POLICY_ID,
            "runnerExecution": {
                "directBinary": True,
                "buildExcludedFromMeasurement": True,
                "completed": True,
                "processModel": "independent-process-per-resampling-unit",
                "acceptedBlockCount": repetitions,
            },
            "preflight": preflight,
            "correctness": correctness_evidence,
            "acceptedBlocks": accepted_evidence,
            "rejectedAttempts": rejected_attempts,
            "recoveryPreflights": recovery_preflights,
            "monitor": aggregate_monitor,
            "quiescentHostBound": (
                not aggregate_monitor["contaminated"]
                and not aggregate_monitor["timedOut"]
            ),
        }
        first = accepted_reports[0]
        aggregate_report = {
            "schemaVersion": 4,
            "planID": "FOVEA-CACHE-LAB-V4",
            "executionMode": "formal",
            "benchmarkScope": "all",
            "provisional": False,
            "sourceIdentity": first["sourceIdentity"],
            "experimentPlanDigest": first["experimentPlanDigest"],
            "claimFamilyDigest": first["claimFamilyDigest"],
            "diskCorrectness": correctness_report["diskCorrectness"],
            "runs": sorted(
                [report["runs"][0] for report in accepted_reports],
                key=lambda item: item["repetition"],
            ),
            "hostExecutionEvidence": evidence,
        }
        atomic_json_write(pending_raw, aggregate_report)
        pending_log.write_text("\n".join(combined_log_parts))
        atomic_json_write(host_sidecar, evidence)
        os.replace(pending_raw, final_raw)
        os.replace(pending_log, final_log)
        analyze_report(final_raw, ARTIFACT_ROOT / "formal-analysis.json", env)
        print(final_log.read_text(errors="replace"), end="")
        return 0
    finally:
        pending_raw.unlink(missing_ok=True)
        pending_log.unlink(missing_ok=True)
        shutil.rmtree(campaign_directory, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the standalone Fovea Cache Lab.")
    parser.add_argument(
        "--mode", choices=["calibration", "formal"], default="calibration"
    )
    parser.add_argument("--repetitions", type=int)
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument(
        "--scope", choices=["all", "memory", "hot", "concurrent"], default="all"
    )
    parser.add_argument("--host-clean-samples", type=int, default=10)
    parser.add_argument("--host-quiescence-timeout", type=float, default=120.0)
    parser.add_argument("--formal-max-attempts", type=int, default=80)
    parser.add_argument("--formal-campaign-timeout", type=float, default=3600.0)
    args = parser.parse_args()

    plan = json.loads((ROOT / "Benchmarks/CacheLab/cache-plan.json").read_text())
    formal_repetitions = int(plan["statistics"]["repetitions"])
    repetitions = args.repetitions or (
        formal_repetitions if args.mode == "formal" else 3
    )
    if args.mode == "formal" and repetitions != formal_repetitions:
        raise SystemExit(
            f"formal Cache Lab requires exactly {formal_repetitions} process blocks"
        )
    if args.mode == "formal" and args.scope != "all":
        raise SystemExit("formal Cache Lab requires --scope all")
    if args.host_clean_samples < 1:
        raise SystemExit("host clean sample count must be positive")
    if args.host_quiescence_timeout <= 0:
        raise SystemExit("host quiescence timeout must be positive")
    if args.formal_max_attempts < repetitions + 1:
        raise SystemExit("formal maximum attempts cannot be smaller than required processes")
    if args.formal_campaign_timeout <= 0:
        raise SystemExit("formal campaign timeout must be positive")

    env = environment()
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    scope_suffix = "" if args.scope == "all" else f"-{args.scope}"
    stem = f"{args.mode}{scope_suffix}"
    run(["python3", "scripts/check-cache-lab-plan.py"], env=env, timeout=180)
    if not args.skip_tests:
        test = run(
            ["xcrun", "swift", "test", "--package-path", str(PACKAGE)],
            env=env,
            timeout=900,
        )
        (ARTIFACT_ROOT / "cache-lab-tests.log").write_text(test.stdout)

    runner = build_runner(env, stem)
    env = common_environment(env)
    if args.mode == "formal":
        return run_formal_campaign(
            runner=runner,
            env=env,
            repetitions=repetitions,
            clean_samples=args.host_clean_samples,
            quiescence_timeout=args.host_quiescence_timeout,
            maximum_attempts=args.formal_max_attempts,
            campaign_timeout=args.formal_campaign_timeout,
        )
    return run_calibration(
        runner=runner,
        env=env,
        repetitions=repetitions,
        scope=args.scope,
        stem=stem,
    )


if __name__ == "__main__":
    raise SystemExit(main())
