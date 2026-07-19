#!/usr/bin/env python3
from __future__ import annotations

import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_ROOT = ROOT / ".artifacts/mutation"
LOG_ROOT = ARTIFACT_ROOT / "logs"
REPORT_PATH = ARTIFACT_ROOT / "critical-mutants.json"


@dataclasses.dataclass(frozen=True)
class Mutant:
    identifier: str
    description: str
    source_file: str
    test_filter: str
    apply: Callable[[Path], None]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_literal(
    path: Path,
    old: str,
    new: str,
    *,
    expected_count: int = 1,
) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != expected_count:
        raise RuntimeError(
            f"{path}: expected {expected_count} occurrence(s), found {count} for literal mutation"
        )
    path.write_text(text.replace(old, new))


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
    if start_index < 0:
        raise RuntimeError(f"{path}: section start not found: {start!r}")
    end_index = text.find(end, start_index + len(start))
    if end_index < 0:
        raise RuntimeError(f"{path}: section end not found: {end!r}")
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
    count = body.count(old)
    if count != expected_count:
        raise RuntimeError(
            f"{path}: expected {expected_count} occurrence(s), found {count} in section {start!r}"
        )
    path.write_text(prefix + body.replace(old, new) + suffix)


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
        "public var displayIdentity",
        "      selectedVariant: selectedVariant,\n",
        "      selectedVariant: nil,\n",
    )
    replace_in_section(
        path,
        "package func fetchExecutionKey(",
        "public var displayIdentity",
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
        r"public func isFresh\(at date: Date\) -> Bool \{\n(?:.|\n)*?\n  \}",
        "public func isFresh(at date: Date) -> Bool { true }",
        flags=re.MULTILINE,
    )


def mutant_005(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/HTTPImageResponseProcessor.swift",
        "  func process304(",
        "  func process200(",
        "      contentID: existing.contentID,\n",
        '      contentID: "sha256:\\(String(repeating: \"0\", count: 64)):\\(existing.payloadLength)",\n',
    )


def mutant_006(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPCachePolicy.swift",
        "package static func selectRecord(",
        "  }\n}",
        "      return current == record.vary\n",
        "      return current.fieldNames == record.vary.fieldNames\n",
    )


def mutant_007(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/HTTPImageResponseProcessor.swift",
        "  func process200(",
        "  private func refreshRecord(",
        "    if allowReusableState, disposition != .noStore {\n",
        "    if allowReusableState {\n",
    )


def mutant_008(root: Path) -> None:
    regex_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "private func requireActive(",
        "  }\n}",
        r"guard await namespaceRegistry\.isActive\(generation, for: namespace\) else \{",
        "guard true else {",
    )


def mutant_009(root: Path) -> None:
    replace_literal(
        root / "Sources/ImageCraftCore/ImageTypes.swift",
        "    guard width > 0, height > 0 else { throw ImageCraftError.invalidTarget }\n",
        "    guard width >= 0, height >= 0 else { throw ImageCraftError.invalidTarget }\n",
    )


def mutant_010(root: Path) -> None:
    replace_literal(
        root / "Sources/ImageCraftImageIO/ImageIOImageDecoder.swift",
        "CGImageSourceCreateThumbnailAtIndex",
        "CGImageSourceCreateImageAtIndex",
    )


def mutant_011(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "  package func release(\n",
        "  package func subscriberCount",
        """      if !entry.subscribers.isEmpty {
        let effective = Self.effectivePriority(entry.subscribers)
        await entry.priorityControl.update(effective)
      }
""",
        "      // AIQA-MUT-011：故意不降低有效优先级。\n",
    )


def mutant_012(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "  package func completed(key: Key, taskID: UUID) async",
        "  private static func effectivePriority(",
        "    guard let entry = entries[key], entry.taskID == taskID else { return }\n",
        "    guard let entry = entries[key] else { return }\n",
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
        root / "Sources/FoveaCore/ImageRequest.swift",
        "private static func normalizedHTTPURL(",
        "private static func normalizedHeaders(",
        "    components.fragment = nil\n",
        "    components.fragment = nil\n    components.query = nil\n",
    )


