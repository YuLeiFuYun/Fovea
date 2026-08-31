#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_ROOT = ROOT / ".artifacts/mutation"
LOG_ROOT = ARTIFACT_ROOT / "logs"
REPORT_PATH = ARTIFACT_ROOT / "critical-mutants.json"
GIT = next(
    str(candidate)
    for candidate in (
        Path("/Library/Developer/CommandLineTools/usr/bin/git"),
        Path("/usr/bin/git"),
    )
    if candidate.is_file() and os.access(candidate, os.X_OK)
)


@dataclasses.dataclass(frozen=True)
class Mutant:
    identifier: str
    description: str
    source_file: str
    test_filter: str
    apply: Callable[[Path], None]
    test_package: str | None = None
    prepare_test: Callable[[Path], None] | None = None
    test_root: str | None = None


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


COMPONENT_PREFIX = "component://"
COMPONENT_PINS = "docs/project-memory/component-pins.json"


def component_revisions(root: Path) -> dict[str, str]:
    document = json.loads((root / COMPONENT_PINS).read_text())
    components = document.get("components")
    if not isinstance(components, dict):
        raise RuntimeError("component pin registry has no components object")
    revisions: dict[str, str] = {}
    for name, component in components.items():
        if not isinstance(name, str) or not isinstance(component, dict):
            raise RuntimeError("component pin registry contains an invalid entry")
        revision = component.get("revision")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise RuntimeError(f"component {name} has no exact revision")
        revisions[name] = revision
    return revisions


def mutation_source(root: Path, reference: str) -> Path:
    if not reference.startswith(COMPONENT_PREFIX):
        path = (root / reference).resolve()
        path.relative_to(root.resolve())
        return path

    parsed = urlparse(reference)
    component = parsed.netloc
    relative = parsed.path.lstrip("/")
    if not component or not relative:
        raise RuntimeError(f"invalid component mutation source: {reference}")
    checkout = (root / ".build/checkouts" / component).resolve()
    path = (checkout / relative).resolve()
    path.relative_to(checkout)
    if not path.is_file():
        raise RuntimeError(f"component mutation source is missing: {reference}")
    path.chmod(path.stat().st_mode | stat.S_IWUSR)
    return path


def prepare_component_checkouts(
    root: Path,
    env: dict[str, str],
) -> dict[str, str]:
    revisions = component_revisions(root)
    completed = run(
        ["xcrun", "swift", "package", "resolve"],
        root,
        env,
        timeout=300,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"component resolution failed:\n{completed.stdout}")
    reset_component_checkouts(root, revisions)
    return revisions


def materialize_component_checkouts_for_validation(root: Path) -> dict[str, str]:
    revisions = component_revisions(root)
    checkout_root = root / ".build/checkouts"
    checkout_root.mkdir(parents=True, exist_ok=True)
    for name, revision in revisions.items():
        source = ROOT / ".build/checkouts" / name
        destination = checkout_root / name
        if not source.is_dir():
            raise RuntimeError(f"local exact component checkout is unavailable: {name}")
        observed = command_output([GIT, "rev-parse", "HEAD"], source)
        if observed != revision:
            raise RuntimeError(
                f"local component checkout revision mismatch for {name}: "
                f"expected={revision} observed={observed}"
            )
        subprocess.run(
            [GIT, "clone", "--quiet", "--no-hardlinks", str(source), str(destination)],
            cwd=root,
            check=True,
        )
        subprocess.run(
            [GIT, "checkout", "--detach", revision],
            cwd=destination,
            check=True,
            stdout=subprocess.DEVNULL,
        )
    reset_component_checkouts(root, revisions)
    return revisions


def reset_component_checkouts(root: Path, revisions: dict[str, str]) -> None:
    for name, revision in revisions.items():
        checkout = root / ".build/checkouts" / name
        if not checkout.is_dir():
            raise RuntimeError(f"component checkout missing after resolution: {name}")
        observed = command_output([GIT, "rev-parse", "HEAD"], checkout)
        if observed != revision:
            raise RuntimeError(
                f"component checkout revision mismatch for {name}: "
                f"expected={revision} observed={observed}"
            )
        subprocess.run(
            [GIT, "reset", "--hard", revision],
            cwd=checkout,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [GIT, "clean", "-fdx"],
            cwd=checkout,
            check=True,
            stdout=subprocess.DEVNULL,
        )


def flexible_leading_whitespace_pattern(literal: str) -> str:
    """构造只忽略每行前导空白的正则；行内空白和换行仍保持精确。"""
    pieces: list[str] = []
    for line in literal.splitlines(keepends=True):
        newline = ""
        content = line
        if line.endswith("\r\n"):
            content = line[:-2]
            newline = r"\r?\n"
        elif line.endswith("\n"):
            content = line[:-1]
            newline = r"\n"
        match = re.match(r"^[ \t]*", content)
        assert match is not None
        leading = match.group(0)
        remainder = content[len(leading):]
        if leading:
            pieces.append(r"[ \t]*" + re.escape(remainder) + newline)
        else:
            pieces.append(re.escape(content) + newline)
    return "".join(pieces)


def replace_literal_flexible(
    text: str,
    old: str,
    new: str,
    *,
    expected_count: int,
    context: str,
) -> str:
    exact_count = text.count(old)
    if exact_count == expected_count:
        return text.replace(old, new)
    if exact_count != 0:
        raise RuntimeError(
            f"{context}: expected {expected_count} occurrence(s), found {exact_count} "
            "for literal mutation"
        )
    pattern = flexible_leading_whitespace_pattern(old)
    updated, count = re.subn(pattern, lambda _: new, text, flags=re.MULTILINE)
    if count != expected_count:
        raise RuntimeError(
            f"{context}: expected {expected_count} occurrence(s), found {count} "
            "for indentation-insensitive literal mutation"
        )
    return updated


def flexible_span(text: str, literal: str, start: int = 0) -> tuple[int, int] | None:
    pattern = re.compile(flexible_leading_whitespace_pattern(literal), re.MULTILINE)
    match = pattern.search(text, start)
    if match is None:
        return None
    return match.span()


def replace_literal(
    path: Path,
    old: str,
    new: str,
    *,
    expected_count: int = 1,
) -> None:
    text = path.read_text()
    path.write_text(
        replace_literal_flexible(
            text,
            old,
            new,
            expected_count=expected_count,
            context=str(path),
        )
    )


def replace_regex(
    path: Path,
    pattern: str,
    replacement: str,
    *,
    expected_count: int = 1,
    flags: int = 0,
) -> None:
    text = path.read_text()
    updated, count = re.subn(pattern, replacement, text, flags=flags)
    if count != expected_count:
        raise RuntimeError(
            f"{path}: expected {expected_count} occurrence(s), found {count} for regex {pattern!r}"
        )
    path.write_text(updated)


def section(path: Path, start: str, end: str) -> tuple[str, str, str]:
    text = path.read_text()
    start_index = text.find(start)
    start_length = len(start)
    if start_index < 0:
        span = flexible_span(text, start)
        if span is None:
            raise RuntimeError(f"{path}: section start not found: {start!r}")
        start_index, start_end = span
        start_length = start_end - start_index
    end_index = text.find(end, start_index + start_length)
    if end_index < 0:
        span = flexible_span(text, end, start_index + start_length)
        if span is None:
            raise RuntimeError(f"{path}: section end not found: {end!r}")
        end_index = span[0]
    return text[:start_index], text[start_index:end_index], text[end_index:]


def replace_in_section(
    path: Path,
    start: str,
    end: str,
    old: str,
    new: str,
    *,
    expected_count: int = 1,
) -> None:
    prefix, body, suffix = section(path, start, end)
    updated = replace_literal_flexible(
        body,
        old,
        new,
        expected_count=expected_count,
        context=f"{path} section {start!r}",
    )
    path.write_text(prefix + updated + suffix)


def regex_in_section(
    path: Path,
    start: str,
    end: str,
    pattern: str,
    replacement: str,
    *,
    expected_count: int = 1,
    flags: int = 0,
) -> None:
    prefix, body, suffix = section(path, start, end)
    updated, count = re.subn(pattern, replacement, body, flags=flags)
    if count != expected_count:
        raise RuntimeError(
            f"{path}: expected {expected_count} occurrence(s), found {count} in section {start!r}"
        )
    path.write_text(prefix + updated + suffix)


def mutant_001(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/Identity.swift",
        "public struct FetchBaseKey",
        "public struct FetchVariantKey",
        "    encoder.append(namespace.value)\n",
        "    // AIQA-MUT-001：故意省略命名空间。\n",
    )


def mutant_002(root: Path) -> None:
    path = root / "Sources/FoveaCore/ImageRequest.swift"
    replace_in_section(
        path,
        "package func fetchExecutionKey(",
        "package var renderAliasIdentity",
        "      selectedVariantDigest: selectedVariant?.digestHex,\n",
        "      selectedVariantDigest: nil,\n",
    )
    replace_in_section(
        path,
        "package func fetchExecutionKey(",
        "package var renderAliasIdentity",
        "      revalidationFingerprint: revalidationFingerprint,\n",
        '      revalidationFingerprint: "variant-only",\n',
    )


def mutant_003(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/Identity.swift",
        "public struct FetchExecutionKey",
        "public struct ContentID",
        "    encoder.appendOptional(credentialGeneration?.value)\n",
        "    encoder.appendOptional(Optional<UInt64>.none)\n",
    )


def mutant_004(root: Path) -> None:
    replace_regex(
        root / "Sources/FoveaHTTP/RepresentationRecord.swift",
        r"public func isFresh\(at date: Date\) -> Bool \{\n(?:.|\n)*?\n[ \t]+\}",
        "public func isFresh(at date: Date) -> Bool { true }",
        flags=re.MULTILINE,
    )


def mutant_005(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/HTTPImageResponseProcessor.swift",
        "      contentID: existing.contentID,\n",
        '      contentID: "sha256:" + String(repeating: "0", count: 64) + ":\\(existing.payloadLength)",\n',
    )


def mutant_006(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/HTTPCachePolicy.swift",
        "        return current == record.vary\n",
        "        return current.fieldNames == record.vary.fieldNames\n",
    )


def mutant_007(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/HTTPImageResponseProcessor.swift",
        "    let allowsReusableState = allowReusableState && prepared.disposition != .noStore\n",
        "    let allowsReusableState = allowReusableState\n",
    )


def mutant_008(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "        guard await namespaceRegistry.isActive(generation, for: namespace) else {\n",
        "        guard true else {\n",
    )


def mutant_009(root: Path) -> None:
    replace_literal(
        mutation_source(root, "component://ImageCraft/Sources/ImageCraftCore/ImageTypes.swift"),
        "    guard width > 0, height > 0 else { throw ImageCraftError.invalidTarget }\n",
        "    guard width >= 0, height >= 0 else { throw ImageCraftError.invalidTarget }\n",
    )


