#!/usr/bin/env python3
from __future__ import annotations

import ast
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFORMANCE = ROOT / "ConformanceKits"
MATRIX = CONFORMANCE / "current-contracts.json"
SUPPORT = CONFORMANCE / "_support.py"
EXPECTED_IMAGECRAFT_REVISION = "c16a868f1a1c0ed6b1a916ad082f762969ac5a7e"
EXPECTED_AKASHIC_REVISION = "2846d4715cc5917711ffa2f100ee310c2290de40"
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


def resolved_revisions(path: Path) -> dict[str, str | None]:
    document = object_document(path)
    pins = document.get("pins")
    require(isinstance(pins, list), f"{path.relative_to(ROOT)} pins are required")
    return {
        pin.get("identity"): (pin.get("state") or {}).get("revision")
        for pin in pins
        if isinstance(pin, dict) and isinstance(pin.get("state"), dict)
    }


def validate_obligations(
    manifest: dict[str, object],
    harness: Path,
    expected_ids: list[str],
) -> list[dict[str, object]]:
    obligations = manifest.get("obligations")
    require(isinstance(obligations, list), "manifest obligations must be an array")
    actual_ids = [item.get("id") if isinstance(item, dict) else None for item in obligations]
    require(actual_ids == expected_ids, f"obligation sequence drifted: {actual_ids}")
    source = harness.read_text()
    for item in obligations:
        require(isinstance(item, dict), "obligation must be an object")
        summary = item.get("summary")
        test_name = item.get("testName")
        require(
            isinstance(summary, str) and len(summary.strip()) >= 24,
            f"{item.get('id')}: summary missing",
        )
        require(
            isinstance(test_name, str) and test_name in source,
            f"{item.get('id')}: harness test missing",
        )
    return obligations


def validate_sources(paths: list[Path]) -> None:
    for path in paths:
        source = path.read_text()
        for forbidden in FORBIDDEN_SOURCE:
            require(
                forbidden not in source,
                f"{path.relative_to(ROOT)} contains forbidden marker: {forbidden}",
            )


def validate_python(path: Path) -> str:
    source = path.read_text()
    ast.parse(source, filename=str(path))
    return source


def validate_shared_support() -> str:
    require(SUPPORT.is_file(), "shared conformance support is missing")
    source = validate_python(SUPPORT)
    for marker in (
        "TemporaryDirectory",
        "start_new_session=True",
        "terminate_group(process)",
        "working_tree_identity",
        "source_digest",
        "xctest_summary",
        "conformance run timed out after",
    ):
        require(marker in source, f"shared conformance support marker missing: {marker}")
    return source


def validate_runner(
    runner: Path,
    support_source: str,
    required_markers: tuple[str, ...],
) -> str:
    require(runner.is_file(), f"missing runner: {runner.relative_to(ROOT)}")
    source = validate_python(runner)
    combined = source + "\n" + support_source
    common = (
        "start_new_session=True",
        "terminate_group(process)",
        "skippedTestsObserved",
        "executedTestCount",
        "expectedTestCount",
        "failureCount",
        "working_tree_identity",
        "source_digest",
        "componentDependencies",
        '"releaseQualified": False',
        "return 0 if passed else 1",
        '"xcrun", "swift", "test"',
    )
    for marker in common + required_markers:
        require(marker in combined, f"{runner.relative_to(ROOT)} marker missing: {marker}")
    return source


