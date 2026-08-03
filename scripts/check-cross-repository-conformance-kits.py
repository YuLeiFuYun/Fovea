#!/usr/bin/env python3
from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "ConformanceKits/PersistentStoreProvider/v1"
MANIFEST = KIT / "manifest.json"
HARNESS = KIT / "Harness/PersistentStoreProviderConformanceTests.swift"
RUNNER = KIT / "run.py"
README = KIT / "README.md"
MATRIX = ROOT / "ConformanceKits/compatibility-matrix.json"
FIXTURE = ROOT / "Fixtures/QualifiedStoreProvider"
FIXTURE_PACKAGE = FIXTURE / "Package.swift"
FIXTURE_RESOLVED = FIXTURE / "Package.resolved"
FIXTURE_SOURCE = (
    FIXTURE
    / "Sources/QualifiedStoreProviderFixture/QualifiedStoreProviderFixture.swift"
)
FACTORY = FIXTURE / "ConformanceFactory.swift"
EXPECTED_IMAGECRAFT_REVISION = "4507da936ef348fa198652c2e4314a1f393b2c90"
EXPECTED_AKASHIC_REVISION = "50e7032b155187b993b5a82f613c3a0410d32976"
EXPECTED_IDS = [f"FOVEA-PSP-CT-{index:03d}" for index in range(1, 6)]
FORBIDDEN_SOURCE = (
    "FIXTURE_TRACE",
    "FoveaTesting",
    "@testable import",
    "try!",
    " as! ",
    "fatalError(",
    "preconditionFailure(",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def object_document(path: Path) -> dict[str, object]:
    document = json.loads(path.read_text())
    require(isinstance(document, dict), f"{path.relative_to(ROOT)} must be an object")
    return document


def main() -> int:
    try:
        for path in (
            MANIFEST,
            HARNESS,
            RUNNER,
            README,
            MATRIX,
            FIXTURE_PACKAGE,
            FIXTURE_RESOLVED,
            FIXTURE_SOURCE,
            FACTORY,
        ):
            require(path.is_file(), f"missing conformance asset: {path.relative_to(ROOT)}")

        manifest = object_document(MANIFEST)
        require(manifest.get("schemaVersion") == 1, "provider manifest schemaVersion must be 1")
        require(
            manifest.get("kitID") == "FOVEA-PERSISTENT-STORE-PROVIDER-CONFORMANCE-V1",
            "provider kitID drifted",
        )
        require(manifest.get("contractVersion") == 1, "provider contractVersion must be 1")
        factory = manifest.get("factoryContract")
        require(isinstance(factory, dict), "provider factoryContract is required")
        require(factory.get("symbol") == "ProviderUnderTest", "provider factory symbol drifted")
        require(
            factory.get("method")
            == "make() throws -> any FoveaPersistentStoreBundleProviding",
            "provider factory method drifted",
        )

        obligations = manifest.get("obligations")
        require(isinstance(obligations, list), "provider obligations must be an array")
        actual_ids = [item.get("id") if isinstance(item, dict) else None for item in obligations]
        require(actual_ids == EXPECTED_IDS, f"provider obligation sequence drifted: {actual_ids}")
        harness_source = HARNESS.read_text()
        for item in obligations:
            require(isinstance(item, dict), "provider obligation must be an object")
            summary = item.get("summary")
            test_name = item.get("testName")
            require(isinstance(summary, str) and len(summary.strip()) >= 24, f"{item.get('id')}: summary missing")
            require(isinstance(test_name, str) and test_name in harness_source, f"{item.get('id')}: harness test missing")

        dependencies = manifest.get("componentDependencies")
        imagecraft = dependencies.get("imageCraft") if isinstance(dependencies, dict) else None
        require(isinstance(imagecraft, dict), "provider manifest must bind ImageCraft")
        require(
            imagecraft
            == {
                "packageIdentity": "ImageCraft",
                "product": "ImageCraftCore",
                "revision": EXPECTED_IMAGECRAFT_REVISION,
                "url": "https://github.com/YuLeiFuYun/ImageCraft.git",
            },
            "provider ImageCraft dependency drifted",
        )
        require(manifest.get("harness") == "Harness/PersistentStoreProviderConformanceTests.swift", "provider harness path drifted")
        rules = manifest.get("rules")
        require(
            rules
            == {
                "componentEvidenceDoesNotReplaceHostEvidence": True,
                "inMemoryFixtureDoesNotProveCrashConsistency": True,
                "releaseQualified": False,
                "unsupportedOrSkippedFailsClosed": True,
            },
            "provider fail-closed rules drifted",
        )

        matrix = object_document(MATRIX)
        require(matrix.get("schemaVersion") == 1, "compatibility matrix schemaVersion must be 1")
        contracts = matrix.get("contracts")
        require(isinstance(contracts, dict), "compatibility matrix contracts are required")
        provider = contracts.get("persistentStoreProvider")
        codec = contracts.get("codec")
        require(isinstance(provider, dict) and isinstance(codec, dict), "compatibility matrix contract entries are required")
        require(provider.get("contractVersion") == 1, "provider matrix contractVersion drifted")
        require(provider.get("previousContractVersion") is None, "provider v1 must remain the initial baseline")
        require(provider.get("kit") == "PersistentStoreProvider/v1/manifest.json", "provider matrix kit path drifted")
        require(provider.get("releaseQualified") is False, "provider kit must not claim release qualification")
        require(codec.get("contractVersion") == 1, "codec matrix current contractVersion drifted")
        require(codec.get("currentRevision") == EXPECTED_IMAGECRAFT_REVISION, "codec matrix ImageCraft pin drifted")
        require(codec.get("kit") is None, "codec matrix must remain pending until a runnable kit exists")
        require(codec.get("releaseQualified") is False, "codec local model must not claim release qualification")
        policy = matrix.get("policy")
        require(isinstance(policy, dict) and all(policy.get(key) is True for key in (
            "componentEvidenceDoesNotReplaceCompositionEvidence",
            "inconclusiveFailsClosed",
            "previousNullMeansInitialBaseline",
            "unsupportedFailsClosed",
        )), "compatibility matrix fail-closed policy drifted")

        runner_source = RUNNER.read_text()
        ast.parse(runner_source, filename=str(RUNNER))
        runner_markers = (
            "TemporaryDirectory",
            "start_new_session=True",
            "terminate_group(process)",
            "unsupportedOrSkippedFailsClosed",
            "skippedTestsObserved",
            "executedTestCount",
            "expectedTestCount",
            "failureCount",
            "working_tree_identity",
            "providerSourceSha256",
            "foveaVerifiedTree",
            "componentDependencies",
            "releaseQualified\": False",
            "return 0 if passed else 1",
        )
        for marker in runner_markers:
            require(marker in runner_source, f"provider runner contract marker missing: {marker}")
        require("--provider-package-path" in runner_source, "provider runner must accept an external package")
        require("--factory-source" in runner_source, "provider runner must accept an external factory")
        require("xcrun\", \"swift\", \"test" in runner_source, "provider runner must execute SwiftPM tests")
        require(EXPECTED_IMAGECRAFT_REVISION in MANIFEST.read_text(), "provider manifest lost exact ImageCraft pin")

        fixture_resolved = object_document(FIXTURE_RESOLVED)
        pins = fixture_resolved.get("pins")
        require(isinstance(pins, list), "fixture Package.resolved pins are required")
        resolved = {
            pin.get("identity"): (pin.get("state") or {}).get("revision")
            for pin in pins
            if isinstance(pin, dict) and isinstance(pin.get("state"), dict)
        }
        require(
            resolved
            == {
                "akashic": EXPECTED_AKASHIC_REVISION,
                "imagecraft": EXPECTED_IMAGECRAFT_REVISION,
            },
            f"fixture Package.resolved drifted: {resolved}",
        )

        fixture_package = FIXTURE_PACKAGE.read_text()
        require('.product(name: "FoveaAdvanced", package: "Fovea")' in fixture_package, "fixture must consume the public FoveaAdvanced product")
        require(EXPECTED_AKASHIC_REVISION in fixture_package, "fixture Akashic dependency must be exact")
        require("FoveaTesting" not in fixture_package, "fixture must not depend on FoveaTesting")
        require(".testTarget(" not in fixture_package, "fixture package must remain a production-style external provider")
        require("ProviderUnderTest" in FACTORY.read_text(), "fixture factory must define ProviderUnderTest")
        require("FoveaPersistentStoreBundleProviding" in FIXTURE_SOURCE.read_text(), "fixture must implement the public provider protocol")

        checked_sources = [HARNESS, FIXTURE_SOURCE, FACTORY]
        for path in checked_sources:
            source = path.read_text()
            for forbidden in FORBIDDEN_SOURCE:
                require(forbidden not in source, f"{path.relative_to(ROOT)} contains forbidden marker: {forbidden}")
        require("TransportReusePolicy.reusable" in harness_source or ".reusable(" in harness_source, "provider harness must explicitly authorize cross-request transport reuse")
        require("XCTAssertGreaterThan(revokedRequestCount, 1)" in harness_source, "revocation proof must tolerate bounded transport retries")
        require("FoveaTesting" not in harness_source, "provider harness must use only public products")

        readme = README.read_text()
        for marker in (
            "ProviderUnderTest",
            "release",
            "crash",
            "--provider-package-path",
        ):
            require(marker in readme, f"provider kit README missing boundary marker: {marker}")

        print(
            "Cross-repository conformance kits valid: "
            f"provider-v1 obligations={len(obligations)} codec-kit=pending"
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError, SyntaxError) as error:
        print(f"Cross-repository conformance kit validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
