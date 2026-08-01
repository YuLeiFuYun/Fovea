#!/usr/bin/env python3
"""执行锁定竞品的原生测试，不修改其源码或用 Fovea 语义测试替代。"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_ROOT = ROOT / ".artifacts/comparators/upstream-tests"
SOURCE_ROOT = ROOT / ".artifacts/comparators/sources"
WORKSPACE_ROOT = ROOT / ".artifacts/comparators/upstream-test-workspaces"
LOCK = ROOT / "docs/research/comparator-lock.json"


@dataclass(frozen=True)
class Suite:
    project: str
    name: str
    runner: str
    platform: str
    classification: str
    container_kind: str | None = None
    container: str | None = None
    scheme: str | None = None
    settings: tuple[str, ...] = ()

    @property
    def identifier(self) -> str:
        return f"{self.project}-{self.name}".lower()


SUITES = [
    Suite("Nuke", "core", "xcodebuild", "macOS", "original-core", "project", "Nuke.xcodeproj", "NukeTests"),
    Suite(
        "Nuke", "thread-safety", "xcodebuild", "macOS", "original-concurrency",
        "project", "Nuke.xcodeproj", "NukeThreadSafetyTests",
    ),
    Suite(
        "Nuke", "performance-host", "xcodebuild", "macOS/Catalyst host", "original-performance",
        "project", "Nuke.xcodeproj", "NukePerformanceTests",
    ),
    Suite(
        "Nuke", "extensions", "xcodebuild", "macOS", "original-ui-extension",
        "project", "Nuke.xcodeproj", "NukeExtensionsTests",
    ),
    Suite(
        "Nuke", "ui", "xcodebuild", "iOS Simulator", "original-ui",
        "project", "Nuke.xcodeproj", "NukeUITests",
    ),
    Suite(
        "Kingfisher", "core", "xcodebuild", "macOS", "original-core",
        "project", "Kingfisher.xcodeproj", "Kingfisher", ("MACOSX_DEPLOYMENT_TARGET=12.0",),
    ),
    Suite(
        "SDWebImage", "macos", "xcodebuild", "macOS", "original-macos",
        "workspace", "SDWebImage.xcworkspace", "Tests Mac", ("MACOSX_DEPLOYMENT_TARGET=12.0",),
    ),
    Suite(
        "SDWebImage", "ios", "xcodebuild", "iOS Simulator", "original-ios",
        "workspace", "SDWebImage.xcworkspace", "Tests iOS", ("IPHONEOS_DEPLOYMENT_TARGET=15.0",),
    ),
    Suite(
        "PINRemoteImage", "ios", "xcodebuild", "iOS Simulator", "original-ios",
        "workspace", "PINRemoteImage.xcworkspace", "PINRemoteImage",
        ("IPHONEOS_DEPLOYMENT_TARGET=15.0",),
    ),
    Suite(
        "AlamofireImage", "swiftpm-macos", "swiftpm", "macOS", "original-swiftpm-tests",
    ),
]

TEXT_ISSUE_SIGNATURES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("ui-scene-lifecycle-required", ("uiscene life cycle is required",)),
    ("external-giphy-fixture-unavailable", ("media.giphy.com", "status code 404")),
    ("host-provenance-xattr-visible", ("com.apple.provenance",)),
    ("test-process-simctl-unavailable", ('unable to find utility "simctl"',)),
)

METHOD_ISSUE_SIGNATURES: tuple[tuple[str, str], ...] = (
    (
        "kingfisher-mutable-data-copy-on-write-assertion",
        "testSessionDataTaskMutableDataGetterDoesNotShareStorage",
    ),
    ("platform-heic-animated-behavior", "test16ThatHEICAnimatedWorks"),
    ("platform-hdr-encode-behavior", "test34ThatHDREncodeWorks"),
    ("sdwebimage-animated-view-category-assertion", "test22AnimatedImageViewCategory"),
    ("sdwebimage-transition-cancellation-assertion", "testUIViewCancelCurrentImageLoadWithTransition"),
    ("sdwebimage-download-decryptor-assertion", "test25ThatDownloadDecryptorWorks"),
    ("sdwebimage-urlsession-metrics-assertion", "test26DownloadURLSessionMetrics"),
    (
        "alamofireimage-multi-subscriber-cancellation-assertion",
        "testThatCancellingDownloadWithMultipleResponseHandlersCancelsFirstYetAllowsSecondToComplete",
    ),
    (
        "alamofireimage-cache-hit-receipt-assertion",
        "testThatItAutomaticallyCachesDownloadedImageIfCacheIsAvailable",
    ),
    ("alamofireimage-progress-callback-assertion", "testThatItCallsTheProgressHandler"),
    ("alamofireimage-download-cancel-retry-assertion", "testThatItCanDownloadAndCancelAndDownloadAgain"),
    ("pinremoteimage-localized-url-error-assertion", "testErrorOnEmptyURLDownload"),
    ("pinremoteimage-external-qos-fixture-assertions", "testQOS"),
    ("alamofireimage-network-dependent-assertions", "AlamofireImageTests.ImageDownloader"),
)



def environment() -> dict[str, str]:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        result = subprocess.run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        env["DEVELOPER_DIR"] = result.stdout.strip()
    return env


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )


def git_output(source: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(source), *arguments],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def verify_sources() -> dict[str, dict[str, Any]]:
    lock = json.loads(LOCK.read_text())
    records = {
        item["name"]: item
        for item in lock["comparators"]
        if item["phase0bRole"] == "required"
    }
    expected = {"Nuke", "Kingfisher", "SDWebImage", "PINRemoteImage", "AlamofireImage"}
    if set(records) != expected:
        raise RuntimeError("comparator lock does not contain the four A-tier Git projects and B-tier AlamofireImage")
    for name, item in records.items():
        source = SOURCE_ROOT / name
        if git_output(source, "rev-parse", "HEAD") != item["exactCommit"]:
            raise RuntimeError(f"{name} source checkout differs from lock")
        if git_output(source, "status", "--porcelain"):
            raise RuntimeError(f"{name} source checkout is dirty")
    return records


def tracked_tree_digest(source: Path, mirror: Path | None = None) -> str:
    paths = git_output(source, "ls-files", "-z").split("\0")
    digest = hashlib.sha256()
    for relative in sorted(path for path in paths if path):
        expected = source / relative
        actual = (mirror / relative) if mirror is not None else expected
        if not actual.is_file() and not actual.is_symlink():
            raise RuntimeError(f"tracked source missing from generated workspace: {relative}")
        digest.update(relative.encode())
        digest.update(b"\0")
        if expected.is_symlink():
            if not actual.is_symlink() or os.readlink(expected) != os.readlink(actual):
                raise RuntimeError(f"tracked symlink differs in generated workspace: {relative}")
            digest.update(os.readlink(actual).encode())
        else:
            expected_bytes = expected.read_bytes()
            actual_bytes = actual.read_bytes()
            if mirror is not None and actual_bytes != expected_bytes:
                raise RuntimeError(f"tracked source differs in generated workspace: {relative}")
            digest.update(actual_bytes)
        digest.update(b"\0")
    return digest.hexdigest()


def safe_extract_tar(payload: bytes, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as archive:
        destination_real = destination.resolve()
        for member in archive.getmembers():
            target = (destination / member.name).resolve()
            if destination_real not in target.parents and target != destination_real:
                raise RuntimeError("git archive contains an unsafe path")
        archive.extractall(destination, filter="data")


def prepare_sdwebimage_workspace(
    env: dict[str, str],
    exact_commit: str,
    *,
    refresh: bool,
    timeout: int,
) -> tuple[Path, dict[str, Any]]:
    source = SOURCE_ROOT / "SDWebImage"
    workspace = WORKSPACE_ROOT / "SDWebImage"
    marker = workspace / ".fovea-upstream-workspace.json"
    expected_digest = tracked_tree_digest(source)
    valid = False
    if workspace.is_dir() and not refresh:
        try:
            actual_digest = tracked_tree_digest(source, workspace)
            marker_data = json.loads(marker.read_text()) if marker.is_file() else {}
            valid = (
                actual_digest == expected_digest
                and marker_data.get("exactCommit") == exact_commit
                and marker_data.get("trackedTreeSHA256") == expected_digest
                and (workspace / "SDWebImage.xcworkspace").is_dir()
                and (workspace / "Pods/Manifest.lock").is_file()
            )
        except (OSError, RuntimeError, json.JSONDecodeError):
            valid = False
    if not valid:
        shutil.rmtree(workspace, ignore_errors=True)
        archive = subprocess.run(
            ["git", "-C", str(source), "archive", "--format=tar", exact_commit],
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
        safe_extract_tar(archive, workspace)
        pod = run(["pod", "install"], cwd=workspace, env=env, timeout=timeout)
        (ARTIFACT_ROOT / "logs").mkdir(parents=True, exist_ok=True)
        (ARTIFACT_ROOT / "logs/sdwebimage-pod-install.log").write_text(pod.stdout)
        if pod.returncode != 0:
            raise RuntimeError("SDWebImage pod install failed; see generated log")
        actual_digest = tracked_tree_digest(source, workspace)
        if actual_digest != expected_digest:
            raise RuntimeError("SDWebImage generated workspace changed tracked upstream source")
        marker.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "exactCommit": exact_commit,
                    "trackedTreeSHA256": expected_digest,
                    "generatedBy": "pod install",
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
    pod_version = run(["pod", "--version"], cwd=workspace, env=env, timeout=120)
    return workspace, {
        "kind": "generated-cocoapods-workspace",
        "exactCommit": exact_commit,
        "trackedTreeSHA256": expected_digest,
        "trackedSourceModified": False,
        "cocoaPodsVersion": pod_version.stdout.strip() if pod_version.returncode == 0 else None,
        "workspace": str(workspace.relative_to(ROOT)),
    }


def simulator_destination(env: dict[str, str]) -> str:
    result = run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        cwd=ROOT,
        env=env,
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError("cannot enumerate iOS simulators")
    data = json.loads(result.stdout)
    candidates: list[dict[str, Any]] = []
    for runtime, devices in data.get("devices", {}).items():
        if "iOS-27-0" not in runtime:
            continue
        candidates.extend(device for device in devices if device.get("isAvailable"))
    preferred = next((device for device in candidates if device.get("name") == "iPhone 17e"), None)
    if preferred is None and candidates:
        preferred = candidates[0]
    if preferred is None:
        raise RuntimeError("no available iOS 27 simulator")
    udid = preferred["udid"]
    if preferred.get("state") != "Booted":
        boot = run(["xcrun", "simctl", "boot", udid], cwd=ROOT, env=env, timeout=120)
        if boot.returncode not in {0, 149}:
            raise RuntimeError("failed to boot iOS simulator")
    ready = run(["xcrun", "simctl", "bootstatus", udid, "-b"], cwd=ROOT, env=env, timeout=240)
    if ready.returncode != 0:
        raise RuntimeError("iOS simulator did not become ready")
    return f"platform=iOS Simulator,id={udid}"


def normalized_count(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, list):
        return len(value)
    return None


def count_tests_from_xcresult(xcresult: Path, env: dict[str, str]) -> dict[str, int | None]:
    if not xcresult.exists():
        return {"tests": None, "failures": None, "skipped": None}
    result = run(
        [
            "xcrun", "xcresulttool", "get", "test-results", "summary",
            "--path", str(xcresult), "--format", "json",
        ],
        cwd=ROOT,
        env=env,
        timeout=120,
    )
    if result.returncode != 0:
        return {"tests": None, "failures": None, "skipped": None}
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"tests": None, "failures": None, "skipped": None}
    return {
        "tests": normalized_count(data.get("totalTestCount")),
        "failures": normalized_count(data.get("failedTests")),
        "skipped": normalized_count(data.get("skippedTests")),
    }


def count_tests_from_log(log: str) -> dict[str, int | None]:
    matches = list(
        re.finditer(
            r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?",
            log,
            re.IGNORECASE,
        )
    )
    if matches:
        match = matches[-1]
        return {"tests": int(match.group(1)), "failures": int(match.group(2)), "skipped": None}
    swift = list(re.finditer(r"Test run with\s+(\d+)\s+tests?", log, re.IGNORECASE))
    if swift:
        failures = 0 if "passed" in swift[-1].group(0).lower() else None
        return {"tests": int(swift[-1].group(1)), "failures": failures, "skipped": None}
    return {"tests": None, "failures": None, "skipped": None}


def failed_test_methods(log: str) -> list[str]:
    methods: set[str] = set()
    for match in re.finditer(r"Test Case '-\[([^\]]+)\]' failed", log):
        methods.add(match.group(1))
    for match in re.finditer(r"^[ \t]*[-+]\[([^\]]+)\][ \t]*$", log, re.MULTILINE):
        methods.add(match.group(1))
    for match in re.finditer(r"^[ \t]*[✘✗]\s+Test\s+([^\n]+?)(?:\s+failed|$)", log, re.MULTILINE):
        methods.add(match.group(1).strip())
    return sorted(methods)


def final_assertion_failure_count(log: str) -> int | None:
    """返回整份日志中最大的 XCTest 断言失败聚合值。

    一个测试进程会先打印子 suite，再打印总 suite。日志尾部不一定是总计，
    因此不能取最后一个匹配；最大值才是本次执行的完整断言失败计数。
    """
    matches = [
        int(match.group(1))
        for match in re.finditer(
            r"Executed\s+\d+\s+tests?,\s+with\s+(\d+)\s+failures?",
            log,
            re.IGNORECASE,
        )
    ]
    return max(matches) if matches else None


def normalize_test_counts(
    counts: dict[str, int | None],
    log: str,
) -> tuple[dict[str, int | None], list[str]]:
    methods = failed_test_methods(log)
    assertion_failures = final_assertion_failure_count(log)
    normalized = dict(counts)
    normalized["failedTestMethods"] = len(methods)
    normalized["assertionFailures"] = assertion_failures
    if methods:
        normalized["failures"] = len(methods)
    return normalized, methods


def observed_issues(log: str, failed_methods: list[str]) -> list[str]:
    """只为真实失败或明确环境错误生成问题标签。

    测试名称会在 started/passed 行出现，因此单纯全文包含测试名会产生误报。
    方法类标签必须来自 failedTestMethods；环境/外部 fixture 标签则要求完整文本签名。
    """
    lower = log.lower()
    failed = "\n".join(failed_methods).lower()
    issues = [
        identifier
        for identifier, signatures in TEXT_ISSUE_SIGNATURES
        if all(signature.lower() in lower for signature in signatures)
    ]
    issues.extend(
        identifier
        for identifier, signature in METHOD_ISSUE_SIGNATURES
        if signature.lower() in failed
    )
    return sorted(set(issues))


def failure_category(log: str, returncode: int, counts: dict[str, int | None]) -> str | None:
    if returncode == 0:
        return None
    lower = log.lower()
    if "uiscene life cycle is required" in lower:
        return "environment-incompatible-test-host"
    if counts.get("tests") and counts.get("failures"):
        return "upstream-test-failure"
    if "could not resolve package dependencies" in lower or "package resolution failed" in lower:
        return "dependency-resolution"
    if "failed to launch test runner" in lower or ("test runner" in lower and "failed" in lower):
        return "test-runner-launch"
    if "compile" in lower or "build failed" in lower or "error:" in lower:
        return "upstream-build-or-toolchain"
    return "unclassified-upstream-failure"


def suite_source(
    suite: Suite,
    env: dict[str, str],
    locks: dict[str, dict[str, Any]],
    *,
    refresh_sdwebimage: bool,
    timeout: int,
) -> tuple[Path, dict[str, Any]]:
    if suite.project == "SDWebImage":
        return prepare_sdwebimage_workspace(
            env,
            locks["SDWebImage"]["exactCommit"],
            refresh=refresh_sdwebimage,
            timeout=timeout,
        )
    source = SOURCE_ROOT / suite.project
    return source, {
        "kind": "exact-git-checkout",
        "exactCommit": locks[suite.project]["exactCommit"],
        "trackedSourceModified": False,
        "source": str(source.relative_to(ROOT)),
    }


def execute_suite(
    suite: Suite,
    env: dict[str, str],
    simulator: str,
    locks: dict[str, dict[str, Any]],
    *,
    refresh_sdwebimage: bool,
    timeout: int,
) -> dict[str, Any]:
    source, source_metadata = suite_source(
        suite,
        env,
        locks,
        refresh_sdwebimage=refresh_sdwebimage,
        timeout=timeout,
    )
    safe = suite.identifier
    derived = ARTIFACT_ROOT / "DerivedData" / safe
    result_bundle = ARTIFACT_ROOT / "xcresults" / f"{safe}.xcresult"
    log_path = ARTIFACT_ROOT / "logs" / f"{safe}.log"
    record_path = ARTIFACT_ROOT / "records" / f"{safe}.json"
    shutil.rmtree(derived, ignore_errors=True)
    shutil.rmtree(result_bundle, ignore_errors=True)
    result_bundle.parent.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.parent.mkdir(parents=True, exist_ok=True)

    if suite.runner == "swiftpm":
        command = ["xcrun", "swift", "test", "--package-path", str(source)]
        destination = "native-macOS-SwiftPM"
    else:
        destination = "platform=macOS,arch=arm64" if suite.platform != "iOS Simulator" else simulator
        container_flag = "-workspace" if suite.container_kind == "workspace" else "-project"
        command = [
            "xcodebuild",
            container_flag,
            str(source / str(suite.container)),
            "-scheme",
            str(suite.scheme),
            "-destination",
            destination,
            "-derivedDataPath",
            str(derived),
            "-resultBundlePath",
            str(result_bundle),
            *suite.settings,
            "CODE_SIGNING_ALLOWED=NO",
            "test",
        ]

    print(f"Upstream test: {suite.project} {suite.name} ({suite.platform})", flush=True)
    started = time.monotonic()
    try:
        result = run(command, cwd=source, env=env, timeout=timeout)
        log = result.stdout
        code = result.returncode
        timed_out = False
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        log = stdout.decode(errors="replace") if isinstance(stdout, bytes) else stdout
        code = 124
        timed_out = True
    duration = time.monotonic() - started
    log_path.write_text(log)

    counts = (
        count_tests_from_xcresult(result_bundle, env)
        if suite.runner == "xcodebuild"
        else count_tests_from_log(log)
    )
    if counts["tests"] is None:
        counts = count_tests_from_log(log)
    counts, failed_methods = normalize_test_counts(counts, log)
    category = "timeout" if timed_out else failure_category(log, code, counts)
    if code == 0:
        status = "passed"
    elif timed_out:
        status = "timed-out"
    elif category == "environment-incompatible-test-host":
        status = "blocked-environment"
    else:
        status = "failed"
    record = {
        "schemaVersion": 2,
        "project": suite.project,
        "suite": suite.name,
        "runner": suite.runner,
        "entrypoint": (
            {"containerKind": suite.container_kind, "container": suite.container, "scheme": suite.scheme}
            if suite.runner == "xcodebuild"
            else {"packagePath": str(source.relative_to(ROOT)), "command": "swift test"}
        ),
        "platform": suite.platform,
        "destination": destination,
        "classification": suite.classification,
        "status": status,
        "returnCode": code,
        "failureCategory": category,
        "observedIssues": observed_issues(log, failed_methods),
        "durationSeconds": round(duration, 3),
        "testCounts": counts,
        "failedTestMethods": failed_methods,
        "compatibilityOverrides": list(suite.settings),
        "source": source_metadata,
        "originalTestsModified": False,
        "originalSourcesModified": False,
        "log": str(log_path.relative_to(ROOT)),
        "xcresult": str(result_bundle.relative_to(ROOT)) if result_bundle.exists() else None,
    }
    record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return record


def assemble_report(
    records: list[dict[str, Any]],
    locks: dict[str, dict[str, Any]],
    *,
    selected_only: bool,
) -> dict[str, Any]:
    failures = [record for record in records if record["status"] == "failed"]
    blocked = [record for record in records if record["status"] in {"blocked-environment", "timed-out"}]
    passed = [record for record in records if record["status"] == "passed"]
    missing = [record for record in records if record["status"] == "not-run"]
    return {
        "schemaVersion": 2,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "sourceIdentity": {
            name: {"tag": item["tag"], "exactCommit": item["exactCommit"]}
            for name, item in locks.items()
        },
        "originalSourcesModified": False,
        "originalTestsModified": False,
        "selectedOnly": selected_only,
        "suiteCount": len(records),
        "passedSuiteCount": len(passed),
        "failedSuiteCount": len(failures),
        "blockedSuiteCount": len(blocked),
        "notRunSuiteCount": len(missing),
        "status": "incomplete" if missing else "failed" if failures else "blocked" if blocked else "passed",
        "suites": records,
        "exclusions": [
            {
                "scope": "non-iOS/macOS platform schemes",
                "classification": "platform-not-applicable-to-current-phase0b-matrix",
                "examples": ["tvOS", "watchOS", "visionOS"],
            },
            {
                "scope": "PINRemoteImage original iOS workspace deployment target",
                "classification": "toolchain-compatibility-override",
                "reason": "The locked project declares iOS 12/14 targets, while the current Xcode Simulator supports iOS 15 and newer; IPHONEOS_DEPLOYMENT_TARGET=15.0 is passed without modifying source or tests.",
            },
            {
                "scope": "AlamofireImage legacy standalone xcodeproj",
                "classification": "replaced-by-native-runnable-entrypoint",
                "reason": "The legacy project does not resolve the locked Alamofire module under the current toolchain; SwiftPM is the package's runnable original test entrypoint.",
            },
        ],
        "truthBoundary": (
            "A failing original test remains a failing original test. Environment blocks, external fixtures, "
            "platform codec behavior, and compatibility deployment overrides are reported separately; no "
            "upstream assertion, fixture, timeout, or source file is changed."
        ),
    }


def refresh_record_from_log(record: dict[str, Any]) -> dict[str, Any]:
    log_relative = record.get("log")
    if not isinstance(log_relative, str):
        return record
    log_path = ROOT / log_relative
    if not log_path.is_file():
        return record
    log = log_path.read_text(errors="replace")
    counts, methods = normalize_test_counts(record.get("testCounts", {}), log)
    record["testCounts"] = counts
    record["failedTestMethods"] = methods
    record["observedIssues"] = observed_issues(log, methods)
    returncode = record.get("returnCode")
    if isinstance(returncode, int):
        category = failure_category(log, returncode, counts)
        record["failureCategory"] = category
        if returncode == 0:
            record["status"] = "passed"
        elif category == "environment-incompatible-test-host":
            record["status"] = "blocked-environment"
        else:
            record["status"] = "failed"
    return record


def load_all_records() -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for suite in SUITES:
        path = ARTIFACT_ROOT / "records" / f"{suite.identifier}.json"
        if path.is_file():
            record = refresh_record_from_log(json.loads(path.read_text()))
            path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
            records.append(record)
        else:
            records.append(
                {
                    "schemaVersion": 2,
                    "project": suite.project,
                    "suite": suite.name,
                    "platform": suite.platform,
                    "classification": suite.classification,
                    "status": "not-run",
                    "returnCode": None,
                    "failureCategory": "missing-execution-record",
                    "observedIssues": [],
                    "testCounts": {"tests": None, "failures": None, "skipped": None},
                    "originalTestsModified": False,
                    "originalSourcesModified": False,
                }
            )
    return records


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run exact upstream image-loader tests through each project's native runnable entrypoint."
    )
    parser.add_argument("--project", action="append", choices=sorted({suite.project for suite in SUITES}))
    parser.add_argument("--suite", action="append", help="Restrict to suite name; repeatable.")
    parser.add_argument("--exclude-performance", action="store_true")
    parser.add_argument("--refresh-sdwebimage-workspace", action="store_true")
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=1200)
    parser.add_argument("--allow-failures", action="store_true")
    args = parser.parse_args()
    if args.timeout_seconds < 60:
        raise SystemExit("timeout must be at least 60 seconds")

    env = environment()
    locks = verify_sources()
    if args.report_only:
        records = load_all_records()
        selected_only = False
    else:
        selected = [suite for suite in SUITES if not args.project or suite.project in args.project]
        if args.suite:
            selected = [suite for suite in selected if suite.name in set(args.suite)]
        if args.exclude_performance:
            selected = [suite for suite in selected if suite.classification != "original-performance"]
        if not selected:
            raise SystemExit("no upstream suites selected")
        simulator = (
            simulator_destination(env)
            if any(suite.platform == "iOS Simulator" for suite in selected)
            else ""
        )
        ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
        records = [
            execute_suite(
                suite,
                env,
                simulator,
                locks,
                refresh_sdwebimage=args.refresh_sdwebimage_workspace,
                timeout=args.timeout_seconds,
            )
            for suite in selected
        ]
        selected_only = len(selected) != len(SUITES)

    report = assemble_report(records, locks, selected_only=selected_only)
    output = ARTIFACT_ROOT / ("report-selected.json" if selected_only else "report.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Upstream image-loader tests: "
        f"passed={report['passedSuiteCount']} failed={report['failedSuiteCount']} "
        f"blocked={report['blockedSuiteCount']} notRun={report['notRunSuiteCount']} "
        f"total={report['suiteCount']}"
    )
    print(f"Artifact: {output.relative_to(ROOT)}")
    has_problem = bool(report["failedSuiteCount"] or report["blockedSuiteCount"] or report["notRunSuiteCount"])
    return 0 if not has_problem or args.allow_failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