def validate_provider(support_source: str) -> int:
    kit = CONFORMANCE / "PersistentStoreProvider/v1"
    manifest_path = kit / "manifest.json"
    harness = kit / "Harness/PersistentStoreProviderConformanceTests.swift"
    runner = kit / "run.py"
    readme = kit / "README.md"
    fixture = ROOT / "Fixtures/QualifiedStoreProvider"
    fixture_package = fixture / "Package.swift"
    fixture_resolved = fixture / "Package.resolved"
    fixture_source = (
        fixture
        / "Sources/QualifiedStoreProviderFixture/QualifiedStoreProviderFixture.swift"
    )
    factory_source = fixture / "ConformanceFactory.swift"
    for path in (
        manifest_path,
        harness,
        readme,
        fixture_package,
        fixture_resolved,
        fixture_source,
        factory_source,
    ):
        require(path.is_file(), f"missing provider asset: {path.relative_to(ROOT)}")

    manifest = object_document(manifest_path)
    require(manifest.get("schemaVersion") == 1, "provider manifest schemaVersion must be 1")
    require(
        manifest.get("kitID") == "FOVEA-PERSISTENT-STORE-PROVIDER-CONFORMANCE-V1",
        "provider kitID drifted",
    )
    require(manifest.get("contractVersion") == 1, "provider contractVersion drifted")
    factory = manifest.get("factoryContract")
    require(isinstance(factory, dict), "provider factoryContract is required")
    require(factory.get("symbol") == "ProviderUnderTest", "provider factory symbol drifted")
    require(
        factory.get("method")
        == "make() throws -> any FoveaPersistentStoreBundleProviding",
        "provider factory method drifted",
    )
    obligations = validate_obligations(
        manifest,
        harness,
        [f"FOVEA-PSP-CT-{index:03d}" for index in range(1, 6)],
    )
    require(
        manifest.get("harness")
        == "Harness/PersistentStoreProviderConformanceTests.swift",
        "provider harness path drifted",
    )
    dependencies = manifest.get("componentDependencies")
    imagecraft = dependencies.get("imageCraft") if isinstance(dependencies, dict) else None
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
    require(
        manifest.get("rules")
        == {
            "componentEvidenceDoesNotReplaceHostEvidence": True,
            "inMemoryFixtureDoesNotProveCrashConsistency": True,
            "releaseQualified": False,
            "unsupportedOrSkippedFailsClosed": True,
        },
        "provider fail-closed rules drifted",
    )
    validate_runner(
        runner,
        support_source,
        (
            "--provider-package-path",
            "--factory-source",
            "providerSourceSha256",
            "foveaVerifiedTree",
            "unsupportedOrSkippedFailsClosed",
        ),
    )

    require(
        resolved_revisions(fixture_resolved)
        == {
            "akashic": EXPECTED_AKASHIC_REVISION,
            "imagecraft": EXPECTED_IMAGECRAFT_REVISION,
        },
        "provider fixture Package.resolved drifted",
    )
    package_source = fixture_package.read_text()
    require(
        '.product(name: "FoveaAdvanced", package: "Fovea")' in package_source,
        "provider fixture must consume FoveaAdvanced",
    )
    require(EXPECTED_AKASHIC_REVISION in package_source, "provider fixture Akashic pin drifted")
    require("FoveaTesting" not in package_source, "provider fixture must not depend on FoveaTesting")
    require(".testTarget(" not in package_source, "provider fixture must remain production-style")
    require("ProviderUnderTest" in factory_source.read_text(), "provider fixture factory is missing")
    require(
        "FoveaPersistentStoreBundleProviding" in fixture_source.read_text(),
        "provider fixture must implement the public provider protocol",
    )
    validate_sources([harness, fixture_source, factory_source])
    harness_source = harness.read_text()
    require(
        "TransportReusePolicy.reusable" in harness_source or ".reusable(" in harness_source,
        "provider harness must explicitly authorize reusable transport context",
    )
    require(
        "XCTAssertGreaterThan(revokedRequestCount, 1)" in harness_source,
        "provider revoke proof must tolerate bounded retries",
    )
    for marker in ("ProviderUnderTest", "release", "crash", "--provider-package-path"):
        require(marker in readme.read_text(), f"provider README marker missing: {marker}")
    return len(obligations)


