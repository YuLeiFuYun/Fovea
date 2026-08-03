#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

KIT_ROOT = Path(__file__).resolve().parent
ROOT = KIT_ROOT.parents[2]
MANIFEST = KIT_ROOT / "manifest.json"
HARNESS = KIT_ROOT / "Harness/PersistentStoreProviderConformanceTests.swift"
DEFAULT_OUTPUT = ROOT / ".artifacts/conformance/persistent-store-provider-v1/report.json"
DEFAULT_WORK = ROOT / ".artifacts/conformance/persistent-store-provider-v1/work"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(root: Path) -> str:
    excluded = {".build", ".git", ".swiftpm", ".artifacts", "DerivedData"}
    hasher = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or any(part in excluded for part in path.relative_to(root).parts):
            continue
        relative = path.relative_to(root).as_posix().encode()
        payload = path.read_bytes()
        hasher.update(len(relative).to_bytes(4, "big"))
        hasher.update(relative)
        hasher.update(len(payload).to_bytes(8, "big"))
        hasher.update(payload)
    return hasher.hexdigest()


def command_output(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def working_tree_identity(repository: Path, env: dict[str, str]) -> str:
    top = command_output(["git", "rev-parse", "--show-toplevel"], repository, env)
    top_path = Path(top).resolve()
    with tempfile.TemporaryDirectory(prefix="fovea-conformance-index-") as temporary:
        index = Path(temporary) / "index"
        git_env = dict(env)
        git_env["GIT_INDEX_FILE"] = str(index)
        subprocess.run(
            ["git", "read-tree", "HEAD"],
            cwd=top_path,
            env=git_env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["git", "add", "-A", "--", "."],
            cwd=top_path,
            env=git_env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return command_output(["git", "write-tree"], top_path, git_env)


def swift_string(value: str) -> str:
    return json.dumps(value)


def package_manifest(
    fovea_path: Path,
    provider_path: Path,
    provider_package_name: str,
    provider_product: str,
    imagecraft: dict[str, str],
) -> str:
    return f'''// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PersistentStoreProviderConformanceRun",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(path: {swift_string(str(fovea_path))}),
        .package(path: {swift_string(str(provider_path))}),
        .package(
            url: {swift_string(imagecraft["url"])},
            revision: {swift_string(imagecraft["revision"])}
        ),
    ],
    targets: [
        .testTarget(
            name: "PersistentStoreProviderConformanceTests",
            dependencies: [
                .product(name: "FoveaAdvanced", package: "Fovea"),
                .product(
                    name: {swift_string(provider_product)},
                    package: {swift_string(provider_package_name)}
                ),
                .product(
                    name: {swift_string(imagecraft["product"])},
                    package: {swift_string(imagecraft["packageIdentity"])}
                ),
            ]
        )
    ]
)
'''


def terminate_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_tests(
    work: Path,
    env: dict[str, str],
    timeout: int,
) -> tuple[int, str, float, bool]:
    started = time.monotonic()
    process = subprocess.Popen(
        ["xcrun", "swift", "test", "--package-path", str(work)],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    timed_out = False
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_group(process)
        output, _ = process.communicate()
        output += f"\nconformance run timed out after {timeout} seconds\n"
    return (124 if timed_out else process.returncode, output, time.monotonic() - started, timed_out)


def validate_manifest(document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise ValueError("manifest must be an object")
    if document.get("schemaVersion") != 1:
        raise ValueError("manifest schemaVersion must be 1")
    if document.get("kitID") != "FOVEA-PERSISTENT-STORE-PROVIDER-CONFORMANCE-V1":
        raise ValueError("unexpected kitID")
    if document.get("contractVersion") != 1:
        raise ValueError("unexpected contractVersion")
    obligations = document.get("obligations")
    if not isinstance(obligations, list) or not obligations:
        raise ValueError("manifest obligations are required")
    expected_ids = [f"FOVEA-PSP-CT-{index:03d}" for index in range(1, 6)]
    actual_ids = [item.get("id") if isinstance(item, dict) else None for item in obligations]
    if actual_ids != expected_ids:
        raise ValueError(f"obligation sequence drifted: {actual_ids}")
    for item in obligations:
        if not isinstance(item.get("summary"), str) or len(item["summary"].strip()) < 24:
            raise ValueError(f"{item.get('id')}: summary is missing")
        if not isinstance(item.get("testName"), str) or item["testName"] not in HARNESS.read_text():
            raise ValueError(f"{item.get('id')}: testName is missing from harness")
    dependencies = document.get("componentDependencies")
    imagecraft = dependencies.get("imageCraft") if isinstance(dependencies, dict) else None
    if not isinstance(imagecraft, dict):
        raise ValueError("ImageCraft component dependency is required")
    for key in ("url", "revision", "packageIdentity", "product"):
        if not isinstance(imagecraft.get(key), str) or not imagecraft[key]:
            raise ValueError(f"ImageCraft dependency field is invalid: {key}")
    if len(imagecraft["revision"]) != 40:
        raise ValueError("ImageCraft dependency must use an exact revision")

    rules = document.get("rules")
    required_rules = {
        "componentEvidenceDoesNotReplaceHostEvidence": True,
        "inMemoryFixtureDoesNotProveCrashConsistency": True,
        "releaseQualified": False,
        "unsupportedOrSkippedFailsClosed": True,
    }
    if not isinstance(rules, dict) or any(rules.get(key) is not value for key, value in required_rules.items()):
        raise ValueError("manifest rules fail closed contract drifted")
    return document


def main() -> int:
    parser = argparse.ArgumentParser(description="Run persistent-store provider conformance v1.")
    parser.add_argument("--provider-package-path", required=True)
    parser.add_argument("--provider-package-name")
    parser.add_argument("--provider-product", required=True)
    parser.add_argument("--factory-source", required=True)
    parser.add_argument("--fovea-package-path", default=str(ROOT))
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--work-directory", default=str(DEFAULT_WORK))
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    output_path = Path(args.output).resolve()
    work = Path(args.work_directory).resolve()
    fovea_path = Path(args.fovea_package_path).resolve()
    provider_path = Path(args.provider_package_path).resolve()
    provider_package_name = args.provider_package_name or provider_path.name
    factory = Path(args.factory_source).resolve()
    log_path = output_path.with_suffix(".log")

    try:
        manifest = validate_manifest(json.loads(MANIFEST.read_text()))
        if not (fovea_path / "Package.swift").is_file():
            raise ValueError("Fovea package path is invalid")
        if not (provider_path / "Package.swift").is_file():
            raise ValueError("provider package path is invalid")
        if not factory.is_file() or "ProviderUnderTest" not in factory.read_text():
            raise ValueError("factory source must define ProviderUnderTest")
        if args.timeout <= 0 or args.timeout > 3_600:
            raise ValueError("timeout must be in 1...3600 seconds")

        shutil.rmtree(work, ignore_errors=True)
        tests = work / "Tests/PersistentStoreProviderConformanceTests"
        tests.mkdir(parents=True)
        (work / "Package.swift").write_text(
            package_manifest(
                fovea_path,
                provider_path,
                provider_package_name,
                args.provider_product,
                manifest["componentDependencies"]["imageCraft"],
            )
        )
        shutil.copy2(HARNESS, tests / HARNESS.name)
        shutil.copy2(factory, tests / "ProviderUnderTest.swift")

        env = os.environ.copy()
        env["DEVELOPER_DIR"] = command_output(
            [str(ROOT / "scripts/select-xcode.sh")], ROOT, env
        )
        return_code, test_output, elapsed, timed_out = run_tests(work, env, args.timeout)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(test_output)

        obligations = manifest["obligations"]
        observed = {
            item["id"]: f"Test Case '-[PersistentStoreProviderConformanceTests.PersistentStoreProviderConformanceTests {item['testName']}]'" in test_output
            for item in obligations
        }
        skipped = " test skipped" in test_output or " tests skipped" in test_output
        unique_test_names = {item["testName"] for item in obligations}
        summaries = re.findall(
            r"Executed ([0-9]+) tests, with ([0-9]+) failures",
            test_output,
        )
        executed_test_count = max((int(count) for count, _ in summaries), default=-1)
        failure_count = max((int(count) for _, count in summaries), default=-1)
        passed = (
            return_code == 0
            and all(observed.values())
            and not skipped
            and executed_test_count == len(unique_test_names)
            and failure_count == 0
        )
        report = {
            "schemaVersion": 1,
            "kitID": manifest["kitID"],
            "contractVersion": manifest["contractVersion"],
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "status": "passed" if passed else "failed",
            "returnCode": return_code,
            "timedOut": timed_out,
            "elapsedSeconds": round(elapsed, 3),
            "executedTestCount": executed_test_count,
            "expectedTestCount": len(unique_test_names),
            "failureCount": failure_count,
            "providerPackageName": provider_package_name,
            "providerProduct": args.provider_product,
            "manifestSha256": digest(MANIFEST),
            "harnessSha256": digest(HARNESS),
            "factorySha256": digest(factory),
            "providerSourceSha256": source_digest(provider_path),
            "componentDependencies": manifest["componentDependencies"],
            "foveaVerifiedTree": working_tree_identity(fovea_path, env),
            "swiftVersion": command_output(["xcrun", "swift", "--version"], ROOT, env),
            "xcodeVersion": command_output(["xcodebuild", "-version"], ROOT, env),
            "log": str(log_path.relative_to(ROOT)),
            "logSha256": digest(log_path),
            "obligations": [
                {
                    "id": item["id"],
                    "testName": item["testName"],
                    "observed": observed[item["id"]],
                }
                for item in obligations
            ],
            "skippedTestsObserved": skipped,
            "releaseQualified": False,
        }
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "Persistent-store provider conformance: "
            f"status={report['status']} obligations={sum(observed.values())}/{len(observed)} "
            f"elapsed={elapsed:.1f}s report={output_path.relative_to(ROOT)}"
        )
        if not passed:
            print("\n".join(test_output.splitlines()[-120:]), file=sys.stderr)
        return 0 if passed else 1
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"Persistent-store provider conformance failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
