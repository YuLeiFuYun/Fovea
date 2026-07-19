#!/usr/bin/env python3
from __future__ import annotations

import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
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
        "    // AIQA-MUT-001: namespace deliberately omitted.\n",
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
        root / "Sources/FoveaCore/ImageRequest.swift",
        "package func fetchExecutionKey(",
        "public var displayIdentity",
        "      credentialGeneration: credentialGeneration,\n",
        "      credentialGeneration: nil,\n",
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
        root / "Sources/FoveaCore/FoveaPipeline.swift",
        "private func process304(",
        "private func process200(",
        "      contentID: existing.contentID,\n",
        '      contentID: "sha256:\\(String(repeating: \"0\", count: 64)):0",\n',
    )


def mutant_006(root: Path) -> None:
    candidates = list((root / "Sources/FoveaHTTP").glob("*.swift"))
    for path in candidates:
        text = path.read_text()
        if "fieldNames.allSatisfy" not in text:
            continue
        replace_regex(
            path,
            r"(?m)^(\s*)(return\s+)?fieldNames\.allSatisfy",
            r"\1\2true || fieldNames.allSatisfy",
        )
        return
    raise RuntimeError("HTTPVarySelection.matches implementation was not found")


def mutant_007(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FoveaPipeline.swift",
        "private func process200(",
        "private func decodeAndCache(",
        "    if disposition != .noStore {\n",
        "    if true {\n",
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
        "package func release(key: Key, subscriberID: UUID) async",
        "package func subscriberCount",
        "      await entry.priorityControl.update(effective)\n",
        "      // AIQA-MUT-011: effective priority is never lowered.\n",
    )