def mutant_015(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/ImageDeliveryCoordinator.swift",
        "  func transformAndPublish(",
        "  func imageFromReusableData(",
        "    let image = try await transformStage.image(from: decoded)\n",
        """    let prematureRenderKey = scopedRenderKey(
      contentID: contentID,
      request: request,
      generation: generation
    )
    await cache.insertRendered(decoded, for: prematureRenderKey)
    let image = try await transformStage.image(from: decoded)
""",
    )


def mutant_016(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "  private func rollback(",
        "  private func recordCacheCleanupFailure(",
        "    if createdBlob {\n",
        "    if false && createdBlob {\n",
    )


def mutant_017(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/HTTPImageResponseProcessor.swift",
        "  func process200(",
        "  private func refreshRecord(",
        "        namespaceGeneration: generation.value,\n",
        "        namespaceGeneration: 0,\n",
    )


def mutant_018(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "  func refresh(",
        "  func renderedImage(",
        "      try await requireActive(generation, for: namespace)\n",
        "      // AIQA-MUT-018：故意让延迟刷新忽略命名空间撤销。\n",
    )


def mutant_019(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "  private func rollback(",
        "  private func recordCacheCleanupFailure(",
        "    if recordCommitted {\n",
        "    if false && recordCommitted {\n",
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
        root / "Sources/ImageCraftCore/ImageTypes.swift",
        "    self.maximumMetadataBytes = max(0, maximumMetadataBytes)\n",
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
        "  private func rollbackRefresh(",
        "  func renderedImage(",
        "      if restoreOverwrittenRecord,\n",
        "      if false,\n",
    )


def mutant_024(root: Path) -> None:
    replace_literal(
        root / "Sources/AkashicMemory/MemoryCache.swift",
        "    let maximumExistingCost = costLimit - cost\n",
        "    let maximumExistingCost = costLimit\n",
    )


def mutant_025(root: Path) -> None:
    replace_literal(
        root / "Sources/AkashicDisk/OriginalEncodedStore.swift",
        "        isValidManifest(decoded)\n",
        "        true\n",
    )


def mutant_026(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/RepresentationRecord.swift",
        "  private func bootstrap(root: URL) throws",
        "  public func records(",
        "        manifest.records.allSatisfy({ key, record in\n          isValidRecord(record, storedUnder: key)\n        })\n",
        "        true\n",
    )


def mutant_027(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/RepresentationRecord.swift",
        "  public func put(_ record: RepresentationRecord) throws",
        "  public func containsReference(",
        "    guard isValidRecord(record, storedUnder: record.variantKeyDigest) else {\n",
        "    guard true else {\n",
    )


def mutant_028(root: Path) -> None:
    replace_regex(
        root / "Sources/FoveaHTTP/URLSessionTransport.swift",
        r"  private static func expectedIdentityContentLength\(\n    from response: HTTPURLResponse\n  \) throws -> Int\? \{\n(?:.|\n)*?\n  \}\n\n  private static func headers",
        "  private static func expectedIdentityContentLength(\n    from response: HTTPURLResponse\n  ) throws -> Int? {\n    guard let raw = response.value(forHTTPHeaderField: \"Content-Length\") else { return nil }\n    return Int(raw)\n  }\n\n  private static func headers",
        flags=re.MULTILINE,
    )


def mutant_029(root: Path) -> None:
    replace_in_section(
        root / "Sources/AkashicDisk/OriginalEncodedStore.swift",
        "  private func contentIDMatches(",
        "  private func manifestKey(",
        "      ) != nil\n",
        "      ) == nil || true\n",
    )


def mutant_030(root: Path) -> None:
    replace_literal(
        root / "Sources/AkashicCore/StorageDirectorySecurity.swift",
        "      status.st_nlink == 1,\n",
        "      true,\n",
        expected_count=2,
    )


def mutant_031(root: Path) -> None:
    replace_in_section(
        root / "Sources/AkashicCore/StorageDirectorySecurity.swift",
        "  package static func validateDirectory(",
        "  package static func validateRegularFile(",
        "    guard fileType == S_IFDIR, status.st_uid == Darwin.geteuid() else {\n",
        "    guard fileType == S_IFDIR || fileType == S_IFLNK,\n      status.st_uid == Darwin.geteuid()\n    else {\n",
    )


def mutant_032(root: Path) -> None:
    replace_literal(
        root / "Sources/AkashicCore/BoundedFileReader.swift",
        "      UInt64(status.st_size) <= UInt64(maximumBytes),\n",
        "      true,\n",
    )