def mutant_010(root: Path) -> None:
    replace_literal(
        mutation_source(root, "component://ImageCraft/Sources/ImageCraftImageIO/ImageIOImageDecoder.swift"),
        "CGImageSourceCreateThumbnailAtIndex",
        "CGImageSourceCreateImageAtIndex",
    )


def mutant_011(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "  package func release(\n",
        "  package func subscriberCount",
        """      let effective = Self.effectivePriority(entry.subscribers)
      await entry.priorityControl.update(effective)
""",
        "      // AIQA-MUT-011: deliberately keep the stale elevated priority.\n",
    )

def mutant_012(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "    package func completed(key: Key, taskID: UUID) async",
        "    private static func effectivePriority(",
        "        guard var entry = entries[key], entry.taskID == taskID else { return }\n",
        "        guard var entry = entries[key] else { return }\n",
    )


def mutant_013(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/Identity.swift",
        "public struct FetchBaseKey",
        "public struct FetchVariantKey",
        "  public var digestHex: String { canonicalBytes.sha256Hex }\n",
        """  public var digestHex: String {
    let unstable = UInt64(UInt(bitPattern: canonicalBytes.hashValue))
    return String(format: "%064llx", unstable)
  }
""",
    )


def mutant_014(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/ImageRequestValidation.swift",
        "  package static func normalizedHTTPURL(",
        "  package static func validateIdentityComponent(",
        "    components.fragment = nil\n",
        "    components.fragment = nil\n    components.query = nil\n",
    )

def mutant_015(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/ImageDeliveryCoordinator.swift",
        "  private func sharedTransform(",
        "  private func subscriptionValue(",
        "      let image = try await transformStage.image(from: decoded)\n",
        """      await cache.insertRendered(decoded, for: renderKey)
      let image = try await transformStage.image(from: decoded)
""",
    )


def mutant_016(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/PipelineCache+Persistence.swift",
        "        if createdBlob {\n",
        "        if false && createdBlob {\n",
    )


def mutant_017(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/HTTPImageResponseProcessor.swift",
        "    private func reusableRecord(",
        "    private func cached304Body(",
        "            namespaceGeneration: generation.value,\n",
        "            namespaceGeneration: 0,\n",
    )


def mutant_018(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "    func refresh(",
        "    private func rollbackRefresh(",
        "            try await requireActive(generation, for: namespace)\n",
        "            // AIQA-MUT-018: deliberately ignore namespace revocation after refresh publication.\n",
    )


def mutant_019(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache+Persistence.swift",
        "    private func rollback(",
        "}\n",
        "        if recordMutationAttempted {\n",
        "        if false && recordMutationAttempted {\n",
    )


def mutant_020(root: Path) -> None:
    path = root / "Sources/FoveaCore/ImageDeliveryCoordinator.swift"
    replace_literal(
        path,
        "request.renderCacheAdmission == .stable",
        "true",
        expected_count=1,
    )


def mutant_021(root: Path) -> None:
    replace_literal(
        mutation_source(root, "component://ImageCraft/Sources/ImageCraftCore/ImageTypes.swift"),
        "    self.maximumMetadataBytes = min(\n      Self.maximumSupportedMetadataBytes,\n      max(0, maximumMetadataBytes)\n    )\n",
        "    self.maximumMetadataBytes = Int.max\n",
    )


def mutant_022(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/DecodeStage.swift",
        "    let subscription = await registry.subscribe(\n",
        "    let subscription = await SharedTaskRegistry<ScopedDecodeKey, DecodedImage>().subscribe(\n",
    )


def mutant_023(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "    private func rollbackRefresh(",
        "    func cleanup(",
        "            if restoreOverwrittenRecord,\n",
        "            if false,\n",
    )


def mutant_024(root: Path) -> None:
    replace_literal(
        mutation_source(root, "component://Akashic/Sources/AkashicMemory/MemoryCache.swift"),
        "    let maximumExistingCost = costLimit - cost\n",
        "    let maximumExistingCost = costLimit\n",
    )


def mutant_025(root: Path) -> None:
    replace_regex(
        mutation_source(root, "component://Akashic/Sources/AkashicDisk/FileBlobStoreMaintenance.swift"),
        r"    func isValidManifest\(_ manifest: Manifest\) -> Bool \{(?:.|\n)*?\n    \}\n\n    func recordAccess",
        "    func isValidManifest(_ manifest: Manifest) -> Bool {\n        true\n    }\n\n    func recordAccess",
        flags=re.MULTILINE,
    )


def mutant_026(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaPersistence/RepresentationRecordStore.swift",
        "  private func bootstrap(root: URL) throws",
        "  package func records(",
        "        manifest.records.allSatisfy({ key, record in\n          record.isValidPersistentRecord(storedUnder: key)\n        })\n",
        "        true\n",
    )

def mutant_027(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaPersistence/RepresentationRecordStore.swift",
        "  package func put(_ record: RepresentationRecord) throws",
        "  package func containsReference(",
        "    guard record.isValidPersistentRecord(storedUnder: record.variantKeyDigest) else {\n",
        "    guard true else {\n",
    )

def mutant_028(root: Path) -> None:
    replace_regex(
        root / "Sources/FoveaHTTP/URLSessionTransport.swift",
        r"[ \t]+private static func expectedIdentityContentLength\(\n[ \t]+from response: HTTPURLResponse\n[ \t]+\) throws -> Int\? \{\n(?:.|\n)*?\n[ \t]+\}\n\n[ \t]+package static func responseHead",
        "  private static func expectedIdentityContentLength(\n    from response: HTTPURLResponse\n  ) throws -> Int? {\n    guard let raw = response.value(forHTTPHeaderField: \"Content-Length\") else { return nil }\n    return Int(raw)\n  }\n\n  package static func responseHead",
        flags=re.MULTILINE,
    )


def mutant_029(root: Path) -> None:
    replace_regex(
        root / "Sources/FoveaPersistence/AkashicOriginalEncodedStore.swift",
        r"    private static func digest\(_ contentID: String\) throws -> BlobDigest \{(?:.|\n)*?\n    \}",
        r'''    private static func digest(_ contentID: String) throws -> BlobDigest {
        let parts = contentID.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 3, let count = Int(parts[2]) {
            return try BlobDigest(canonicalString: "\(parts[0]):\(parts[1]):\(count)")
        }
        return try BlobDigest(canonicalString: contentID)
    }''',
        flags=re.MULTILINE,
    )


def mutant_030(root: Path) -> None:
    replace_in_section(
        mutation_source(root, "component://Akashic/Sources/AkashicCore/StorageDirectorySecurity.swift"),
        "    package static func validateOpenedPrivateRegularFile(",
        "    package static func validateOpenedDirectory(",
        "            status.st_nlink == 1,\n",
        "            true,\n",
    )