def mutant_012(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/SharedTaskRegistry.swift",
        "  func resolve(_ result:",
        "  }\n}",
        "      state = .finished\n      continuation.resume(with: result)\n",
        "      continuation.resume(with: result)\n",
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
    cache = root / "Sources/FoveaCore/PipelineCache.swift"
    pipeline = root / "Sources/FoveaCore/FoveaPipeline.swift"
    replace_in_section(
        cache,
        "  func commit(",
        "  private func rollback(",
        "  func commit(\n",
        """  func publishUnsafeOriginal(
    data: Data,
    contentID: ContentID,
    baseKeyDigest: String,
    variantKeyDigest: String,
    vary: HTTPVarySelection,
    namespace: SecurityNamespaceID,
    generation: NamespaceGeneration
  ) async {
    _ = try? await encodedStore.commit(
      data: data,
      contentID: contentID.description,
      namespace: namespace.value
    )
    try? await recordStore.put(
      RepresentationRecord(
        securityNamespace: namespace.value,
        namespaceGeneration: generation.value,
        baseKeyDigest: baseKeyDigest,
        variantKeyDigest: variantKeyDigest,
        vary: vary,
        statusCode: 200,
        requestTime: Date(),
        responseTime: Date(),
        responseDate: Date(),
        expiresAt: nil,
        etag: nil,
        lastModified: nil,
        disposition: .reusable,
        contentID: contentID.description,
        payloadLength: data.count,
        contentType: nil
      )
    )
  }

  func commit(
""",
    )
    marker = "    let image = try await decodeStage.image(\n"
    prefix, body, suffix = section(pipeline, "private func process200(", "private func decodeAndCache(")
    index = body.find(marker)
    if index < 0:
        raise RuntimeError("process200 decode call not found")
    insertion = """    await cache.publishUnsafeOriginal(
      data: response.transport.body,
      contentID: contentID,
      baseKeyDigest: request.fetchBaseKey.digestHex,
      variantKeyDigest: variant.digestHex,
      vary: varySelection ?? HTTPVarySelection(fieldNames: [], values: [:]),
      namespace: request.namespace,
      generation: generation
    )
"""
    pipeline.write_text(prefix + body[:index] + insertion + body[index:] + suffix)


def mutant_016(root: Path) -> None:
    path = root / "Sources/FoveaCore/PipelineCache.swift"
    old = """      await diagnostics.record(
        DiagnosticEvent(
          kind: .cacheWriteFailed,
          keyDigest: record.variantKeyDigest,
          reason: "encoded-or-record-write"
        )
      )
"""
    new = old + """      throw PipelineFailure(
        category: .cacheWrite,
        stage: .persistence,
        disposition: .cacheDegraded,
        reasonCode: "mutated-cache-write-overrides-final"
      )
"""
    replace_in_section(path, "  func commit(", "  private func rollback(", old, new)


def mutant_017(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/FoveaPipeline.swift",
        "private func process200(",
        "private func decodeAndCache(",
        "        namespaceGeneration: generation.value,\n",
        "        namespaceGeneration: 0,\n",
    )


def mutant_018(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "  func refresh(",
        "  func renderedImage(",
        "      try await requireActive(generation, for: namespace)\n",
        "      // AIQA-MUT-018: late refresh ignores namespace revocation.\n",
    )


def mutant_019(root: Path) -> None:
    replace_in_section(
        root / "Sources/FoveaCore/PipelineCache.swift",
        "  func discardReusableState(",
        "  func commit(",
        "    if !stillReferenced {\n",
        "    if true {\n",
    )


def mutant_020(root: Path) -> None:
    path = root / "Sources/FoveaCore/FoveaPipeline.swift"
    replace_literal(
        path,
        "request.renderCacheAdmission == .stable",
        "true",
        expected_count=2,
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


MUTANTS = [
    Mutant("AIQA-MUT-001", "Omit namespace from persistent base identity.", "Sources/FoveaCore/Identity.swift", "IdentityTests/testNamespaceChangesBaseAndVariantIdentity_CACHE_PT_003", mutant_001),
    Mutant("AIQA-MUT-002", "Collapse exact fetch execution identity to base-only dimensions.", "Sources/FoveaCore/ImageRequest.swift", "IdentityTests/testImageRequestExecutionKeyIncludesCredentialAndRevalidation", mutant_002),
    Mutant("AIQA-MUT-003", "Ignore credential generation in exact execution identity.", "Sources/FoveaCore/ImageRequest.swift", "IdentityTests/testCredentialRefreshChangesExecutionButNotBaseOrVariant_AUTH_PT_001", mutant_003),
    Mutant("AIQA-MUT-004", "Treat every persistent representation as fresh.", "Sources/FoveaHTTP/RepresentationRecord.swift", "PipelineTests/testInjectedClockControlsFreshnessWithoutSleeping", mutant_004),
    Mutant("AIQA-MUT-005", "Replace the validated 304 content identity.", "Sources/FoveaCore/FoveaPipeline.swift", "PipelineTests/test304ReusesContentID_CACHE_PT_008", mutant_005),
    Mutant("AIQA-MUT-006", "Reuse a Vary candidate even when selected request fields mismatch.", "Sources/FoveaHTTP/HTTPCachePolicy.swift", "VaryCacheTests/testAcceptLanguageVariantsCoexistAndHitCorrectBodies_CACHE_PT_004", mutant_006),
    Mutant("AIQA-MUT-007", "Publish Cache-Control no-store responses into reusable caches.", "Sources/FoveaCore/FoveaPipeline.swift", "PipelineTests/testNoStoreNeverSatisfiesNewRequest_CACHE_PT_026", mutant_007),
    Mutant("AIQA-MUT-008", "Allow persistence after namespace generation revocation.", "Sources/FoveaCore/PipelineCache.swift", "AuthGalleryTests/testRevokeDuringBlobCommitRemovesLateBlobAndRecord", mutant_008),
    Mutant("AIQA-MUT-009", "Accept a zero target dimension.", "Sources/ImageCraftCore/ImageTypes.swift", "IdentityTests/testZeroTargetIsRejected_GEO_PT_002", mutant_009),
    Mutant("AIQA-MUT-010", "Decode a full-size bitmap instead of a target thumbnail.", "Sources/ImageCraftImageIO/ImageIOImageDecoder.swift", "ImageDecoderTests/testTargetDecodeAvoidsFullSizeBitmap", mutant_010),
    Mutant("AIQA-MUT-011", "Keep stale elevated priority after a subscriber leaves.", "Sources/FoveaCore/SharedTaskRegistry.swift", "PrioritySchedulingTests/testSharedTaskEffectivePriorityRisesAndFallsWithSubscribers_SCHED_PT_003", mutant_011),
    Mutant("AIQA-MUT-012", "Permit completion and cancellation to resume one continuation twice.", "Sources/FoveaCore/SharedTaskRegistry.swift", "SharedTaskTests/testCompletionAndReleaseDoNotDoubleCancel_SCHED_PT_010", mutant_012),
    Mutant("AIQA-MUT-013", "Use Swift hashValue as a persistent key digest.", "Sources/FoveaCore/Identity.swift", "IdentityTests/testFetchBaseKeyDigestUsesStableSHA256AiqaMut013", mutant_013),
    Mutant("AIQA-MUT-014", "Strip signed query parameters during URL normalization.", "Sources/FoveaCore/ImageRequest.swift", "IdentityTests/testURLNormalizationIsConservativeAndFragmentFree_CACHE_PT_027", mutant_014),
    Mutant("AIQA-MUT-015", "Publish OriginalEncoded bytes before probe/decode succeeds.", "Sources/FoveaCore/FoveaPipeline.swift", "PipelineTests/testProbeFailureDoesNotPublishRecord_CACHE_PT_029_AIQA_MUT_015", mutant_015),
    Mutant("AIQA-MUT-016", "Let a cache write degradation overwrite a successful image.", "Sources/FoveaCore/PipelineCache.swift", "StagingAndStorageTests/testCacheWriteFailureDoesNotOverrideFinal_ERR_PT_001", mutant_016),
    Mutant("AIQA-MUT-017", "Write a post-revoke 200 record with generation zero.", "Sources/FoveaCore/FoveaPipeline.swift", "PipelineTests/testRevokeThenNewResponsePersistsCurrentGenerationAndHitsDisk_CACHE_PT_038", mutant_017),
    Mutant("AIQA-MUT-018", "Allow a late 304 refresh to survive namespace revocation.", "Sources/FoveaCore/PipelineCache.swift", "AuthGalleryTests/testRevokeDuring304RefreshRemovesLateMetadata_AUTH_PT_011", mutant_018),
    Mutant("AIQA-MUT-019", "Delete a blob still referenced by another Vary representation.", "Sources/FoveaCore/PipelineCache.swift", "VaryCacheTests/testNoStoreRevalidationRemovesOnlySelectedVariant_CACHE_PT_005", mutant_019),
    Mutant("AIQA-MUT-020", "Admit transient geometry into RenderedMemory.", "Sources/FoveaCore/FoveaPipeline.swift", "TargetGeometryTests/testTransientTargetDoesNotEnterRenderedMemoryUntilStableGeoPt009", mutant_020),
    Mutant("AIQA-MUT-021", "Disable the encoded metadata byte limit.", "Sources/ImageCraftCore/ImageTypes.swift", "PipelineFailureTests/testMetadataSecurityFailurePublishesNoReusableStateSecCase004", mutant_021),
    Mutant("AIQA-MUT-022", "Create a separate DecodeKey registry for every subscriber.", "Sources/FoveaCore/DecodeStage.swift", "DecodeSharingTests/testSameDecodeKeyExecutesProbeAndDecodeOnce_SCHED_PT_002", mutant_022),
]


def run(command: list[str], cwd: Path, env: dict[str, str], timeout: int) -> subprocess.CompletedProcess[str]:
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
                except Exception as error:  # noqa: BLE001 - gate records every invalid mutation.
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