def mutant_033(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/RepresentationRecord.swift",
        "      record.responseTime.timeIntervalSinceReferenceDate.isFinite,\n",
        "      record.responseTime.timeIntervalSinceReferenceDate.isFinite,\n      record.responseTime >= record.requestTime,\n",
    )


def mutant_034(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/ImageRequest.swift",
        '        "\\(credentialExecutionFingerprint)|\\(networkPolicy.executionFingerprint)|\\(transportPolicyFingerprint)"\n',
        '        "\\(credentialExecutionFingerprint)|\\(transportPolicyFingerprint)"\n',
    )


def mutant_035(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FoveaPipeline.swift",
        "  private func validateAccess(",
        "  private func validateAuthorization(",
        "    guard profileAccessPolicy.permits(request) else {\n",
        "    guard true else {\n",
    )


def mutant_036(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/ImageRequest.swift",
        "  package func replacingCredentials(",
        "  }\n}",
        "      networkPolicy: networkPolicy,\n",
        "      networkPolicy: .interactive,\n",
    )


def mutant_037(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/DecodeStage.swift",
        "    let workingSetPermit: AsyncPermitPool.Permit",
        "    let image: DecodedImage",
        "        units: workingSetBytes,\n",
        "        units: 1,\n",
    )


def mutant_038(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/URLSessionTransport.swift",
        "      var response: HTTPURLResponse?",
        "      guard let response else",
        "        case .metrics(let metrics):\n          networkMetrics = metrics\n",
        "        case .metrics:\n          networkMetrics = nil\n",
    )


def mutant_039(root: Path) -> None:
    path = root / "Sources/FoveaCore/DecodeStage.swift"
    replace_in_section(
        path,
        "    let probe: ImageProbe",
        "    let workingSetBytes",
        "      await probePermit.release()\n    } catch is CancellationError {",
        "    } catch is CancellationError {",
    )
    replace_in_section(
        path,
        "    let decodePermit: AsyncPermitPool.Permit",
        "    let image: DecodedImage",
        "    let decodePermit: AsyncPermitPool.Permit\n    do {\n      decodePermit = try await acquireDecodePermit(priorityControl: priorityControl)\n    } catch {\n      await workingSetPermit.release()\n      throw error\n    }\n",
        "    let decodePermit = probePermit\n",
    )


def mutant_040(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaHTTP/HTTPURLSecurityPolicy.swift",
        '    return scheme == "http" && isLoopbackHost(host)\n',
        '    return scheme == "http" && (isLoopbackHost(host) || host.count > 0)\n',
    )


def mutant_041(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaHTTP/HTTPRedirectPolicy.swift",
        "  package static func request(",
        "  }\n}",
        "    guard let url = proposed.url, HTTPURLSecurityPolicy.permits(url) else {\n",
        "    guard proposed.url != nil else {\n",
    )


def mutant_042(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaCore/PipelineConfiguration.swift",
        r'      "maximumDecodeWorkingSetBytes:\(maximumDecodeWorkingSetBytes)",' + "\n",
        "",
    )


def mutant_043(root: Path) -> None:
    replace_literal(
        root / "Sources/FoveaSystem/FoveaSystemPipeline.swift",
        "    profileAccessPolicy: ProfileAccessPolicy = .publicOnly,\n",
        "    profileAccessPolicy: ProfileAccessPolicy = .unrestricted,\n",
    )