def validate_codec(support_source: str) -> int:
    kit = CONFORMANCE / "ImageCodec/v1"
    manifest_path = kit / "manifest.json"
    harness = kit / "Harness/ImageCodecConformanceTests.swift"
    runner = kit / "run.py"
    readme = kit / "README.md"
    fixture = ROOT / "Fixtures/ImageIOCodec"
    fixture_package = fixture / "Package.swift"
    fixture_resolved = fixture / "Package.resolved"
    fixture_source = fixture / "Sources/ImageIOCodecFixture/ImageIOCodecFixture.swift"
    factory_source = fixture / "ConformanceFactory.swift"
    for path in (
        manifest_path,
        harness,
        readme,
        fixture_package,
        fixture_resolved,
        fixture_source,
        factory_source,
    ):
        require(path.is_file(), f"missing codec asset: {path.relative_to(ROOT)}")

    manifest = object_document(manifest_path)
    require(manifest.get("schemaVersion") == 1, "codec manifest schemaVersion must be 1")
    require(manifest.get("kitID") == "FOVEA-IMAGE-CODEC-CONFORMANCE-V1", "codec kitID drifted")
    require(manifest.get("contractVersion") == 1, "codec contractVersion drifted")
    factory = manifest.get("factoryContract")
    require(isinstance(factory, dict), "codec factoryContract is required")
    require(factory.get("symbol") == "CodecUnderTest", "codec factory symbol drifted")
    require(factory.get("method") == "make() -> any ImageCodec", "codec factory method drifted")
    obligations = validate_obligations(
        manifest,
        harness,
        [f"FOVEA-ICT-{index:03d}" for index in range(1, 7)],
    )
    require(manifest.get("harness") == "Harness/ImageCodecConformanceTests.swift", "codec harness path drifted")
    dependencies = manifest.get("componentDependencies")
    contract = dependencies.get("imageCraftContract") if isinstance(dependencies, dict) else None
    require(
        contract
        == {
            "packageIdentity": "ImageCraft",
            "product": "ImageCraftCore",
            "revision": EXPECTED_IMAGECRAFT_REVISION,
            "url": "https://github.com/YuLeiFuYun/ImageCraft.git",
        },
        "codec ImageCraft contract dependency drifted",
    )
    require(
        manifest.get("rules")
        == {
            "backendEvidenceDoesNotReplaceFoveaCompositionEvidence": True,
            "referenceFixturesDoNotProveHostileCorpusSafety": True,
            "releaseQualified": False,
            "unsupportedOrSkippedFailsClosed": True,
        },
        "codec fail-closed rules drifted",
    )
    validate_runner(
        runner,
        support_source,
        (
            "--codec-package-path",
            "--factory-source",
            "verify_same_contract_package",
            "codecSourceSha256",
            "foveaKitVerifiedTree",
        ),
    )

    require(
        resolved_revisions(fixture_resolved)
        == {"imagecraft": EXPECTED_IMAGECRAFT_REVISION},
        "codec fixture Package.resolved drifted",
    )
    package_source = fixture_package.read_text()
    require(EXPECTED_IMAGECRAFT_REVISION in package_source, "codec fixture ImageCraft pin drifted")
    require('.product(name: "ImageCraftCore", package: "ImageCraft")' in package_source, "codec fixture must depend on ImageCraftCore")
    require('.product(name: "ImageCraftImageIO", package: "ImageCraft")' in package_source, "codec fixture must expose the ImageIO backend")
    require("Fovea" not in package_source, "codec fixture must not depend on Fovea")
    require(".testTarget(" not in package_source, "codec fixture must remain production-style")
    require("CodecUnderTest" in factory_source.read_text(), "codec fixture factory is missing")
    require("ImageIOImageDecoder" in fixture_source.read_text(), "codec fixture must construct ImageIO")
    validate_sources([harness, fixture_source, factory_source])
    harness_source = harness.read_text()
    for marker in (
        "3_072",
        "ImageDecodeResourceEstimate.conservativeMaximum",
        ".encodedBytesExceeded",
        ".unsupportedFormat",
        ".dimensionLimitExceeded",
        ".pixelLimitExceeded",
    ):
        require(marker in harness_source, f"codec harness obligation marker missing: {marker}")
    require("import Fovea" not in harness_source, "codec harness must not import Fovea")
    for marker in ("CodecUnderTest", "release-qualified: false", "hostile corpus", "--codec-package-path"):
        require(marker in readme.read_text(), f"codec README marker missing: {marker}")
    return len(obligations)


def validate_matrix() -> None:
    matrix = object_document(MATRIX)
    require(matrix.get("schemaVersion") == 1, "current contract registry schemaVersion must be 1")
    contracts = matrix.get("contracts")
    require(isinstance(contracts, dict), "current contract registry contracts are required")
    provider = contracts.get("persistentStoreProvider")
    codec = contracts.get("codec")
    require(isinstance(provider, dict) and isinstance(codec, dict), "current contract registry entries are required")
    require(provider.get("contractVersion") == 1, "provider current contract contractVersion drifted")
    require(provider.get("kit") == "PersistentStoreProvider/v1/manifest.json", "provider current contract kit drifted")
    require(provider.get("currentStatus") == "self-hosted-independent-consumer-passed", "provider current contract status drifted")
    require(provider.get("releaseQualified") is False, "provider current contract must not claim release qualification")
    require(codec.get("contractVersion") == 1, "codec current contract contractVersion drifted")
    require(codec.get("currentRevision") == EXPECTED_IMAGECRAFT_REVISION, "codec current contract revision drifted")
    require(codec.get("kit") == "ImageCodec/v1/manifest.json", "codec current contract kit drifted")
    require(codec.get("currentStatus") == "self-hosted-independent-consumer-passed", "codec current contract status drifted")
    require(codec.get("releaseQualified") is False, "codec current contract must not claim release qualification")
    policy = matrix.get("policy")
    require(
        isinstance(policy, dict)
        and all(
            policy.get(key) is True
            for key in (
                "componentEvidenceDoesNotReplaceCompositionEvidence",
                "inconclusiveFailsClosed",
                "unsupportedFailsClosed",
            )
        ),
        "current contract registry fail-closed policy drifted",
    )


def main() -> int:
    try:
        require(MATRIX.is_file(), "current contract registry is missing")
        support_source = validate_shared_support()
        provider_count = validate_provider(support_source)
        codec_count = validate_codec(support_source)
        validate_matrix()
        print(
            "Cross-repository conformance kits valid: "
            f"provider-v1 obligations={provider_count} codec-v1 obligations={codec_count}"
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError, SyntaxError) as error:
        print(f"Cross-repository conformance kit validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