def write_component_contract_test(
    root: Path, component: str, filename: str, source: str
) -> None:
    checkout = (root / ".build/checkouts" / component).resolve()
    target = (checkout / "Tests/AkashicCoreTests" / filename).resolve()
    target.relative_to(checkout)
    if target.exists():
        raise RuntimeError(f"component contract test collision: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(source)


def prepare_mutant_031_test(root: Path) -> None:
    write_component_contract_test(
        root,
        "Akashic",
        "FoveaMutationDirectoryContractTests.swift",
        """import Foundation
import XCTest
@testable import AkashicCore

final class FoveaMutationDirectoryContractTests: XCTestCase {
    func testManagedDirectoryValidationRejectsSymbolicLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-mutant-directory-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: target.path
        )
        let link = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try StorageDirectorySecurity.validateDirectory(link))
    }
}
""",
    )


def mutant_031(root: Path) -> None:
    replace_in_section(
        mutation_source(root, "component://Akashic/Sources/AkashicCore/StorageDirectorySecurity.swift"),
        "    private static func fileStatusWithoutFollowingLinks(at url: URL) throws -> stat {",
        "    private static func excludeFromBackup(",
        "        let result = url.path.withCString { Darwin.lstat($0, &status) }\n",
        "        let result = url.path.withCString { Darwin.fstatat(AT_FDCWD, $0, &status, 0) }\n",
    )


def prepare_mutant_032_test(root: Path) -> None:
    write_component_contract_test(
        root,
        "Akashic",
        "FoveaMutationBoundedReaderContractTests.swift",
        """import Foundation
import XCTest
@testable import AkashicCore

final class FoveaMutationBoundedReaderContractTests: XCTestCase {
    func testBoundedFileReaderRejectsOversizeBeforeAllocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-mutant-bounded-reader-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("metadata.bin")
        try Data([0x41, 0x42]).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: file.path
        )

        XCTAssertThrowsError(try BoundedFileReader.read(from: file, maximumBytes: 1))
    }
}
""",
    )


def mutant_032(root: Path) -> None:
    replace_literal(
        mutation_source(root, "component://Akashic/Sources/AkashicCore/BoundedFileReader.swift"),
        "      UInt64(status.st_size) <= UInt64(maximumBytes),\n",
        "      true,\n",
    )


def mutant_033(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/RepresentationRecord.swift",
        "      responseTime.timeIntervalSinceReferenceDate.isFinite,\n",
        "      responseTime.timeIntervalSinceReferenceDate.isFinite,\n      responseTime >= requestTime,\n",
    )

def mutant_034(root: Path) -> None:
    path = root / "Sources/FoveaCore/ImageRequest.swift"
    replace_literal(
        path,
        '                "\\(credentialExecutionFingerprint)|\\(networkPolicy.executionFingerprint)|request-default-v1"\n',
        '                "\\(credentialExecutionFingerprint)|request-default-v1"\n',
    )
    replace_literal(
        path,
        '                "\\(cachedCredentialExecutionFingerprint)|\\(networkPolicy.executionFingerprint)|\\(transportPolicyFingerprint)"\n',
        '                "\\(cachedCredentialExecutionFingerprint)|\\(transportPolicyFingerprint)"\n',
    )


def mutant_035(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FoveaPipeline+Operations.swift",
        "    package func validateAccess(",
        "    package func validateAuthorization(",
        "        guard profileAccessPolicy.permits(request) else {\n",
        "        guard true else {\n",
    )


def mutant_036(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/ImageRequest+Credentials.swift",
        "  package func replacingCredentials(",
        "  }\n}",
        "      networkPolicy: networkPolicy,\n",
        "      networkPolicy: .interactive,\n",
    )

def mutant_037(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FoveaDecodePermitController.swift",
        "    private func acquireWorkingSetPermit(",
        "    private func withDecodePermits<Result>(",
        "                units: bytes,\n",
        "                units: 1,\n",
    )


def mutant_038(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/URLSessionTransport.swift",
        "  private func consume(",
        "  private func makeResponse(",
        "      case .metrics(let metrics):\n        networkMetrics = metrics\n",
        "      case .metrics:\n        networkMetrics = nil\n",
    )


def mutant_039(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/AsyncPermitPool.swift",
        "            defer { await pool.release(identifier) }\n            return try await operation()\n",
        "            var completed = false\n            defer {\n                if completed { await pool.release(identifier) }\n            }\n            let result = try await operation()\n            completed = true\n            return result\n",
    )


def mutant_040(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/HTTPURLSecurityPolicy.swift",
        '    return scheme == "http" && isLoopbackHost(host)\n',
        '    return scheme == "http" && (isLoopbackHost(host) || host.count > 0)\n',
    )


def mutant_041(root: Path) -> None:
    path = root / "Sources/FoveaHTTP/HTTPRedirectPolicy.swift"
    replace_in_section(
        path,
        "  package static func request(",
        "  }\n}",
        "    guard let url = proposed.url, HTTPURLSecurityPolicy.permits(url) else {\n",
        "    guard let url = proposed.url else {\n",
    )
    replace_in_section(
        path,
        "  package static func request(",
        "  }\n}",
        "    guard destinationPolicy.permits(url) else {\n      throw TransportError.destinationDisallowed\n    }\n",
        "    // AIQA-MUT-041: allow remote cleartext redirect destinations.\n",
    )

def mutant_042(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/PipelineConfiguration.swift",
        r'      "maximumDecodeWorkingSetBytes:\(maximumDecodeWorkingSetBytes)",' + "\n",
        "",
    )


def mutant_043(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaSystem/FoveaSystemPipeline.swift",
        "    public static func open(",
        "    package static func openQualified(",
        "        profileAccessPolicy: ProfileAccessPolicy = .publicOnly,\n",
        "        profileAccessPolicy: ProfileAccessPolicy = .unrestricted,\n",
    )


def mutant_044(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "    let task = Task { @concurrent [weak self] in",
        "    entries[key] = Entry(",
        "        await self?.completed(key: key, taskID: taskID)\n        return value\n",
        "        return value\n",
    )


def mutant_045(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FetchRetryController.swift",
        "  func schedule(",
        "  private func retryDelay(",
        "      if error is CancellationError || Task.isCancelled {\n",
        "      if false {\n",
    )


def mutant_046(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/URLSessionTransport.swift",
        "    configuration.urlCredentialStorage = nil\n",
        "    // AIQA-MUT-046: preserve ambient credential storage.\n",
    )


def mutant_047(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        """            await self?.expireOrphanedTask(
                key: key,
                taskID: taskID,
                leaseID: leaseID
            )
""",
        "            // AIQA-MUT-047: leave the zero-subscriber task registered forever.\n",
    )

def mutant_048(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/URLSessionTransportPolicy.swift",
        "  package func validate(_ metrics: TransportNetworkMetrics?) throws {",
        "  }\n}",
        "    guard self == .requireNoProxyInTaskMetrics else { return }\n",
        "    return\n",
    )


def mutant_049(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/ImageRequestValidation.swift",
        "  package static let maximumNamespaceBytes = 4 * 1024\n",
        "  package static let maximumNamespaceBytes = Int.max\n",
    )


def mutant_050(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/NamespaceRegistry.swift",
        "  private func startAdvance(",
        "  /// 释放一个撤销清理 lease。",
        """    guard state.generation.value < UInt64.max else {
      var exhausted = state
      exhausted.isExhausted = true
      states[fingerprint] = exhausted
      return exhausted.generation
    }

    let next = NamespaceGeneration(state.generation.value + 1)
""",
        "    let next = NamespaceGeneration(state.generation.value &+ 1)\n",
    )


def mutant_051(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/URLSessionTransport.swift",
        "  public func execute(_ request: TransportRequest) async throws -> TransportResponse {",
        "    let accumulator = try BoundedStagingAccumulator(",
        "    guard let url = request.request.url, destinationPolicy.permits(url) else {\n      throw TransportError.destinationDisallowed\n    }\n",
        "    // AIQA-MUT-051: skip initial destination validation.\n",
    )


def mutant_052(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPRedirectPolicy.swift",
        "  package static func request(",
        "    return CredentialHeaderPolicy.sanitizedRedirectRequest(",
        "    guard destinationPolicy.permits(url) else {\n      throw TransportError.destinationDisallowed\n    }\n",
        "    // AIQA-MUT-052: allow redirect outside the destination policy.\n",
    )


def mutant_053(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/ProfileAccessPolicy.swift",
        "  package func permits(_ request: ImageRequest) -> Bool {",
        "    switch rule {",
        "    guard destinationPolicy.permits(request.url) else { return false }\n",
        "    // AIQA-MUT-053: bypass destination ACL before cache lookup.\n",
    )


def mutant_054(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/URLSessionTransportPolicy.swift",
        r'      "destination:\(destinationPolicy.executionFingerprint)",' + "\n",
        "",
    )


def mutant_055(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/NamespaceRegistry.swift",
        "    guard states.count < maximumTrackedNamespaces else {\n",
        "    guard true else {\n",
    )


def mutant_056(root: Path) -> None:
    path = root / "Sources/FoveaPersistence/FoveaPersistentStores.swift"
    for declaration in (
        "encoded: AkashicOriginalEncodedStore?",
        "records: RepresentationRecordStore?",
        "namespaceGenerations: NamespaceGenerationStore?",
        "lifetime: PersistentStoreLifetime?",
    ):
        replace_literal(path, f"  weak let {declaration}\n", f"  let {declaration}\n")


def mutant_057(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "  package init(recordsCancellationCounts: Bool = false) {\n",
        "  package init(recordsCancellationCounts: Bool = true) {\n",
    )


def mutant_058(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaObservability/OSLogDiagnosticsSink.swift",
        "    if activeIntervalCount() >= configuration.maximumActiveIntervals {\n",
        "    if active.count >= configuration.maximumActiveIntervals {\n",
    )


def mutant_059(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/CredentialRefreshing.swift",
        "    while latestResults.count > policy.maximumRememberedScopes,\n",
        "    while latestResults.count < policy.maximumRememberedScopes,\n",
    )


def mutant_060(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FetchStageDiagnostics.swift",
        "    func recordCompleted(",
        "/// Owns the subscriber-side lifecycle for a shared fetch",
        "                redirectCount: network?.redirectCount,\n",
        "                redirectCount: nil,\n",
    )


def mutant_061(root: Path) -> None:
    replace_in_section(
        mutation_source(root, "component://Akashic/Sources/AkashicDisk/FileBlobStoreIdentity.swift"),
        "    static func isInvalidBlobPath(",
        "    }\n}",
        "        default:\n            return false\n",
        "        default:\n            return true\n",
    )


def mutant_062(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaPersistence/FoveaPersistentStores.swift",
        "    pruneReleasedEntries()\n",
        "    // AIQA-MUT-062: retain expired weak registry metadata forever.\n",
        expected_count=2,
    )


def mutant_063(root: Path) -> None:
    replace_regex(
        root / "Sources/FoveaCore/CredentialRefreshing.swift",
        r"(?m)^[ \t]+guard !Task\.isCancelled else \{\n[ \t]+throw PipelineFailure\.cancelled\(stage: \.requestValidation\)\n[ \t]+\}\n",
        "    // AIQA-MUT-063: allow cancelled callers to continue through credential replay.\n",
        expected_count=3,
    )


def mutant_064(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/NamespaceRegistry.swift",
        "      guard !existing.isExhausted, existing.activeRevocations == 0 else {\n",
        "      guard !existing.isExhausted, true else {\n",
    )


def mutant_065(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaSystem/FoveaSystemPipeline.swift",
        "        if let monitor { await pipeline.retainLifetimeAnchor(monitor) }\n",
        "        // AIQA-MUT-065: drop the monitor when the wrapper is released.\n",
    )


def mutant_066(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/Diagnostics.swift",
        "    self.reason = Self.sanitizedReasonCode(reason)\n",
        "    self.reason = reason\n",
    )


def mutant_067(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FoveaPipeline+Operations.swift",
        "    public func purgeMemoryCache() async -> Int {",
        "    /// Comparative-Lab-only full in-memory cache reset.",
        "                byteCount: removed.costBytes,\n",
        "                byteCount: removed.itemCount,\n",
    )

def mutant_068(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/Diagnostics.swift",
        "    guard schemaVersion == Self.currentSchemaVersion else {\n",
        "    guard true else {\n",
    )


def mutant_069(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/DiagnosticsSink.swift",
        "      itemCount: droppedSinceLastReport,\n",
        "      byteCount: droppedSinceLastReport,\n",
    )


def mutant_070(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineFailure.swift",
        "  private static func sanitizedReasonCode(",
        "\n}\n",
        "      return \"invalid-reason-code\"\n",
        "      return reasonCode\n",
    )


def mutant_071(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/HTTPMetadataLimits.swift",
        "  package static let maximumHeaderCount = 64\n",
        "  package static let maximumHeaderCount = Int.max\n",
    )


def mutant_072(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/RepresentationRecord.swift",
        "      Self.isValidOptionalField(etag),\n",
        "      true,\n",
    )

def mutant_073(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaPersistence/RepresentationRecordStore.swift",
        "    if let oldRecord {\n",
        "    if false, let oldRecord {\n",
    )


def mutant_074(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaSwiftUI/FoveaImageModels.swift",
        "      force: force || tokenForcesReload\n",
        "      force: force\n",
    )


def mutant_075(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaSwiftUI/FoveaImagePhaseContent.swift",
        "        .aspectRatio(contentMode: swiftUIContentMode)\n",
        "        .aspectRatio(contentMode: .fill)\n",
        expected_count=2,
    )


def mutant_076(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/URLSessionEventRouter.swift",
        "          continuation.resume(\n            returning: routes[taskID].map { route in\n              URLSessionRedirectContext(\n                credentialHeaderNames: route.credentialHeaderNames,\n                destinationPolicy: route.destinationPolicy\n              )\n            }\n          )\n",
        "          continuation.resume(\n            returning: routes[taskID].map { route in\n              URLSessionRedirectContext(\n                credentialHeaderNames: route.credentialHeaderNames,\n                destinationPolicy: route.destinationPolicy\n              )\n            } ?? URLSessionRedirectContext(\n              credentialHeaderNames: [],\n              destinationPolicy: .secureDefault\n            )\n          )\n",
    )

def mutant_077(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPTypes.swift",
        "  public init(head: TransportResponseHead, body: Data, metrics: TransportMetrics)",
        "    init(\n        head: TransportResponseHead,",
        "      receivedBytes: body.count,\n",
        "      receivedBytes: metrics.receivedBytes,\n",
    )


def mutant_078(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/FetchStage.swift",
        """                guard transportResponse.bodyByteCount <= configuration.maximumTransportBytes else {
                    throw TransportError.bodyTooLarge
                }
""",
        """                if false {
                    throw TransportError.bodyTooLarge
                }
""",
    )

def mutant_079(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/TransformStage.swift",
        "      try validate(image)\n",
        "      // AIQA-MUT-079: skip transform output admission.\n",
    )


def mutant_080(root: Path) -> None:
    replace_in_section(
        mutation_source(root, "component://Akashic/Sources/AkashicDisk/FileBlobStoreMaintenance.swift"),
        "        guard !victims.isEmpty else {",
        "        var next = manifest",
        "            let removed = try removeUnreferencedBlobFiles()\n"
        "            return try BlobMaintenanceResult(\n"
        "                removedBlobCount: removed.fileCount,\n"
        "                removedByteCount: removed.byteCount\n"
        "            )\n",
        "            return try BlobMaintenanceResult(removedBlobCount: 0, removedByteCount: 0)\n",
    )


def mutant_081(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/AsyncPermitPool.swift",
        "  private func nextSequenceValue() -> UInt64 {",
        "  private func updatePriority(",
        "  private func nextSequenceValue() -> UInt64 {\n    if nextSequence == UInt64.max {\n      let ordered = waiters.sorted { lhs, rhs in\n        lhs.value.sequence < rhs.value.sequence\n      }\n      for (index, element) in ordered.enumerated() {\n        var waiter = element.value\n        waiter.sequence = UInt64(index + 1)\n        waiters[element.key] = waiter\n      }\n      nextSequence = UInt64(ordered.count)\n    }\n    nextSequence += 1\n    return nextSequence\n  }\n\n",
        "  private func nextSequenceValue() -> UInt64 {\n    nextSequence &+= 1\n    return nextSequence\n  }\n\n",
    )


def mutant_082(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPTypes.swift",
        "  public static func reusable(contextIdentifier: String)",
        "  public var allowsCrossRequestReuse",
        "    guard !bytes.isEmpty, bytes.count <= maximumContextIdentifierBytes,\n      normalized.unicodeScalars.allSatisfy({ scalar in\n        scalar.value >= 0x20 && scalar.value != 0x7f\n      })\n    else { return .taskLocal }\n",
        "    guard !bytes.isEmpty else { return .taskLocal }\n",
    )


def mutant_083(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPTypes.swift",
        "  public init(\n    request: URLRequest,",
        "  package init(\n    request: URLRequest,",
        "    self.credentialHeaderNames = try Self.normalizedCredentialHeaderNames(credentialHeaderNames)\n",
        "    self.credentialHeaderNames = Set(credentialHeaderNames.map { $0.lowercased() })\n",
    )


def mutant_084(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPTypes.swift",
        "  public init(statusCode: Int, headers: [String: String], url: URL?) throws",
        "  public func value(forHeader name: String)",
        "        HTTPURLSecurityPolicy.permits(url),\n",
        "        true,\n",
    )


def mutant_085(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPCachePolicy.swift",
        "  private static func deltaSeconds(_ raw: String)",
        "  private static func splitHTTPList(",
        "    guard !value.isEmpty,\n      value.utf8.allSatisfy({ (48...57).contains($0) }),\n      let seconds = UInt64(value)\n    else { return nil }\n    return TimeInterval(seconds)\n",
        "    guard let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 else { return nil }\n    return seconds\n",
    )


def mutant_086(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPCachePolicy.swift",
        "  private static func maxAge(in directives: [CacheControlDirective])",
        "  private static func deltaSeconds(",
        "    guard values.count == 1,\n      let raw = values[0].value,\n      let seconds = deltaSeconds(raw)\n    else { return .invalid }\n",
        "    guard let raw = values.first?.value, let seconds = deltaSeconds(raw) else { return .invalid }\n",
    )


def mutant_087(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/StaleFallbackPolicy.swift",
        "      !record.requiresRevalidation,\n",
        "      true,\n",
    )


def mutant_088(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/EncodedDataCoordinator.swift",
        "  private func cachedData(",
        "  private func validatedBody(",
        """    } catch is CancellationError {
      throw CancellationError()
""",
        """    } catch is CancellationError {
      await cache.removeRecord(
        record.variantKeyDigest,
        namespace: request.namespace,
        generation: generation
      )
      throw CancellationError()
""",
    )


def mutant_089(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "        record.securityNamespaceFingerprint == namespaceFingerprint,\n",
        "        true,\n",
    )


def mutant_090(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "        guard existing == record else {\n",
        "        guard true else {\n",
    )


def mutant_091(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/DecodeStage.swift",
        "            try timed.plan.probe.validateForFovea(under: limits)\n",
        "            // AIQA-MUT-091: trust the custom decoder probe.\n",
    )

def mutant_092(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FetchRetryController.swift",
        "  func schedule(",
        "  private func retryDelay(",
        "        failure = .internalFailure(stage: .transport)\n",
        "        failure = .cancelled(stage: .transport)\n",
    )


def mutant_093(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "        for entry in entries.values { entry.task.cancel() }\n",
        "        // AIQA-MUT-093: detached orphan tasks survive registry destruction.\n",
    )

def mutant_094(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaObservability/OSLogDiagnosticsSink.swift",
        "  private func nextIntervalSequenceValue() -> UInt64 {",
        "  private func rebaseActiveIntervalSequences()",
        "  private func nextIntervalSequenceValue() -> UInt64 {\n    if nextIntervalSequence == UInt64.max {\n      rebaseActiveIntervalSequences()\n    }\n    nextIntervalSequence += 1\n    return nextIntervalSequence\n  }\n\n",
        "  private func nextIntervalSequenceValue() -> UInt64 {\n    nextIntervalSequence = nextIntervalSequence == UInt64.max ? 1 : nextIntervalSequence + 1\n    return nextIntervalSequence\n  }\n\n",
    )


def mutant_095(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/StagingDirectoryLease.swift",
        "      guard !activePaths.contains(path) else { continue }\n",
        "      guard true else { continue }\n",
    )


def mutant_096(root: Path) -> None:
    replace_literal(
        mutation_source(root, "component://ImageCraft/Sources/ImageCraftImageIO/ImageIOImageDecoder.swift"),
        "    else { return Int.max }\n",
        "    else { return 0 }\n",
    )


def mutant_097(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/CredentialRefreshing.swift",
        "extension RefreshingImageLoader: NamespaceRevoking where Base: NamespaceRevoking {",
        "}\n",
        "    await coordinator.invalidate(namespace: namespace)\n",
        "    // AIQA-MUT-097: leave remembered refreshed credentials alive during logout.\n",
    )

def mutant_098(root: Path) -> None:
    replace_in_section(
        mutation_source(root, "component://Akashic/Sources/AkashicDisk/FileBlobStoreMaintenance.swift"),
        "        guard !victims.isEmpty else {",
        "        var next = manifest",
        "                removedBlobCount: removed.fileCount,\n"
        "                removedByteCount: removed.byteCount\n",
        "                removedBlobCount: 0,\n"
        "                removedByteCount: 0\n",
    )


def mutant_099(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaStorage/StorageTypes.swift",
        "    guard StoredContentIdentifier.byteCount(in: contentID) != nil else {\n",
        "    guard true else {\n",
    )


def mutant_100(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/NamespaceRegistry.swift",
        "  package func beginRevocation(",
        "  package func finishRevocation(",
        "        try await persistence.persist(next.value, for: fingerprint)\n",
        "        // AIQA-MUT-100: publish the in-memory generation without durable state.\n",
    )


def mutant_101(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/CredentialHeaderPolicy.swift",
        "    return components.contains(where: sensitiveNameComponents.contains)\n",
        "    return false\n",
    )


def mutant_102(root: Path) -> None:
    replace_literal(
        root
        / "Benchmarks/ComparativeLab/Adapters/FoveaAdapterPackage/Sources/"
        "FoveaComparatorAdapter/FoveaComparatorAdapter.swift",
        "        let benchmarkRequestID = semanticHeaders.removeValue(forKey: benchmarkRequestIDHeader)\n",
        "        // AIQA-MUT-102: keep telemetry in semantic headers so it perturbs cache/single-flight identity.\n"
        "        let benchmarkRequestID: String? = nil\n",
    )


MUTANTS = [
    Mutant("AIQA-MUT-001", "Omit namespace from persistent base identity.", "Sources/FoveaCore/Identity.swift", "IdentityTests/testNamespaceChangesBaseAndVariantIdentity_CACHE_PT_003", mutant_001),
    Mutant("AIQA-MUT-002", "Collapse exact fetch execution identity to base-only dimensions.", "Sources/FoveaCore/ImageRequest.swift", "IdentityTests/testImageRequestExecutionKeyIncludesCredentialAndRevalidation", mutant_002),
    Mutant("AIQA-MUT-003", "Ignore credential generation in exact execution identity.", "Sources/FoveaCore/Identity.swift", "IdentityTests/testCredentialRefreshChangesExecutionButNotBaseOrVariant_AUTH_PT_001", mutant_003),
    Mutant("AIQA-MUT-004", "Treat every persistent representation as fresh.", "Sources/FoveaHTTP/RepresentationRecord.swift", "PipelineTests/testInjectedClockControlsFreshnessWithoutSleeping", mutant_004),
    Mutant("AIQA-MUT-005", "Replace the validated 304 content identity.", "Sources/FoveaCore/HTTPImageResponseProcessor.swift", "PipelineTests/test304ReusesContentID_CACHE_PT_008", mutant_005),
    Mutant("AIQA-MUT-006", "Reuse a Vary candidate even when selected request fields mismatch.", "Sources/FoveaHTTP/HTTPCachePolicy.swift", "VaryCacheTests/testAcceptLanguageVariantsCoexistAndHitCorrectBodies_CACHE_PT_004", mutant_006),
    Mutant("AIQA-MUT-007", "Publish Cache-Control no-store responses into reusable caches.", "Sources/FoveaCore/HTTPImageResponseProcessor.swift", "PipelineTests/testNoStoreNeverSatisfiesNewRequest_CACHE_PT_026", mutant_007),
    Mutant("AIQA-MUT-008", "Allow a revoked generation to reach the record store.", "Sources/FoveaCore/PipelineCache.swift", "AuthGalleryTests/testRevocationBeforeRecordPublicationNeverTouchesRecordStore_AUTH_PT_003", mutant_008),
    Mutant("AIQA-MUT-009", "Accept a zero target dimension.", "component://ImageCraft/Sources/ImageCraftCore/ImageTypes.swift", "IdentityTests/testZeroTargetIsRejected_GEO_PT_002", mutant_009),
    Mutant("AIQA-MUT-010", "Decode a full-size bitmap instead of a target thumbnail.", "component://ImageCraft/Sources/ImageCraftImageIO/ImageIOImageDecoder.swift", "ImageDecoderTests/testTargetDecodeAvoidsFullSizeBitmap", mutant_010),
    Mutant("AIQA-MUT-011", "Keep stale elevated priority after a subscriber leaves.", "Sources/FoveaCore/SharedTaskRegistry.swift", "PrioritySchedulingTests/testSharedTaskEffectivePriorityRisesAndFallsWithSubscribers_SCHED_PT_003", mutant_011),
    Mutant("AIQA-MUT-012", "Let a stale completion remove an active task with the same key.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testMismatchedCompletionCannotRemoveActiveTask", mutant_012),
    Mutant("AIQA-MUT-013", "Use Swift hashValue as a persistent key digest.", "Sources/FoveaCore/Identity.swift", "IdentityTests/testFetchBaseKeyDigestUsesStableSHA256AiqaMut013", mutant_013),
    Mutant("AIQA-MUT-014", "Strip signed query parameters during URL normalization.", "Sources/FoveaCore/ImageRequestValidation.swift", "IdentityTests/testURLNormalizationIsConservativeAndFragmentFree_CACHE_PT_027", mutant_014),
    Mutant("AIQA-MUT-015", "Publish RenderedMemory before transform succeeds.", "Sources/FoveaCore/ImageDeliveryCoordinator.swift", "PipelineTests/testTransformFailureRetainsOriginalAndPublishesNoRendered_CACHE_PT_030", mutant_015),
    Mutant("AIQA-MUT-016", "Leave a newly created blob behind when record publication fails.", "Sources/FoveaCore/PipelineCache+Persistence.swift", "AuthGalleryTests/testRevokeDuringBlobCommitRemovesLateBlobAndRecord", mutant_016),
    Mutant("AIQA-MUT-017", "Write a post-revoke 200 record with generation zero.", "Sources/FoveaCore/HTTPImageResponseProcessor.swift", "PipelineTests/testRevokeThenNewResponsePersistsCurrentGenerationAndHitsDisk_CACHE_PT_038", mutant_017),
    Mutant("AIQA-MUT-018", "Allow a late 304 refresh to survive namespace revocation.", "Sources/FoveaCore/PipelineCache.swift", "AuthGalleryTests/testRevokeDuring304RefreshRemovesLateMetadata_AUTH_PT_011", mutant_018),
    Mutant("AIQA-MUT-019", "Leave a published record behind after generation revocation.", "Sources/FoveaCore/PipelineCache+Persistence.swift", "AuthGalleryTests/testRevocationAfterRecordPublicationRollsBackRecordAndBlob_AUTH_PT_005", mutant_019),
    Mutant("AIQA-MUT-020", "Admit transient geometry into RenderedMemory.", "Sources/FoveaCore/ImageDeliveryCoordinator.swift", "TargetGeometryTests/testTransientTargetDoesNotEnterRenderedMemoryUntilStableGeoPt009", mutant_020),
    Mutant("AIQA-MUT-021", "Disable the encoded metadata byte limit.", "component://ImageCraft/Sources/ImageCraftCore/ImageTypes.swift", "PipelineFailureTests/testMetadataSecurityFailurePublishesNoReusableStateSecCase004", mutant_021),
    Mutant("AIQA-MUT-022", "Create a separate DecodeKey registry for every subscriber.", "Sources/FoveaCore/DecodeStage.swift", "DecodeSharingTests/testSameDecodeKeyExecutesProbeAndDecodeOnce_SCHED_PT_002", mutant_022),
    Mutant("AIQA-MUT-023", "Delete overwritten 304 metadata instead of restoring it after cancellation.", "Sources/FoveaCore/PipelineCache.swift", "CacheRefreshTransactionTests/testCancellationAfterSameVariantRefreshRestoresPreviousRecord_CACHE_PT_039", mutant_023),
    Mutant("AIQA-MUT-024", "Allow memory-cache cost addition to overflow before eviction.", "component://Akashic/Sources/AkashicMemory/MemoryCache.swift", "MemoryCacheTests/testCostAccountingCannotOverflowPastLimit_RES_PT_001", mutant_024),
    Mutant("AIQA-MUT-025", "Accept semantically corrupt OriginalEncoded manifests.", "component://Akashic/Sources/AkashicDisk/FileBlobStoreMaintenance.swift", "ManifestSemanticValidationTests/testOriginalManifestSemanticCorruptionFailsClosedWithoutRewrite_SEC_CASE_030", mutant_025),
    Mutant("AIQA-MUT-026", "Accept semantically corrupt representation manifests.", "Sources/FoveaPersistence/RepresentationRecordStore.swift", "ManifestSemanticValidationTests/testRepresentationManifestSemanticCorruptionFailsClosedWithoutRewrite_SEC_CASE_030", mutant_026),
    Mutant("AIQA-MUT-027", "Accept an invalid runtime representation record.", "Sources/FoveaPersistence/RepresentationRecordStore.swift", "ManifestSemanticValidationTests/testRecordStoreRejectsInvalidRuntimeRecordWithoutMutation_SEC_CASE_030", mutant_027),
    Mutant("AIQA-MUT-028", "Ignore malformed or conflicting Content-Length values.", "Sources/FoveaHTTP/URLSessionTransport.swift", "URLSessionTransportTests/testMalformedOrConflictingContentLengthFailsClosed_HTTP_CONF_CONTENT_LENGTH_001", mutant_028),
    Mutant("AIQA-MUT-029", "Accept a noncanonical runtime content identifier.", "Sources/FoveaPersistence/AkashicOriginalEncodedStore.swift", "ManifestSemanticValidationTests/testOriginalStoreRejectsNoncanonicalRuntimeContentIDWithoutMutation_SEC_CASE_030", mutant_029),
    Mutant("AIQA-MUT-030", "Accept hard-linked managed files and lock inodes.", "component://Akashic/Sources/AkashicCore/StorageDirectorySecurity.swift", "FilesystemLinkDefenseTests/testLockAndManifestHardLinksAreRejected_SEC_CASE_031", mutant_030),
    Mutant(
        "AIQA-MUT-031",
        "Follow symbolic links while validating managed directory paths.",
        "component://Akashic/Sources/AkashicCore/StorageDirectorySecurity.swift",
        "FoveaMutationDirectoryContractTests/testManagedDirectoryValidationRejectsSymbolicLink",
        mutant_031,
        "Akashic",
        prepare_mutant_031_test,
    ),
    Mutant(
        "AIQA-MUT-032",
        "Allocate metadata files without enforcing the pre-read size bound.",
        "component://Akashic/Sources/AkashicCore/BoundedFileReader.swift",
        "FoveaMutationBoundedReaderContractTests/testBoundedFileReaderRejectsOversizeBeforeAllocation",
        mutant_032,
        "Akashic",
        prepare_mutant_032_test,
    ),
    Mutant("AIQA-MUT-033", "Reject finite records when the wall clock moves backward during a request.", "Sources/FoveaHTTP/RepresentationRecord.swift", "ManifestSemanticValidationTests/testRecordStoreAcceptsFiniteWallClockRollback_HTTP_CONF_AGE_005", mutant_033),
    Mutant("AIQA-MUT-034", "Ignore request network permissions in exact fetch execution identity.", "Sources/FoveaCore/ImageRequest.swift", "IdentityTests/testNetworkPolicyChangesExecutionButNotPersistentIdentity_RES_PT_008", mutant_034),
    Mutant("AIQA-MUT-035", "Bypass the profile access allowlist before cache and network access.", "Sources/FoveaCore/FoveaPipeline+Operations.swift", "ProfileAccessPolicyTests/testDeniedProfileFailsBeforeCacheOrNetwork_AUTH_PT_014", mutant_035),
    Mutant("AIQA-MUT-036", "Reset request network policy while replacing credentials.", "Sources/FoveaCore/ImageRequest+Credentials.swift", "AuthenticationRefreshTests/testCredentialReplacementPreservesRequestSemantics_AUTH_PT_013", mutant_036),
    Mutant("AIQA-MUT-037", "Reserve one byte instead of the estimated decode working set.", "Sources/FoveaCore/FoveaDecodePermitController.swift", "ResourceLimitTests/testDecodeWorkingSetIsRejectedBeforePixelAllocation_RES_PT_013", mutant_037),
    Mutant("AIQA-MUT-038", "Drop URLSession transaction metrics before transport completion.", "Sources/FoveaHTTP/URLSessionTransport.swift", "URLSessionTransportTests/testDelegateTransportCollectsSanitizedTaskMetrics_DIAG_PT_011", mutant_038),
    Mutant("AIQA-MUT-039", "Leak an asynchronous permit when the scoped operation throws or is cancelled.", "Sources/FoveaCore/AsyncPermitPool.swift", "PrioritySchedulingTests/testPermitScopeReleasesCapacityAfterSuccessFailureAndCancellation", mutant_039),
    Mutant("AIQA-MUT-040", "Accept remote cleartext HTTP image URLs.", "Sources/FoveaHTTP/HTTPURLSecurityPolicy.swift", "IdentityTests/testImageRequestRejectsRemoteCleartextButAllowsLoopback_SEC_CASE_033", mutant_040),
    Mutant("AIQA-MUT-041", "Allow HTTPS redirects to downgrade to remote cleartext HTTP.", "Sources/FoveaHTTP/HTTPRedirectPolicy.swift", "URLSessionTransportTests/testRedirectPolicyRejectsRemoteCleartextAndAllowsLoopback_SEC_CASE_033", mutant_041),
    Mutant("AIQA-MUT-042", "Omit decode working-set budget from the full configuration fingerprint.", "Sources/FoveaCore/PipelineConfiguration.swift", "PipelineConfigurationTests/testWorkingSetBudgetIsOperationalAndChangesFullFingerprint_PIPE_PT_010", mutant_042),
    Mutant("AIQA-MUT-043", "Make the official system composition root unrestricted by default.", "Sources/FoveaSystem/FoveaSystemPipeline.swift", "FoveaSystemPipelineTests/testSystemCompositionDefaultsToPublicOnly_AUTH_PT_014", mutant_043),
    Mutant("AIQA-MUT-044", "Omit completed-state publication for a shared task entry.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testCompletedTaskRemainsJoinableOnlyWhileExistingSubscriberHoldsIt_SCHED_PT_015", mutant_044),
    Mutant("AIQA-MUT-045", "Omit the correlated fetch cancellation event when retry backoff is cancelled.", "Sources/FoveaCore/FetchRetryController.swift", "RetryPolicyTests/testCancellationDuringBackoffStopsFurtherAttemptsErrPt004", mutant_045),
    Mutant("AIQA-MUT-046", "Preserve ambient URLSession credential storage.", "Sources/FoveaHTTP/URLSessionTransport.swift", "URLSessionTransportTests/testConfigurationIsSanitizedBeforeSessionCreation_AUTH_PT_008", mutant_046),
    Mutant("AIQA-MUT-047", "Leave a zero-subscriber shared task registered after its handoff lease.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testDetachedTaskIsCancelledAfterBoundedHandoffLease_SCHED_PT_016", mutant_047),
    Mutant("AIQA-MUT-048", "Accept missing or observed proxy metrics under the strict proxy policy.", "Sources/FoveaHTTP/URLSessionTransportPolicy.swift", "URLSessionTransportTests/testProxyTrustPolicyIsExplicitAndFailsClosedWhenVerificationIsRequired_RES_PT_015", mutant_048),
    Mutant("AIQA-MUT-049", "Remove the namespace identity byte bound.", "Sources/FoveaCore/ImageRequestValidation.swift", "IdentityTests/testImageRequestBoundsIdentityComponentsBeforePipelineUse_RES_PT_016", mutant_049),
    Mutant("AIQA-MUT-050", "Allow namespace generation to wrap from UInt64.max to zero.", "Sources/FoveaCore/NamespaceRegistry.swift", "NamespaceRegistryTests/testNamespaceGenerationExhaustionFailsClosedWithoutWraparound_AUTH_PT_016", mutant_050),
    Mutant("AIQA-MUT-051", "Skip destination validation before creating the initial URLSession task.", "Sources/FoveaHTTP/URLSessionTransport.swift", "URLSessionTransportTests/testDestinationPolicyRejectsInitialRequestAndCrossOriginRedirect_RES_PT_017", mutant_051),
    Mutant("AIQA-MUT-052", "Allow redirects outside the exact destination allowlist.", "Sources/FoveaHTTP/HTTPRedirectPolicy.swift", "URLSessionTransportTests/testDestinationPolicyRejectsInitialRequestAndCrossOriginRedirect_RES_PT_017", mutant_052),
    Mutant("AIQA-MUT-053", "Bypass destination policy before cache and network access.", "Sources/FoveaCore/ProfileAccessPolicy.swift", "ProfileAccessPolicyTests/testDestinationPolicyRejectsBeforeCacheAndNetwork_AUTH_PT_017", mutant_053),
    Mutant("AIQA-MUT-054", "Omit destination policy from reusable transport identity.", "Sources/FoveaHTTP/URLSessionTransportPolicy.swift", "URLSessionTransportTests/testBuiltInSessionPolicyChangesReusableTransportIdentity_RES_PT_012", mutant_054),
    Mutant("AIQA-MUT-055", "Admit unbounded new namespace identities after the registry reaches capacity.", "Sources/FoveaCore/NamespaceRegistry.swift", "ResourceLimitTests/testNamespaceCapacityRejectsBeforeNetwork_RES_PT_018", mutant_055),
    Mutant("AIQA-MUT-056", "Retain persistent store actors and writer leases forever in the process registry.", "Sources/FoveaPersistence/FoveaPersistentStores.swift", "StoreGenerationTests/testPersistentStoreRegistryDoesNotRetainReleasedStoreActors", mutant_056),
    Mutant("AIQA-MUT-057", "Enable high-cardinality cancellation instrumentation in production by default.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testCancellationInstrumentationIsDisabledByDefault", mutant_057),
    Mutant("AIQA-MUT-058", "Apply the signpost interval bound independently per stage instead of globally.", "Sources/FoveaObservability/OSLogDiagnosticsSink.swift", "OSLogDiagnosticsTests/testActiveIntervalsAreBoundedAndDroppedSummaryClosesOutstandingIntervals", mutant_058),
    Mutant("AIQA-MUT-059", "Disable remembered credential scope eviction at the configured capacity.", "Sources/FoveaCore/CredentialRefreshing.swift", "AuthenticationRefreshTests/testRememberedCredentialsAreBoundedExpireAndCanBeInvalidated", mutant_059),
    Mutant("AIQA-MUT-060", "Drop redirect metrics while translating transport completion into diagnostics.", "Sources/FoveaCore/FetchStageDiagnostics.swift", "DiagnosticsTests/testFetchCompletionPropagatesSanitizedNetworkMetrics_DIAG_PT_012", mutant_060),
    Mutant("AIQA-MUT-061", "Classify transient blob I/O failures as corrupt content eligible for deletion.", "component://Akashic/Sources/AkashicDisk/FileBlobStoreIdentity.swift", "StagingAndStorageTests/testTransientBlobReadFailureDoesNotDeleteValidManifestEntry", mutant_061),
    Mutant("AIQA-MUT-062", "Retain expired weak registry metadata for every previously opened cache root.", "Sources/FoveaPersistence/FoveaPersistentStores.swift", "StoreGenerationTests/testPersistentStoreRegistryPrunesReleasedHighCardinalityRoots", mutant_062),
    Mutant("AIQA-MUT-063", "Allow a cancelled caller to consume remembered credentials and replay an authenticated request.", "Sources/FoveaCore/CredentialRefreshing.swift", "AuthenticationRefreshTests/testCancelledCallerCannotReplayRememberedCredentials_AUTH_PT_018", mutant_063),
    Mutant("AIQA-MUT-064", "Allow new namespace work while revoke cleanup is still active.", "Sources/FoveaCore/NamespaceRegistry.swift", "NamespaceRegistryTests/testRevocationBarrierRejectsNewGenerationUntilEveryCleanupLeaseFinishes_AUTH_PT_019", mutant_064),
    Mutant("AIQA-MUT-065", "Tie the memory-pressure monitor to the transient composition wrapper instead of the pipeline.", "Sources/FoveaSystem/FoveaSystemPipeline.swift", "FoveaSystemPipelineTests/testMemoryPressureMonitorIsRetainedByPipelineInsteadOfWrapper", mutant_065),
    Mutant("AIQA-MUT-066", "Allow free-form diagnostic reason text to bypass sanitization.", "Sources/FoveaCore/Diagnostics.swift", "DiagnosticsTests/testDiagnosticReasonRejectsFreeFormSensitiveText", mutant_066),
    Mutant("AIQA-MUT-067", "Report removed cache items as if they were released bytes.", "Sources/FoveaCore/FoveaPipeline+Operations.swift", "FoveaSystemPipelineTests/testMemoryPressurePurgesRenderedMemoryWithoutRefetch_RES_PT_011", mutant_067),
    Mutant("AIQA-MUT-068", "Accept an unknown serialized diagnostic schema.", "Sources/FoveaCore/Diagnostics.swift", "DiagnosticsTests/testDecodedDiagnosticEventReappliesSanitizationAndRejectsUnknownSchema", mutant_068),
    Mutant("AIQA-MUT-069", "Report dropped diagnostic events in byteCount instead of itemCount.", "Sources/FoveaCore/DiagnosticsSink.swift", "DiagnosticsTests/testExternalRelayReportsBoundedDrops_DIAG_PT_004", mutant_069),
    Mutant("AIQA-MUT-070", "Allow free-form or secret-bearing text through the public PipelineFailure contract.", "Sources/FoveaCore/PipelineFailure.swift", "PipelineFailureTests/testPublicFailureContractSanitizesInvalidFields_ERR_PT_010", mutant_070),
    Mutant("AIQA-MUT-071", "Remove the response-header count bound.", "Sources/FoveaHTTP/HTTPMetadataLimits.swift", "HTTPMetadataBoundaryTests/testResponseHeadRejectsUnboundedOrUnsafeMetadata_SEC_CASE_042", mutant_071),
    Mutant("AIQA-MUT-072", "Persist an oversized HTTP validator field.", "Sources/FoveaHTTP/RepresentationRecord.swift", "HTTPMetadataBoundaryTests/testOversizedRecordMetadataIsRejectedWithoutMutatingPublishedIndex_SEC_CASE_042", mutant_072),
    Mutant("AIQA-MUT-073", "Retain stale base-key and reference indexes when replacing a variant.", "Sources/FoveaPersistence/RepresentationRecordStore.swift", "HTTPMetadataBoundaryTests/testRepresentationIndexesStayConsistentAcrossReplacementAndReopen_CACHE_PT_040", mutant_073),
    Mutant("AIQA-MUT-074", "Ignore a changed SwiftUI load token for the same display identity.", "Sources/FoveaSwiftUI/FoveaImageModels.swift", "SwiftUIStateTests/testChangingLoadTokenForcesSameIdentityRetry_UI_PT_020", mutant_074),
    Mutant("AIQA-MUT-075", "Force every SwiftUI image phase to use fill layout.", "Sources/FoveaSwiftUI/FoveaImagePhaseContent.swift", "SwiftUIViewRenderingTests/testPhaseContentPreservesFitAndFillAspectSemantics_UI_PT_021", mutant_075),
    Mutant("AIQA-MUT-076", "Widen a missing redirect route to the secure-default destination policy.", "Sources/FoveaHTTP/URLSessionEventRouter.swift", "URLSessionTransportTests/testEventRouterScopesCustomCredentialHeadersToTask", mutant_076),
    Mutant("AIQA-MUT-077", "Trust a custom transport's claimed received-byte count instead of the delivered body.", "Sources/FoveaHTTP/HTTPTypes.swift", "URLSessionTransportTests/testPublicTransportResponseDerivesContentIdentityAndByteMetrics", mutant_077),
    Mutant("AIQA-MUT-078", "Trust a custom transport to enforce the pipeline response-body hard cap.", "Sources/FoveaCore/FetchStage.swift", "ResourceLimitTests/testPipelineRevalidatesCustomTransportBodyLimit", mutant_078),
    Mutant("AIQA-MUT-079", "Publish a transform result without revalidating its output surface and working set.", "Sources/FoveaCore/TransformStage.swift", "PipelineTests/testTransformOutputIsRevalidatedBeforeDeliveryAndMemoryAdmission", mutant_079),
    Mutant("AIQA-MUT-080", "Skip runtime orphan cleanup when the manifest has no logical victims.", "component://Akashic/Sources/AkashicDisk/FileBlobStoreMaintenance.swift", "StagingAndStorageTests/testGarbageCollectionRetriesOrphanCleanupWithoutManifestVictims", mutant_080),
    Mutant("AIQA-MUT-081", "Wrap permit queue sequence numbers instead of rebasing the bounded waiter set.", "Sources/FoveaCore/AsyncPermitPool.swift", "PrioritySchedulingTests/testPermitSequenceOverflowRebasesWithoutReorderingEqualPriorityWaiters", mutant_081),
    Mutant("AIQA-MUT-082", "Allow unbounded or control-bearing reusable transport context identifiers.", "Sources/FoveaHTTP/HTTPTypes.swift", "URLSessionTransportTests/testTransportReusePolicyBoundsAndHashesCallerContext", mutant_082),
    Mutant("AIQA-MUT-083", "Accept invalid or case-colliding credential header names in a transport request.", "Sources/FoveaHTTP/HTTPTypes.swift", "URLSessionTransportTests/testTransportRequestCanonicalizesAndBoundsCredentialHeaderNames", mutant_083),
    Mutant("AIQA-MUT-084", "Accept an unsafe final response URL outside the supported URL security policy.", "Sources/FoveaHTTP/HTTPTypes.swift", "URLSessionTransportTests/testResponseHeadRejectsUnsafeFinalURLAndMetricsClampNegativeBytes", mutant_084),
    Mutant("AIQA-MUT-085", "Parse fractional or scientific HTTP delta-seconds as valid freshness or retry delays.", "Sources/FoveaHTTP/HTTPCachePolicy.swift", "HTTPCachePolicyTests/testDeltaSecondsRejectsFractionalAndScientificNotation", mutant_085),
    Mutant("AIQA-MUT-086", "Use the first duplicate max-age directive instead of rejecting ambiguous cache policy.", "Sources/FoveaHTTP/HTTPCachePolicy.swift", "HTTPCachePolicyTests/testAmbiguousCacheControlFailsConservatively", mutant_086),
    Mutant("AIQA-MUT-087", "Allow stale fallback for no-cache or must-revalidate representations.", "Sources/FoveaCore/StaleFallbackPolicy.swift", "StaleFallbackTests/testMustRevalidateAndNoCacheNeverUseStaleFallback", mutant_087),
    Mutant("AIQA-MUT-088", "Treat encoded-cache cancellation as corruption and delete a valid record.", "Sources/FoveaCore/EncodedDataCoordinator.swift", "CacheCancellationTests/testFreshCacheCancellationDoesNotDeleteRecordOrStartNetwork", mutant_088),
    Mutant("AIQA-MUT-089", "Trust a custom record store to enforce namespace isolation.", "Sources/FoveaCore/PipelineCache.swift", "RepresentationStoreBoundaryTests/testCrossNamespaceCustomRecordIsRejectedBeforeEncodedRead", mutant_089),
    Mutant("AIQA-MUT-090", "Accept the first of two conflicting records with the same variant identity.", "Sources/FoveaCore/PipelineCache.swift", "RepresentationStoreBoundaryTests/testConflictingDuplicateVariantFromCustomStoreIsRejectedDeterministically", mutant_090),
    Mutant("AIQA-MUT-091", "Trust a custom decoder probe without reapplying runtime decode limits.", "Sources/FoveaCore/DecodeStage.swift", "ResourceLimitTests/testCustomDecoderProbeIsRevalidatedAgainstRuntimeLimits", mutant_091),
    Mutant("AIQA-MUT-092", "Misclassify retry-scheduler failure as user cancellation.", "Sources/FoveaCore/FetchRetryController.swift", "RetryPolicyTests/testRetrySleeperFailureIsNotMisclassifiedAsCancellation", mutant_092),
    Mutant("AIQA-MUT-093", "Allow detached orphan tasks to survive shared registry destruction.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testRegistryDeinitCancelsDetachedOrphanImmediately", mutant_093),
    Mutant("AIQA-MUT-094", "Wrap active OSLog interval sequence numbers instead of rebasing them.", "Sources/FoveaObservability/OSLogDiagnosticsSink.swift", "OSLogDiagnosticsTests/testIntervalSequenceOverflowRebasesBeforeCapacityEviction", mutant_094),
    Mutant("AIQA-MUT-095", "Let staging cleanup delete another active transport session in the same process.", "Sources/FoveaHTTP/StagingDirectoryLease.swift", "URLSessionTransportTests/testStagingDirectoryLeaseRemovesAbandonedButNotActiveSessions", mutant_095),
    Mutant("AIQA-MUT-096", "Treat unmeasurable ImageIO properties as zero metadata bytes.", "component://ImageCraft/Sources/ImageCraftImageIO/ImageIOImageDecoder.swift", "ImageDecoderTests/testUnmeasurableImagePropertiesFailClosedAsOversizedMetadata", mutant_096, "ImageCraft"),
    Mutant("AIQA-MUT-097", "Revoke the base namespace without clearing remembered refreshed credentials.", "Sources/FoveaCore/CredentialRefreshing.swift", "AuthenticationRefreshTests/testRevocableRefreshingLoaderInvalidatesCredentialsBeforeNamespaceRevoke", mutant_097),
    Mutant("AIQA-MUT-098", "Delete orphan staging blobs while reporting zero reclaimed files and bytes.", "component://Akashic/Sources/AkashicDisk/FileBlobStoreMaintenance.swift", "StagingAndStorageTests/testGarbageCollectionRetriesOrphanCleanupWithoutManifestVictims", mutant_098),
    Mutant("AIQA-MUT-099", "Accept a noncanonical live-content reference into garbage collection.", "Sources/FoveaStorage/StorageTypes.swift", "CacheGarbageCollectionTests/testStoredContentReferenceRejectsNoncanonicalIdentity", mutant_099),
    Mutant("AIQA-MUT-100", "Advance namespace revocation without durably publishing the generation.", "Sources/FoveaCore/NamespaceRegistry.swift", "NamespaceGenerationPersistenceTests/testDurableAdvancePreventsStaleGenerationAfterRegistryRecreation_AUTH_PT_020", mutant_100),
    Mutant("AIQA-MUT-101", "Treat auth-like custom header names as ordinary public metadata.", "Sources/FoveaHTTP/CredentialHeaderPolicy.swift", "VaryCacheTests/testAuthLikeCustomVaryHeaderFailsClosedWithoutDeclaration_AUTH_PT_012", mutant_101),
    Mutant(
        "AIQA-MUT-102",
        "Let benchmark request IDs re-enter Fovea cache and single-flight identity.",
        "Benchmarks/ComparativeLab/Adapters/FoveaAdapterPackage/Sources/FoveaComparatorAdapter/FoveaComparatorAdapter.swift",
        "FoveaComparatorAdapterTests/testSameURLWithDifferentObservationIDsSharesOneTransport_COMP_PT_027",
        mutant_102,
        test_root="Benchmarks/ComparativeLab/Adapters/FoveaAdapterPackage",
    ),
]


class ProcessGroupInterrupted(BaseException):
    def __init__(self, signum: int):
        super().__init__(f"mutation runner interrupted by signal {signum}")
        self.signum = signum


def terminate_process_group(
    process: subprocess.Popen[str],
    *,
    grace_seconds: float = 5,
) -> str:
    if process.poll() is not None:
        stdout, _ = process.communicate()
        return stdout or ""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        stdout, _ = process.communicate(timeout=grace_seconds)
        return stdout or ""
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, _ = process.communicate()
        return stdout or ""


def run(command: list[str], cwd: Path, env: dict[str, str], timeout: int) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    previous_handlers: dict[signal.Signals, object] = {}

    def forward_signal(signum: int, _frame: object) -> None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        raise ProcessGroupInterrupted(signum)

    for handled_signal in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[handled_signal] = signal.getsignal(handled_signal)
        signal.signal(handled_signal, forward_signal)
    try:
        stdout, _ = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, None)
    except subprocess.TimeoutExpired as error:
        tail = terminate_process_group(process)
        prefix = error.stdout or ""
        if isinstance(prefix, bytes):
            prefix = prefix.decode(errors="replace")
        raise subprocess.TimeoutExpired(command, timeout, output=prefix + tail)
    except ProcessGroupInterrupted:
        terminate_process_group(process)
        raise
    finally:
        for handled_signal, previous in previous_handlers.items():
            signal.signal(handled_signal, previous)


