#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

CONFORMANCE_ROOT = Path(__file__).resolve().parents[2]
if str(CONFORMANCE_ROOT) not in sys.path:
    sys.path.insert(0, str(CONFORMANCE_ROOT))

from _support import (
    command_output,
    digest,
    run_swift_tests,
    source_digest,
    swift_string,
    working_tree_identity,
    xctest_summary,
)

KIT_ROOT = Path(__file__).resolve().parent
ROOT = KIT_ROOT.parents[2]
MANIFEST = KIT_ROOT / "manifest.json"
HARNESS = KIT_ROOT / "Harness/ImageCodecConformanceTests.swift"
DEFAULT_OUTPUT = ROOT / ".artifacts/conformance/image-codec-v1/report.json"
DEFAULT_WORK = ROOT / ".artifacts/conformance/image-codec-v1/work"


def normalized_identity(value: str) -> str:
    return value.lower().replace("_", "-")


def package_manifest(
    codec_path: Path,
    codec_package_name: str,
    codec_product: str,
    contract: dict[str, str],
) -> str:
    same_package = normalized_identity(codec_package_name) == normalized_identity(
        contract["packageIdentity"]
    )
    dependencies = [f'.package(path: {swift_string(str(codec_path))})']
    if not same_package:
        dependencies.insert(
            0,
            ".package(\n"
            f"            url: {swift_string(contract['url'])},\n"
            f"            revision: {swift_string(contract['revision'])}\n"
            "        )",
        )
    dependencies_text = ",\n        ".join(dependencies)
    return f'''// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCodecConformanceRun",
    platforms: [.macOS(.v12)],
    dependencies: [
        {dependencies_text},
    ],
    targets: [
        .testTarget(
            name: "ImageCodecConformanceTests",
            dependencies: [
                .product(
                    name: {swift_string(contract["product"])},
                    package: {swift_string(contract["packageIdentity"])}
                ),
                .product(
                    name: {swift_string(codec_product)},
                    package: {swift_string(codec_package_name)}
                ),
            ]
        )
    ]
)
'''