def mutant_044(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "    let task = Task { @concurrent [weak self] in",
        "    entries[key] = Entry(",
        "        await self?.completed(key: key, taskID: taskID)\n        return value\n",
        "        return value\n",
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
    Mutant("AIQA-MUT-009", "Accept a zero target dimension.", "Sources/ImageCraftCore/ImageTypes.swift", "IdentityTests/testZeroTargetIsRejected_GEO_PT_002", mutant_009),
    Mutant("AIQA-MUT-010", "Decode a full-size bitmap instead of a target thumbnail.", "Sources/ImageCraftImageIO/ImageIOImageDecoder.swift", "ImageDecoderTests/testTargetDecodeAvoidsFullSizeBitmap", mutant_010),
    Mutant("AIQA-MUT-011", "Keep stale elevated priority after a subscriber leaves.", "Sources/FoveaCore/SharedTaskRegistry.swift", "PrioritySchedulingTests/testSharedTaskEffectivePriorityRisesAndFallsWithSubscribers_SCHED_PT_003", mutant_011),
    Mutant("AIQA-MUT-012", "Let a stale completion remove an active task with the same key.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testMismatchedCompletionCannotRemoveActiveTask", mutant_012),
    Mutant("AIQA-MUT-013", "Use Swift hashValue as a persistent key digest.", "Sources/FoveaCore/Identity.swift", "IdentityTests/testFetchBaseKeyDigestUsesStableSHA256AiqaMut013", mutant_013),
    Mutant("AIQA-MUT-014", "Strip signed query parameters during URL normalization.", "Sources/FoveaCore/ImageRequest.swift", "IdentityTests/testURLNormalizationIsConservativeAndFragmentFree_CACHE_PT_027", mutant_014),
    Mutant("AIQA-MUT-015", "Publish RenderedMemory before transform succeeds.", "Sources/FoveaCore/ImageDeliveryCoordinator.swift", "PipelineTests/testTransformFailureRetainsOriginalAndPublishesNoRendered_CACHE_PT_030", mutant_015),
    Mutant("AIQA-MUT-016", "Leave a newly created blob behind when record publication fails.", "Sources/FoveaCore/PipelineCache.swift", "AuthGalleryTests/testRevokeDuringBlobCommitRemovesLateBlobAndRecord", mutant_016),
    Mutant("AIQA-MUT-017", "Write a post-revoke 200 record with generation zero.", "Sources/FoveaCore/HTTPImageResponseProcessor.swift", "PipelineTests/testRevokeThenNewResponsePersistsCurrentGenerationAndHitsDisk_CACHE_PT_038", mutant_017),
    Mutant("AIQA-MUT-018", "Allow a late 304 refresh to survive namespace revocation.", "Sources/FoveaCore/PipelineCache.swift", "AuthGalleryTests/testRevokeDuring304RefreshRemovesLateMetadata_AUTH_PT_011", mutant_018),
    Mutant("AIQA-MUT-019", "Leave a published record behind after generation revocation.", "Sources/FoveaCore/PipelineCache.swift", "AuthGalleryTests/testRevocationAfterRecordPublicationRollsBackRecordAndBlob_AUTH_PT_005", mutant_019),
    Mutant("AIQA-MUT-020", "Admit transient geometry into RenderedMemory.", "Sources/FoveaCore/ImageDeliveryCoordinator.swift", "TargetGeometryTests/testTransientTargetDoesNotEnterRenderedMemoryUntilStableGeoPt009", mutant_020),
    Mutant("AIQA-MUT-021", "Disable the encoded metadata byte limit.", "Sources/ImageCraftCore/ImageTypes.swift", "PipelineFailureTests/testMetadataSecurityFailurePublishesNoReusableStateSecCase004", mutant_021),
    Mutant("AIQA-MUT-022", "Create a separate DecodeKey registry for every subscriber.", "Sources/FoveaCore/DecodeStage.swift", "DecodeSharingTests/testSameDecodeKeyExecutesProbeAndDecodeOnce_SCHED_PT_002", mutant_022),
    Mutant("AIQA-MUT-023", "Delete overwritten 304 metadata instead of restoring it after cancellation.", "Sources/FoveaCore/PipelineCache.swift", "CacheRefreshTransactionTests/testCancellationAfterSameVariantRefreshRestoresPreviousRecord_CACHE_PT_039", mutant_023),
    Mutant("AIQA-MUT-024", "Allow memory-cache cost addition to overflow before eviction.", "Sources/AkashicMemory/MemoryCache.swift", "MemoryCacheTests/testCostAccountingCannotOverflowPastLimit_RES_PT_001", mutant_024),
    Mutant("AIQA-MUT-025", "Accept semantically corrupt OriginalEncoded manifests.", "Sources/AkashicDisk/OriginalEncodedStore.swift", "ManifestSemanticValidationTests/testOriginalManifestSemanticCorruptionFailsClosedWithoutRewrite_SEC_CASE_030", mutant_025),
    Mutant("AIQA-MUT-026", "Accept semantically corrupt representation manifests.", "Sources/FoveaHTTP/RepresentationRecord.swift", "ManifestSemanticValidationTests/testRepresentationManifestSemanticCorruptionFailsClosedWithoutRewrite_SEC_CASE_030", mutant_026),
    Mutant("AIQA-MUT-027", "Accept an invalid runtime representation record.", "Sources/FoveaHTTP/RepresentationRecord.swift", "ManifestSemanticValidationTests/testRecordStoreRejectsInvalidRuntimeRecordWithoutMutation_SEC_CASE_030", mutant_027),
    Mutant("AIQA-MUT-028", "Ignore malformed or conflicting Content-Length values.", "Sources/FoveaHTTP/URLSessionTransport.swift", "URLSessionTransportTests/testMalformedOrConflictingContentLengthFailsClosed_HTTP_CONF_CONTENT_LENGTH_001", mutant_028),
    Mutant("AIQA-MUT-029", "Accept a noncanonical runtime content identifier.", "Sources/AkashicDisk/OriginalEncodedStore.swift", "ManifestSemanticValidationTests/testOriginalStoreRejectsNoncanonicalRuntimeContentIDWithoutMutation_SEC_CASE_030", mutant_029),
    Mutant("AIQA-MUT-030", "Accept hard-linked managed files and lock inodes.", "Sources/AkashicCore/StorageDirectorySecurity.swift", "FilesystemLinkDefenseTests/testLockAndManifestHardLinksAreRejected_SEC_CASE_031", mutant_030),
    Mutant("AIQA-MUT-031", "Accept symbolic links as managed directories.", "Sources/AkashicCore/StorageDirectorySecurity.swift", "FilesystemLinkDefenseTests/testManagedDirectoryRejectsSymbolicLink_SEC_CASE_031", mutant_031),
    Mutant("AIQA-MUT-032", "Allocate metadata files without enforcing the pre-read size bound.", "Sources/AkashicCore/BoundedFileReader.swift", "BoundedMetadataReadTests/testOversizedStoreManifestsFailBeforeUnboundedRead_SEC_CASE_032", mutant_032),
    Mutant("AIQA-MUT-033", "Reject finite records when the wall clock moves backward during a request.", "Sources/FoveaHTTP/RepresentationRecord.swift", "ManifestSemanticValidationTests/testRecordStoreAcceptsFiniteWallClockRollback_HTTP_CONF_AGE_005", mutant_033),
    Mutant("AIQA-MUT-034", "Ignore request network permissions in exact fetch execution identity.", "Sources/FoveaCore/ImageRequest.swift", "IdentityTests/testNetworkPolicyChangesExecutionButNotPersistentIdentity_RES_PT_008", mutant_034),
    Mutant("AIQA-MUT-035", "Bypass the profile access allowlist before cache and network access.", "Sources/FoveaCore/FoveaPipeline.swift", "ProfileAccessPolicyTests/testDeniedProfileFailsBeforeCacheOrNetwork_AUTH_PT_014", mutant_035),
    Mutant("AIQA-MUT-036", "Reset request network policy while replacing credentials.", "Sources/FoveaCore/ImageRequest.swift", "AuthenticationRefreshTests/testCredentialReplacementPreservesRequestSemantics_AUTH_PT_013", mutant_036),
    Mutant("AIQA-MUT-037", "Reserve one byte instead of the estimated decode working set.", "Sources/FoveaCore/DecodeStage.swift", "ResourceLimitTests/testDecodeWorkingSetIsRejectedBeforePixelAllocation_RES_PT_013", mutant_037),
    Mutant("AIQA-MUT-038", "Drop URLSession transaction metrics before transport completion.", "Sources/FoveaHTTP/URLSessionTransport.swift", "URLSessionTransportTests/testDelegateTransportCollectsSanitizedTaskMetrics_DIAG_PT_011", mutant_038),
    Mutant("AIQA-MUT-039", "Hold the decode-count permit while waiting for working-set capacity.", "Sources/FoveaCore/DecodeStage.swift", "ResourceLimitTests/testWorkingSetWaiterDoesNotHoldDecodeCountPermit_RES_PT_014", mutant_039),
    Mutant("AIQA-MUT-040", "Accept remote cleartext HTTP image URLs.", "Sources/FoveaHTTP/HTTPURLSecurityPolicy.swift", "IdentityTests/testImageRequestRejectsRemoteCleartextButAllowsLoopback_SEC_CASE_033", mutant_040),
    Mutant("AIQA-MUT-041", "Allow HTTPS redirects to downgrade to remote cleartext HTTP.", "Sources/FoveaHTTP/HTTPRedirectPolicy.swift", "URLSessionTransportTests/testRedirectPolicyRejectsRemoteCleartextAndAllowsLoopback_SEC_CASE_033", mutant_041),
    Mutant("AIQA-MUT-042", "Omit decode working-set budget from the full configuration fingerprint.", "Sources/FoveaCore/PipelineConfiguration.swift", "PipelineConfigurationTests/testWorkingSetBudgetIsOperationalAndChangesFullFingerprint_PIPE_PT_010", mutant_042),
    Mutant("AIQA-MUT-043", "Make the official system composition root unrestricted by default.", "Sources/FoveaSystem/FoveaSystemPipeline.swift", "FoveaSystemPipelineTests/testSystemCompositionDefaultsToPublicOnly_AUTH_PT_014", mutant_043),
    Mutant("AIQA-MUT-044", "Publish a shared task result before removing its completed registry entry.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testCompletedTaskCannotBeJoinedByNewSubscriber_SCHED_PT_015", mutant_044),
]


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
    try:
        stdout, _ = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, None)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            tail, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            tail, _ = process.communicate()
        prefix = error.stdout or ""
        if isinstance(prefix, bytes):
            prefix = prefix.decode(errors="replace")
        raise subprocess.TimeoutExpired(command, timeout, output=prefix + (tail or ""))