def test_started(output: str) -> bool:
    if "Test Case '" in output and " started." in output:
        return True
    if re.search(r"Executed [1-9][0-9]* tests?", output):
        return True
    return "◇ Test " in output and " started" in output


def run_mutation_test(
    worktree: Path,
    env: dict[str, str],
    mutant: Mutant,
) -> subprocess.CompletedProcess[str]:
    if mutant.prepare_test is not None:
        mutant.prepare_test(worktree)
    test_root = worktree
    if mutant.test_root is not None:
        test_root = (worktree / mutant.test_root).resolve()
        test_root.relative_to(worktree.resolve())
        if not test_root.is_dir():
            raise RuntimeError(f"mutation test root is missing: {mutant.test_root}")
    if mutant.test_package is not None:
        if mutant.test_root is not None:
            raise RuntimeError("mutation cannot define both test_root and test_package")
        test_root = worktree / ".build/checkouts" / mutant.test_package
        if not test_root.is_dir():
            raise RuntimeError(f"mutation test package checkout is missing: {mutant.test_package}")
    completed = run(
        ["xcrun", "swift", "test", "--filter", mutant.test_filter],
        test_root,
        env,
        timeout=180,
    )
    if completed.returncode != 0 or test_started(completed.stdout):
        return completed

    candidates = sorted(
        worktree.glob(".build/**/FoveaTests.xctest"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        return completed
    direct = run(
        ["xcrun", "xctest", "-XCTest", mutant.test_filter, str(candidates[0])],
        worktree,
        env,
        timeout=60,
    )
    return subprocess.CompletedProcess(
        direct.args,
        direct.returncode,
        completed.stdout
        + "\n--- direct XCTest fallback ---\n"
        + direct.stdout,
        None,
    )


def classify(return_code: int, output: str) -> str:
    started = test_started(output)
    if return_code == 0:
        return "survived" if started else "invalid"
    return "killed" if started else "invalid"


def command_output(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def create_workspace_snapshot(worktree: Path, head: str) -> tuple[str, str, bool]:
    patch = subprocess.run(
        [GIT, "diff", "--binary", "HEAD", "--"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    if patch:
        subprocess.run(
            [GIT, "apply", "--binary", "--whitespace=nowarn", "-"],
            cwd=worktree,
            input=patch,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    untracked = subprocess.run(
        [GIT, "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.split(b"\0")
    for raw_relative in untracked:
        if not raw_relative:
            continue
        relative = Path(os.fsdecode(raw_relative))
        if relative.parts and relative.parts[0] == "Packages":
            continue
        lexical_source = ROOT / relative
        if lexical_source.is_symlink():
            raise RuntimeError(
                f"mutation snapshot rejects untracked symbolic link: {relative.as_posix()}"
            )
        source = lexical_source.resolve()
        source.relative_to(ROOT.resolve())
        destination = worktree / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    dirty = bool(command_output([GIT, "status", "--porcelain"], worktree))
    snapshot_ref = head
    if dirty:
        subprocess.run([GIT, "add", "-A"], cwd=worktree, check=True)
        commit_env = os.environ.copy()
        commit_env.update(
            {
                "GIT_AUTHOR_NAME": "Fovea Mutation Snapshot",
                "GIT_AUTHOR_EMAIL": "mutation-snapshot@invalid",
                "GIT_COMMITTER_NAME": "Fovea Mutation Snapshot",
                "GIT_COMMITTER_EMAIL": "mutation-snapshot@invalid",
            }
        )
        subprocess.run(
            [GIT, "commit", "--no-gpg-sign", "-m", "Fovea mutation workspace snapshot"],
            cwd=worktree,
            env=commit_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=True,
        )
        snapshot_ref = command_output([GIT, "rev-parse", "HEAD"], worktree)

    snapshot_tree = command_output(
        [GIT, "rev-parse", f"{snapshot_ref}^{{tree}}"], worktree
    )
    return snapshot_ref, snapshot_tree, dirty



def make_report(
    *,
    required_mutants: list[Mutant],
    head: str,
    snapshot_tree: str,
    includes_working_tree_changes: bool,
    xcode_version: str,
    swift_version: str,
    results: list[dict[str, object]],
) -> dict[str, object]:
    ordered_results = sorted(results, key=lambda item: str(item["id"]))
    summary = {
        "required": len(required_mutants),
        "completed": len(ordered_results),
        "killed": sum(item["status"] == "killed" for item in ordered_results),
        "survived": sum(item["status"] == "survived" for item in ordered_results),
        "invalid": sum(item["status"] == "invalid" for item in ordered_results),
    }
    return {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "producer": "agent-declared",
        "verifiedCommit": head,
        "verifiedTree": snapshot_tree,
        "includesWorkingTreeChanges": includes_working_tree_changes,
        "xcodeVersion": xcode_version,
        "swiftVersion": swift_version,
        "requiredMutants": [mutant.identifier for mutant in required_mutants],
        "summary": summary,
        "mutants": ordered_results,
    }


def write_report(report: dict[str, object]) -> None:
    temporary = REPORT_PATH.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, REPORT_PATH)


def resumable_results(
    report: dict[str, object],
    *,
    required_mutants: list[Mutant],
    head: str,
    snapshot_tree: str,
) -> list[dict[str, object]]:
    if report.get("verifiedCommit") != head:
        raise RuntimeError("resume report commit does not match the current HEAD")
    if report.get("verifiedTree") != snapshot_tree:
        raise RuntimeError("resume report tree does not match the current workspace")
    raw_results = report.get("mutants")
    if not isinstance(raw_results, list):
        raise RuntimeError("resume report has no mutant results")

    known_ids = {mutant.identifier for mutant in required_mutants}
    resumed: list[dict[str, object]] = []
    seen: set[str] = set()
    for raw in raw_results:
        if not isinstance(raw, dict):
            raise RuntimeError("resume report contains a non-object mutant result")
        identifier = raw.get("id")
        if not isinstance(identifier, str) or identifier not in known_ids or identifier in seen:
            raise RuntimeError(f"resume report contains an invalid mutant id: {identifier!r}")
        seen.add(identifier)
        if raw.get("status") != "killed":
            continue
        log_relative = raw.get("logPath")
        if not isinstance(log_relative, str):
            continue
        log_path = (ROOT / log_relative).resolve()
        log_path.relative_to(ROOT.resolve())
        if not log_path.is_file() or sha256(log_path) != raw.get("logSha256"):
            continue
        resumed.append(dict(raw))
    return resumed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the tree-bound critical mutation gate with optional checkpoint resume."
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="reuse already killed mutants from a matching tree-bound checkpoint",
    )
    parser.add_argument(
        "--only",
        help="run a comma-separated subset of mutant identifiers for targeted smoke verification",
    )
    parser.add_argument(
        "--validate-applications",
        action="store_true",
        help="apply every selected mutant to a reset exact snapshot without running tests",
    )
    args = parser.parse_args()

    selected_mutants = MUTANTS
    if args.only:
        requested = [item.strip() for item in args.only.split(",") if item.strip()]
        by_id = {mutant.identifier: mutant for mutant in MUTANTS}
        unknown = sorted(set(requested) - set(by_id))
        if unknown:
            raise RuntimeError(f"unknown mutant identifier(s): {', '.join(unknown)}")
        selected_mutants = [by_id[identifier] for identifier in requested]
        if not selected_mutants:
            raise RuntimeError("--only must select at least one mutant")
    if args.resume and args.only:
        raise RuntimeError("--resume cannot be combined with --only")
    if args.resume and args.validate_applications:
        raise RuntimeError("--resume cannot be combined with --validate-applications")

    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    if not args.resume and not args.validate_applications:
        if LOG_ROOT.exists():
            shutil.rmtree(LOG_ROOT)
        if REPORT_PATH.exists():
            REPORT_PATH.unlink()
    LOG_ROOT.mkdir(parents=True, exist_ok=True)
    if args.resume and not REPORT_PATH.is_file():
        raise RuntimeError("--resume requires an existing mutation checkpoint")

    head = command_output([GIT, "rev-parse", "HEAD"], ROOT)
    env = os.environ.copy()
    if not args.validate_applications and not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = subprocess.run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip()

    if args.validate_applications:
        xcode_version = "not-required-for-application-validation"
        swift_version = "not-required-for-application-validation"
    else:
        xcode_version = command_output(["xcodebuild", "-version"], ROOT, env)
        swift_version = command_output(["xcrun", "swift", "--version"], ROOT, env)
    snapshot_tree = command_output([GIT, "rev-parse", "HEAD^{tree}"], ROOT)
    includes_working_tree_changes = False

    results: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="fovea-critical-mutants-") as temporary:
        worktree = Path(temporary) / "worktree"
        subprocess.run(
            [GIT, "worktree", "add", "--detach", str(worktree), head],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=True,
        )
        snapshot_ref, snapshot_tree, includes_working_tree_changes = create_workspace_snapshot(
            worktree, head
        )
        revisions = (
            materialize_component_checkouts_for_validation(worktree)
            if args.validate_applications
            else prepare_component_checkouts(worktree, env)
        )
        if args.validate_applications:
            application_failures: list[tuple[str, str]] = []
            valid_count = 0
            try:
                for mutant in selected_mutants:
                    subprocess.run(
                        [GIT, "reset", "--hard", snapshot_ref],
                        cwd=worktree,
                        check=True,
                        stdout=subprocess.DEVNULL,
                    )
                    subprocess.run(
                        [GIT, "clean", "-fd"],
                        cwd=worktree,
                        check=True,
                        stdout=subprocess.DEVNULL,
                    )
                    reset_component_checkouts(worktree, revisions)
                    try:
                        source = mutation_source(worktree, mutant.source_file)
                        before = sha256(source)
                        mutant.apply(worktree)
                        source = mutation_source(worktree, mutant.source_file)
                        after = sha256(source)
                        if before == after:
                            raise RuntimeError(
                                f"did not change declared source file {mutant.source_file}"
                            )
                    except Exception as error:  # noqa: BLE001 - audit must report every stale application.
                        message = str(error).replace("\n", " ")
                        application_failures.append((mutant.identifier, message))
                        print(
                            f"{mutant.identifier}: application-invalid ({message})",
                            flush=True,
                        )
                        continue
                    valid_count += 1
                    print(
                        f"{mutant.identifier}: application-valid ({mutant.source_file})",
                        flush=True,
                    )
            finally:
                subprocess.run(
                    [GIT, "worktree", "remove", "--force", str(worktree)],
                    cwd=ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    check=False,
                )
                subprocess.run(
                    [GIT, "worktree", "prune"],
                    cwd=ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    check=False,
                )
            print(
                f"Mutation application audit: valid={valid_count} "
                f"invalid={len(application_failures)} total={len(selected_mutants)}"
            )
            return 1 if application_failures else 0
        if args.resume:
            checkpoint_report = json.loads(REPORT_PATH.read_text())
            results = resumable_results(
                checkpoint_report,
                required_mutants=selected_mutants,
                head=head,
                snapshot_tree=snapshot_tree,
            )
            print(f"Resuming with {len(results)} verified killed mutant(s)", flush=True)
        completed_ids = {str(item["id"]) for item in results}

        def checkpoint() -> None:
            write_report(
                make_report(
                    required_mutants=selected_mutants,
                    head=head,
                    snapshot_tree=snapshot_tree,
                    includes_working_tree_changes=includes_working_tree_changes,
                    xcode_version=xcode_version,
                    swift_version=swift_version,
                    results=results,
                )
            )

        checkpoint()
        try:
            for mutant in selected_mutants:
                if mutant.identifier in completed_ids:
                    continue
                subprocess.run(
                    [GIT, "reset", "--hard", snapshot_ref],
                    cwd=worktree,
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
                subprocess.run(
                    [GIT, "clean", "-fd"],
                    cwd=worktree,
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
                reset_component_checkouts(worktree, revisions)
                log_path = LOG_ROOT / f"{mutant.identifier}.log"
                status = "invalid"
                return_code = -1
                output = ""
                try:
                    mutant.apply(worktree)
                    completed = run_mutation_test(
                        worktree,
                        env,
                        mutant,
                    )
                    return_code = completed.returncode
                    output = completed.stdout
                    status = classify(return_code, output)
                except subprocess.TimeoutExpired as error:
                    output = (
                        f"mutation test timed out after {error.timeout} seconds\n"
                        f"{error.stdout or ''}"
                    )
                    status = "killed" if test_started(output) else "invalid"
                    return_code = 124
                except Exception as error:  # noqa: BLE001 - 门禁需要记录每个无效变异。
                    output = f"mutation application failed: {error}\n{traceback.format_exc()}"
                log_path.write_text(output)
                result = {
                    "id": mutant.identifier,
                    "description": mutant.description,
                    "sourceFile": mutant.source_file,
                    "testFilter": mutant.test_filter,
                    "status": status,
                    "exitCode": return_code,
                    "logPath": str(log_path.relative_to(ROOT)),
                    "logSha256": sha256(log_path),
                }
                results.append(result)
                completed_ids.add(mutant.identifier)
                checkpoint()
                print(
                    f"{mutant.identifier}: {status} ({mutant.test_filter})",
                    flush=True,
                )
        finally:
            subprocess.run(
                [GIT, "worktree", "remove", "--force", str(worktree)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            subprocess.run(
                [GIT, "worktree", "prune"],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )

    report = make_report(
        required_mutants=selected_mutants,
        head=head,
        snapshot_tree=snapshot_tree,
        includes_working_tree_changes=includes_working_tree_changes,
        xcode_version=xcode_version,
        swift_version=swift_version,
        results=results,
    )
    write_report(report)
    summary = report["summary"]
    if not isinstance(summary, dict):
        raise RuntimeError("mutation report summary construction failed")
    print(f"Mutation report: {REPORT_PATH.relative_to(ROOT)} sha256:{sha256(REPORT_PATH)}")
    if (
        summary["completed"] != len(selected_mutants)
        or summary["survived"]
        or summary["invalid"]
    ):
        print("Critical mutation gate failed", file=sys.stderr)
        return 1
    print("Critical mutation gate passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProcessGroupInterrupted as error:
        print(f"Mutation runner interrupted by signal {error.signum}", file=sys.stderr)
        raise SystemExit(128 + error.signum)