def validate_manifest(document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise ValueError("manifest must be an object")
    if document.get("schemaVersion") != 1:
        raise ValueError("manifest schemaVersion must be 1")
    if document.get("kitID") != "FOVEA-IMAGE-CODEC-CONFORMANCE-V1":
        raise ValueError("unexpected kitID")
    if document.get("contractVersion") != 1:
        raise ValueError("unexpected contractVersion")
    obligations = document.get("obligations")
    if not isinstance(obligations, list) or not obligations:
        raise ValueError("manifest obligations are required")
    expected_ids = [f"FOVEA-ICT-{index:03d}" for index in range(1, 7)]
    actual_ids = [item.get("id") if isinstance(item, dict) else None for item in obligations]
    if actual_ids != expected_ids:
        raise ValueError(f"obligation sequence drifted: {actual_ids}")
    harness_source = HARNESS.read_text()
    for item in obligations:
        if not isinstance(item, dict):
            raise ValueError("obligation must be an object")
        if not isinstance(item.get("summary"), str) or len(item["summary"].strip()) < 24:
            raise ValueError(f"{item.get('id')}: summary is missing")
        if not isinstance(item.get("testName"), str) or item["testName"] not in harness_source:
            raise ValueError(f"{item.get('id')}: testName is missing from harness")
    dependencies = document.get("componentDependencies")
    contract = dependencies.get("imageCraftContract") if isinstance(dependencies, dict) else None
    if not isinstance(contract, dict):
        raise ValueError("ImageCraft contract dependency is required")
    for key in ("url", "revision", "packageIdentity", "product"):
        if not isinstance(contract.get(key), str) or not contract[key]:
            raise ValueError(f"ImageCraft contract field is invalid: {key}")
    if len(contract["revision"]) != 40:
        raise ValueError("ImageCraft contract dependency must use an exact revision")
    rules = document.get("rules")
    required_rules = {
        "backendEvidenceDoesNotReplaceFoveaCompositionEvidence": True,
        "referenceFixturesDoNotProveHostileCorpusSafety": True,
        "releaseQualified": False,
        "unsupportedOrSkippedFailsClosed": True,
    }
    if not isinstance(rules, dict) or any(
        rules.get(key) is not value for key, value in required_rules.items()
    ):
        raise ValueError("manifest fail-closed rules drifted")
    return document


def verify_same_contract_package(
    codec_path: Path,
    codec_package_name: str,
    contract: dict[str, str],
    env: dict[str, str],
) -> None:
    if normalized_identity(codec_package_name) != normalized_identity(
        contract["packageIdentity"]
    ):
        return
    head = command_output(["git", "rev-parse", "HEAD"], codec_path, env)
    dirty = command_output(["git", "status", "--porcelain"], codec_path, env)
    if head != contract["revision"] or dirty:
        raise ValueError(
            "codec package is also the contract package but is not the clean exact manifest revision"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run image codec conformance v1.")
    parser.add_argument("--codec-package-path", required=True)
    parser.add_argument("--codec-package-name")
    parser.add_argument("--codec-product", required=True)
    parser.add_argument("--factory-source", required=True)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--work-directory", default=str(DEFAULT_WORK))
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    output_path = Path(args.output).resolve()
    work = Path(args.work_directory).resolve()
    codec_path = Path(args.codec_package_path).resolve()
    codec_package_name = args.codec_package_name or codec_path.name
    factory = Path(args.factory_source).resolve()
    log_path = output_path.with_suffix(".log")

    try:
        manifest = validate_manifest(json.loads(MANIFEST.read_text()))
        contract = manifest["componentDependencies"]["imageCraftContract"]
        if not (codec_path / "Package.swift").is_file():
            raise ValueError("codec package path is invalid")
        if not factory.is_file() or "CodecUnderTest" not in factory.read_text():
            raise ValueError("factory source must define CodecUnderTest")
        if args.timeout <= 0 or args.timeout > 3_600:
            raise ValueError("timeout must be in 1...3600 seconds")

        env = os.environ.copy()
        env["DEVELOPER_DIR"] = command_output(
            [str(ROOT / "scripts/select-xcode.sh")], ROOT, env
        )
        verify_same_contract_package(codec_path, codec_package_name, contract, env)

        shutil.rmtree(work, ignore_errors=True)
        tests = work / "Tests/ImageCodecConformanceTests"
        tests.mkdir(parents=True)
        (work / "Package.swift").write_text(
            package_manifest(
                codec_path,
                codec_package_name,
                args.codec_product,
                contract,
            )
        )
        shutil.copy2(HARNESS, tests / HARNESS.name)
        shutil.copy2(factory, tests / "CodecUnderTest.swift")

        return_code, test_output, elapsed, timed_out = run_swift_tests(
            ["xcrun", "swift", "test", "--package-path", str(work)],
            ROOT,
            env,
            args.timeout,
        )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(test_output)

        obligations = manifest["obligations"]
        observed = {
            item["id"]: (
                "Test Case '-[ImageCodecConformanceTests.ImageCodecConformanceTests "
                f"{item['testName']}]'"
            ) in test_output
            for item in obligations
        }
        unique_test_names = {item["testName"] for item in obligations}
        executed_test_count, failure_count = xctest_summary(test_output)
        skipped = " test skipped" in test_output or " tests skipped" in test_output
        passed = (
            return_code == 0
            and all(observed.values())
            and executed_test_count == len(unique_test_names)
            and failure_count == 0
            and not skipped
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
            "codecPackageName": codec_package_name,
            "codecProduct": args.codec_product,
            "manifestSha256": digest(MANIFEST),
            "harnessSha256": digest(HARNESS),
            "factorySha256": digest(factory),
            "codecSourceSha256": source_digest(codec_path),
            "foveaKitVerifiedTree": working_tree_identity(ROOT, env),
            "componentDependencies": manifest["componentDependencies"],
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
            "Image codec conformance: "
            f"status={report['status']} obligations={sum(observed.values())}/{len(observed)} "
            f"elapsed={elapsed:.1f}s report={output_path.relative_to(ROOT)}"
        )
        if not passed:
            print("\n".join(test_output.splitlines()[-160:]), file=sys.stderr)
        return 0 if passed else 1
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"Image codec conformance failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