def classify(return_code: int, output: str) -> str:
    test_started = "Test Case '" in output and " started." in output
    if return_code == 0:
        return "survived" if test_started else "invalid"
    return "killed" if test_started else "invalid"


def main() -> int:
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    if LOG_ROOT.exists():
        shutil.rmtree(LOG_ROOT)
    LOG_ROOT.mkdir(parents=True)
    if REPORT_PATH.exists():
        REPORT_PATH.unlink()

    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = subprocess.run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip()

    results: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="fovea-critical-mutants-") as temporary:
        worktree = Path(temporary) / "worktree"
        subprocess.run(
            ["git", "worktree", "add", "--detach", str(worktree), head],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=True,
        )
        try:
            for mutant in MUTANTS:
                subprocess.run(["git", "reset", "--hard", head], cwd=worktree, check=True, stdout=subprocess.DEVNULL)
                subprocess.run(["git", "clean", "-fd"], cwd=worktree, check=True, stdout=subprocess.DEVNULL)
                log_path = LOG_ROOT / f"{mutant.identifier}.log"
                status = "invalid"
                return_code = -1
                output = ""
                try:
                    mutant.apply(worktree)
                    completed = run(
                        ["xcrun", "swift", "test", "--filter", mutant.test_filter],
                        worktree,
                        env,
                        timeout=180,
                    )
                    return_code = completed.returncode
                    output = completed.stdout
                    status = classify(return_code, output)
                except subprocess.TimeoutExpired as error:
                    output = f"mutation test timed out after {error.timeout} seconds\n{error.stdout or ''}"
                except Exception as error:  # noqa: BLE001 - 门禁需要记录每个无效变异。
                    output = f"mutation application failed: {error}\n"
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
                print(f"{mutant.identifier}: {status} ({mutant.test_filter})")
        finally:
            subprocess.run(
                ["git", "worktree", "remove", "--force", str(worktree)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )

    summary = {
        "required": len(MUTANTS),
        "killed": sum(item["status"] == "killed" for item in results),
        "survived": sum(item["status"] == "survived" for item in results),
        "invalid": sum(item["status"] == "invalid" for item in results),
    }
    report = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "producer": "agent-declared",
        "verifiedCommit": head,
        "requiredMutants": [mutant.identifier for mutant in MUTANTS],
        "summary": summary,
        "mutants": results,
    }
    REPORT_PATH.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"Mutation report: {REPORT_PATH.relative_to(ROOT)} sha256:{sha256(REPORT_PATH)}")
    if summary["survived"] or summary["invalid"]:
        print("Critical mutation gate failed", file=sys.stderr)
        return 1
    print("Critical mutation gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
