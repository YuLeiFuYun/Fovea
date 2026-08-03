#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
allowed = {
    "FoveaStorage",
    "FoveaCore",
    "FoveaHTTP",
    "FoveaPersistence",
    "FoveaSystem",
    "FoveaAdvancedSystem",
    "FoveaObservability",
    "FoveaUIKit",
    "FoveaAppKit",
    "FoveaSwiftUI",
    "FoveaTesting",
}

source_root = root / "Sources"
actual = {path.name for path in source_root.iterdir() if path.is_dir()}
unexpected = sorted(actual - allowed)
missing = sorted(allowed - actual)

package = (root / "Package.swift").read_text()
forbidden_products = {
    "FoveaLab", "FoveaTrust", "FoveaVision", "FoveaAdaptive",
    "FoveaAnalysis", "FoveaDerived", "FoveaAnimation",
}
found_forbidden = sorted(
    name for name in forbidden_products if re.search(rf"\b{re.escape(name)}\b", package)
)

errors: list[str] = []
if unexpected:
    errors.append(f"unexpected Sources modules: {unexpected}")
if missing:
    errors.append(f"missing required Sources modules: {missing}")
if found_forbidden:
    errors.append(f"forbidden production products: {found_forbidden}")
if '.library(name: "FoveaTesting"' in package:
    errors.append("FoveaTesting must remain an internal test-support target, not a public product")
public_library_products = set(re.findall(r'\.library\(\s*name:\s*"([A-Za-z0-9]+)"', package))
if public_library_products != {"Fovea", "FoveaAdvanced"}:
    errors.append(
        "public library products must be exactly the safe Fovea surface and advanced escape hatch: "
        f"{sorted(public_library_products)}"
    )
for product, component in (
    ("ImageCraftCore", "ImageCraft"),
    ("ImageCraftImageIO", "ImageCraft"),
    ("AkashicCore", "Akashic"),
    ("AkashicMemory", "Akashic"),
    ("AkashicDisk", "Akashic"),
):
    token = f'.product(name: "{product}", package: "{component}")'
    if token not in package:
        errors.append(f"Package.swift must consume external product {component}.{product}")


legacy_paths = [
    root / "Tests/FoveaPhase0aTests",
    root / "scripts/verify-phase0a.sh",
    root / "scripts/check-phase0a-surface.py",
    root / ".github/workflows/phase0a.yml",
    root / "docs/specifications/phase-0a-surface.md",
]
for legacy in legacy_paths:
    if legacy.exists():
        errors.append(f"legacy stage-specific path must be removed: {legacy.relative_to(root)}")
if not (root / "Tests/FoveaTests").is_dir():
    errors.append("stage-independent FoveaTests target directory is missing")
if 'name: "FoveaTests"' not in package:
    errors.append("Package.swift must declare the stage-independent FoveaTests target")
if not (root / "docs/specifications/core-surface.md").is_file():
    errors.append("current core surface specification is missing")

# AkashicMemory 是外部通用缓存引擎，不是 Fovea-owned target。
if (source_root / "AkashicMemory").exists():
    errors.append("AkashicMemory production source must remain external to Fovea")
if '.product(name: "AkashicMemory", package: "Akashic")' not in package:
    errors.append("FoveaCore must consume the external AkashicMemory product")


# FoveaStorage 是 Fovea 领域存储契约的最小环切割模块；它只依赖通用 AkashicCore。
storage_target = re.search(
    r'\.target\(\s*name:\s*"FoveaStorage",(?P<body>[\s\S]*?)\n\s*\),', package
)
if storage_target is None:
    errors.append("FoveaStorage target declaration not found")
else:
    body = storage_target.group("body")
    if '"AkashicCore"' not in body:
        errors.append("FoveaStorage must depend on AkashicCore for typed physical identities")
    for forbidden_dependency in ("AkashicDisk", "FoveaHTTP", "FoveaPersistence", "FoveaCore"):
        if f'"{forbidden_dependency}"' in body:
            errors.append(f"FoveaStorage must not depend on {forbidden_dependency}")
for path in sorted((source_root / "FoveaStorage").rglob("*.swift")):
    text = path.read_text()
    for forbidden_import in ("AkashicDisk", "FoveaHTTP", "FoveaPersistence", "FoveaCore"):
        if f"import {forbidden_import}" in text:
            errors.append(f"FoveaStorage crossed implementation boundary in {path.relative_to(root)}: {forbidden_import}")
fovea_security = source_root / "FoveaStorage/FoveaManagedFileSecurity.swift"
if not fovea_security.is_file():
    errors.append("Fovea-managed filesystem security helper is missing")
else:
    security_source = fovea_security.read_text()
    for required in (
        "package enum FoveaManagedFileSecurity",
        "status.st_mode & 0o077 == 0",
        "status.st_nlink == 1",
        "Darwin.lstat",
        "Darwin.fstat",
    ):
        if required not in security_source:
            errors.append(f"Fovea filesystem security invariant drifted: {required}")
for module in ("FoveaCore", "FoveaHTTP", "FoveaPersistence", "FoveaTesting"):
    for path in sorted((source_root / module).rglob("*.swift")):
        if "StorageDirectorySecurity" in path.read_text():
            errors.append(f"Fovea source still depends on Akashic package-only filesystem helper: {path.relative_to(root)}")

# Akashic targets must remain domain-neutral. Fovea identity, namespace, revoke and original-byte
# contracts live in FoveaStorage; legacy differential implementations live in FoveaPersistence.
akashic_domain_tokens = (
    "OriginalEncoded",
    "StorageNamespaceFingerprint",
    "NamespaceGenerationPersisting",
    "NamespaceStorageLimits",
    "StoredContentReference",
    "StoredBlob",
    "GarbageCollectionResult",
    "fovea-storage-namespace",
)
for module in ("AkashicCore", "AkashicDisk"):
    for path in sorted((source_root / module).rglob("*.swift")):
        text = path.read_text()
        for token in akashic_domain_tokens:
            if token in text:
                errors.append(f"{module} Fovea domain leak in {path.relative_to(root)}: {token}")

# FoveaCore consumes storage capabilities but never the concrete disk implementation.
fovea_target = re.search(
    r'\.target\(\s*name:\s*"FoveaCore",(?P<body>[\s\S]*?)\n\s*\),', package
)
if fovea_target is None:
    errors.append("FoveaCore target declaration not found")
elif '"AkashicDisk"' in fovea_target.group("body"):
    errors.append("FoveaCore must not depend on the concrete AkashicDisk product")
for path in sorted((source_root / "FoveaCore").rglob("*.swift")):
    if "import AkashicDisk" in path.read_text():
        errors.append(f"FoveaCore concrete disk import: {path.relative_to(root)}")
if not (source_root / "FoveaStorage/OriginalEncodedStoring.swift").is_file():
    errors.append("OriginalEncodedStoring contract must live in FoveaStorage")
if (source_root / "AkashicCore/OriginalEncodedStoring.swift").exists():
    errors.append("OriginalEncodedStoring must not remain in AkashicCore")
for retired_name in (
    "OriginalEncodedStore.swift",
    "OriginalEncodedStoreIdentity.swift",
    "OriginalEncodedAccessJournal.swift",
    "OriginalEncodedPhysicalRemovalSummary.swift",
):
    if (source_root / "FoveaPersistence" / retired_name).exists():
        errors.append(f"retired legacy Fovea store must remain removed: {retired_name}")
limits_path = source_root / "FoveaPersistence/OriginalEncodedStoreLimits.swift"
if not limits_path.is_file() or "package struct OriginalEncodedStoreLimits" not in limits_path.read_text():
    errors.append("FoveaPersistence must retain only package-owned typed adapter limits")

swiftui_source = "\n".join(
    path.read_text() for path in sorted((source_root / "FoveaSwiftUI").rglob("*.swift"))
)
if "public final class FoveaImageModel" in swiftui_source:
    errors.append("FoveaImageModel is an implementation detail and must remain package-only")

# HTTP 模块只拥有表征语义与 transport；具体 representation manifest actor 属于持久化层。
record_store_path = source_root / "FoveaPersistence/RepresentationRecordStore.swift"
if not record_store_path.is_file():
    errors.append("RepresentationRecordStore concrete implementation must live in FoveaPersistence")
for path in sorted((source_root / "FoveaHTTP").rglob("*.swift")):
    if "actor RepresentationRecordStore" in path.read_text():
        errors.append(
            f"FoveaHTTP must not own the concrete representation manifest store: {path.relative_to(root)}"
        )
record_store_source = record_store_path.read_text() if record_store_path.is_file() else ""
if "public actor RepresentationRecordStore" in record_store_source:
    errors.append("RepresentationRecordStore must remain a package implementation detail")

# 生产可观测性适配器独立于 Core；Core 不得直接依赖 OSLog。
observability_path = source_root / "FoveaObservability/OSLogDiagnosticsSink.swift"
emitter_path = source_root / "FoveaObservability/SystemOSLogDiagnosticsEmitter.swift"
if not observability_path.is_file() or not emitter_path.is_file():
    errors.append("FoveaObservability OSLog diagnostics adapter is missing")
else:
    observability_source = observability_path.read_text()
    emitter_source = emitter_path.read_text()
    if "privacy: .public" in emitter_source or "%{public}@" in emitter_source:
        errors.append("FoveaObservability dynamic OSLog payloads must not be public")
    if "privacy: .private" not in emitter_source or "%{private}@" not in emitter_source:
        errors.append("FoveaObservability must mark log and signpost payloads private")
    for required in ("OSLogDiagnosticsSink", "DiagnosticsSink"):
        if required not in observability_source:
            errors.append(f"FoveaObservability sink is incomplete: {required}")
    if "import OSLog" in observability_source:
        errors.append("OSLogDiagnosticsSink must not directly own the system OSLog adapter")
    if "import OSLog" not in emitter_source or "SystemOSLogDiagnosticsEmitter" not in emitter_source:
        errors.append("FoveaObservability system emitter is incomplete")
for path in sorted((source_root / "FoveaCore").rglob("*.swift")):
    if "import OSLog" in path.read_text():
        errors.append(f"FoveaCore must not depend directly on OSLog: {path.relative_to(root)}")

# FoveaAdvancedSystem 是唯一允许公开 qualified persistent bundle seam 的模块。
# 默认 Fovea product 不包含它；高级模块只能把完整 provider bundle 交回 FoveaSystem，
# 不能重新暴露 encoded/record/namespace 三个裸 hook 或直接打开默认 registry。
advanced_target = re.search(
    r'\.target\(\s*name:\s*"FoveaAdvancedSystem",(?P<body>[\s\S]*?)\n\s*\),', package
)
if advanced_target is None:
    errors.append("FoveaAdvancedSystem target declaration not found")
else:
    advanced_body = advanced_target.group("body")
    for required_dependency in (
        "AkashicCore", "FoveaCore", "FoveaHTTP", "FoveaPersistence", "FoveaStorage",
        "FoveaSystem", "ImageCraftCore", "ImageCraftImageIO",
    ):
        if f'"{required_dependency}"' not in advanced_body:
            errors.append(
                f"FoveaAdvancedSystem dependency is missing: {required_dependency}"
            )
    for forbidden_dependency in ("AkashicDisk", "AkashicMemory", "FoveaTesting"):
        if f'"{forbidden_dependency}"' in advanced_body:
            errors.append(
                f"FoveaAdvancedSystem must not depend on {forbidden_dependency}"
            )
advanced_source = "\n".join(
    path.read_text() for path in sorted((source_root / "FoveaAdvancedSystem").rglob("*.swift"))
)
for required in (
    "persistentStoreProvider: any FoveaPersistentStoreBundleProviding",
    "stores.descriptor == persistentStoreProvider.descriptor",
    "openQualified(",
):
    if required not in advanced_source:
        errors.append(f"FoveaAdvancedSystem qualified bundle boundary is incomplete: {required}")
for forbidden in (
    "FoveaPersistentStores.open",
    "PersistentStoreRegistry",
    "encodedStore:",
    "recordStore:",
):
    if forbidden in advanced_source:
        errors.append(f"FoveaAdvancedSystem exposes or opens a forbidden raw store path: {forbidden}")
advanced_product = re.search(
    r'\.library\(\s*name:\s*"FoveaAdvanced",(?P<body>[\s\S]*?)\n\s*\),', package
)
if advanced_product is None:
    errors.append("FoveaAdvanced product declaration not found")
else:
    advanced_product_body = advanced_product.group("body")
    for required_target in ("FoveaAdvancedSystem", "FoveaSystem"):
        if f'"{required_target}"' not in advanced_product_body:
            errors.append(f"FoveaAdvanced product must include {required_target}")
safe_product = re.search(
    r'\.library\(\s*name:\s*"Fovea",(?P<body>[\s\S]*?)\n\s*\),', package
)
if safe_product is not None and '"FoveaAdvancedSystem"' in safe_product.group("body"):
    errors.append("safe Fovea product must not expose FoveaAdvancedSystem")

observability_target = re.search(
    r'\.target\(\s*name:\s*"FoveaObservability",(?P<body>[\s\S]*?)\n\s*\),', package
)
if observability_target is None:
    errors.append("FoveaObservability target declaration not found")
else:
    dependency_names = set(re.findall(r'"([A-Za-z0-9]+)"', observability_target.group("body")))
    if dependency_names != {"FoveaCore"}:
        errors.append(
            f"FoveaObservability must depend only on FoveaCore: {sorted(dependency_names)}"
        )

# 恢复矩阵只有 Core 一个所有者。平台层直接消费 Core 结果，不再暴露零逻辑包装器，
# 也不得按 category/disposition 复制一份平台分支表。
for adapter in ("FoveaUIKit", "FoveaAppKit", "FoveaSwiftUI"):
    adapter_source = "\n".join(
        path.read_text() for path in sorted((source_root / adapter).rglob("*.swift"))
    )
    if "ImageFailurePolicy" in adapter_source:
        errors.append(f"{adapter} must not expose a redundant image failure policy adapter")
    if re.search(r"failure\.(category|disposition)", adapter_source):
        errors.append(f"{adapter} must not duplicate the Core failure matrix")
if ".imageRecoveryAction" not in swiftui_source:
    errors.append("FoveaSwiftUI must consume the centralized Core recovery action directly")

# 原图解码不得通过隐式快捷入口绕过显式 TargetPixels。
product_source = "\n".join(path.read_text() for path in sorted(source_root.rglob("*.swift")))
if re.search(r"\boriginalSize\b", product_source):
    errors.append("implicit original-size API is forbidden; callers must provide TargetPixels")
if re.search(r"public\s+func\s+image\s*\(\s*for\s+[^:]+:\s*URL\b", product_source):
    errors.append("public URL image shortcut must not bypass explicit target pixels")

# 管线只能由组合根显式构造；扩展模块不得通过全局默认实例或注册钩子改变行为。
fovea_core_source = "\n".join(
    path.read_text() for path in sorted((source_root / "FoveaCore").rglob("*.swift"))
)
for forbidden in (
    "FoveaPipeline.shared",
    "FoveaPipeline.default",
    "registerGlobal",
    "globalPipelineRegistry",
    "globalDecoderRegistry",
    "globalTransportRegistry",
):
    if forbidden in fovea_core_source:
        errors.append(f"automatic pipeline composition is forbidden: {forbidden}")

# 自适应控制器只能优化已授权工作的调度，不能自行改写身份、权限、持久化或网络政策。
# 这把研究型策略限制在 L4 控制面；L1-L3 仍由不可变请求、namespace 与 transport 契约拥有。
adaptive_control_paths = (
    source_root / "FoveaCore/AdaptiveImageLoadAdmission.swift",
    source_root / "FoveaCore/AdaptiveEncodedWarmupCoordinator.swift",
)
adaptive_forbidden_tokens = (
    "ProfileAccessPolicy",
    "NamespaceRegistry",
    "HTTPDestinationPolicy",
    "URLSessionTransport",
    "OriginalEncodedStoring",
    "RepresentationRecord",
    "RenderedImageCaching",
    "FoveaPersistentStores",
)
for path in adaptive_control_paths:
    if not path.is_file():
        errors.append(f"adaptive control source is missing: {path.relative_to(root)}")
        continue
    adaptive_source = path.read_text()
    if re.search(r"(?m)^\s*public\s+", adaptive_source):
        errors.append(
            f"adaptive control must remain package-only until an external policy contract exists: {path.relative_to(root)}"
        )
    for token in adaptive_forbidden_tokens:
        if token in adaptive_source:
            errors.append(
                f"adaptive control crossed an authority or persistence boundary in {path.relative_to(root)}: {token}"
            )

# 默认 Apple codec 路径保持静态、进程内和显式注入。WASI、动态库或进程隔离若将来需要，
# 必须进入独立 adapter target，并通过同一语义契约，而不是渗入 ImageIO 快路径。
default_codec_boundary_paths = (
    source_root / "FoveaCore/DecodeStage.swift",
    source_root / "FoveaSystem/FoveaSystemPipeline.swift",
)
for path in default_codec_boundary_paths:
    codec_source = path.read_text()
    for token in ("dlopen(", "NSXPCConnection", "Wasmtime", "import WASI", "Process("):
        if token in codec_source:
            errors.append(
                f"default codec path acquired an execution-loader dependency in {path.relative_to(root)}: {token}"
            )

# 派生身份必须同时绑定源内容、codec 语义、transform 语义与 namespace authority epoch。
# 缺少任一项都可能让 revoke 后的旧 artifact 或不同后端像素错误复用。
derivation_identity_requirements = {
    "Sources/FoveaCore/Identity.swift": (
        "public let contentID: ContentID",
        "package let codecFingerprint: String",
        "public let transformerFingerprint: String",
    ),
    "Sources/FoveaCore/ImageDeliveryCoordinator.swift": (
        "codecFingerprint: decodeStage.codecDescriptor.cacheFingerprint",
        "transformerFingerprint: transformStage.fingerprint",
        "generation: generation",
    ),
}
for relative, required_tokens in derivation_identity_requirements.items():
    derivation_source = (root / relative).read_text()
    for token in required_tokens:
        if token not in derivation_source:
            errors.append(f"artifact derivation identity is incomplete in {relative}: {token}")

local_evidence = root / "evidence/local"
if local_evidence.is_dir():
    snapshots = [path for path in local_evidence.iterdir() if not path.name.startswith(".")]
    if len(snapshots) > 1:
        errors.append("evidence/local must contain at most one latest snapshot")

# 生产代码不得削弱严格并发检查；锁保护的极少数引用类型必须进入精确审计清单。
unchecked_allowlist_path = root / "docs/research/unchecked-sendable-allowlist.json"
if not unchecked_allowlist_path.is_file():
    errors.append("unchecked Sendable audit allowlist is missing")
    unchecked_allowlist: dict[str, dict[str, object]] = {}
else:
    unchecked_document = json.loads(unchecked_allowlist_path.read_text())
    if (
        unchecked_document.get("schemaVersion") != 1
        or unchecked_document.get("allowlistID")
        != "FOVEA-UNCHECKED-SENDABLE-ALLOWLIST-V1"
    ):
        errors.append("unchecked Sendable audit allowlist identity is invalid")
    unchecked_allowlist = {
        entry.get("path"): entry
        for entry in unchecked_document.get("entries", [])
        if isinstance(entry, dict) and isinstance(entry.get("path"), str)
    }

unchecked_locations = {
    str(path.relative_to(root)): path
    for path in sorted(source_root.rglob("*.swift"))
    if "@unchecked Sendable" in path.read_text()
}
for relative in sorted(unchecked_locations.keys() - unchecked_allowlist.keys()):
    errors.append(f"unaudited unchecked Sendable in production source: {relative}")
for relative in sorted(unchecked_allowlist.keys() - unchecked_locations.keys()):
    errors.append(f"stale unchecked Sendable allowlist entry: {relative}")
for relative, entry in sorted(unchecked_allowlist.items()):
    path = root / relative
    if not path.is_file():
        errors.append(f"unchecked Sendable allowlist path is missing: {relative}")
        continue
    text = path.read_text()
    for token in entry.get("requiredTokens", []):
        if not isinstance(token, str) or token not in text:
            errors.append(f"unchecked Sendable audit token missing in {relative}: {token}")
    reason = entry.get("reason")
    if not isinstance(reason, str) or len(reason) < 80:
        errors.append(f"unchecked Sendable audit reason is incomplete: {relative}")
    evidence = entry.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        errors.append(f"unchecked Sendable audit evidence is missing: {relative}")
    else:
        for evidence_path in evidence:
            if not isinstance(evidence_path, str) or not (root / evidence_path).exists():
                errors.append(
                    f"unchecked Sendable audit evidence path is missing: {relative}: {evidence_path}"
                )


# 非测试生产源文件保持可审查；超过 500 行必须有内容摘要绑定的 cohesion review。
cohesion_path = root / "docs/research/production-cohesion-reviews.json"
cohesion_reviews: dict[str, dict[str, object]] = {}
if not cohesion_path.is_file():
    errors.append("production cohesion review registry is missing")
else:
    cohesion_document = json.loads(cohesion_path.read_text())
    if (
        cohesion_document.get("schemaVersion") != 1
        or cohesion_document.get("reviewID") != "FOVEA-PRODUCTION-COHESION-REVIEWS-V1"
    ):
        errors.append("production cohesion review registry identity is invalid")
    cohesion_reviews = {
        entry.get("path"): entry
        for entry in cohesion_document.get("entries", [])
        if isinstance(entry, dict) and isinstance(entry.get("path"), str)
    }

large_production_sources: dict[str, Path] = {}
for path in sorted(source_root.rglob("*.swift")):
    relative = str(path.relative_to(root))
    text = path.read_text()
    if "FoveaTesting" not in path.parts and len(text.splitlines()) > 500:
        large_production_sources[relative] = path
    if re.search(r"\btry!\b|\bas!\b", text):
        errors.append(f"forced error/type conversion in production source: {relative}")
    if path.name in {"Utils.swift", "Util.swift", "Helpers.swift", "Helper.swift", "Common.swift", "Misc.swift"}:
        errors.append(f"generic source filename hides responsibility: {relative}")

for relative in sorted(large_production_sources.keys() - cohesion_reviews.keys()):
    errors.append(f"production source exceeds 500 lines and needs a cohesion review: {relative}")
for relative in sorted(cohesion_reviews.keys() - large_production_sources.keys()):
    errors.append(f"stale production cohesion review entry: {relative}")
for relative, entry in sorted(cohesion_reviews.items()):
    path = large_production_sources.get(relative)
    if path is None:
        continue
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if entry.get("sha256") != digest:
        errors.append(f"production cohesion review digest is stale: {relative}")
    if entry.get("reviewedLineCount") != len(data.decode().splitlines()):
        errors.append(f"production cohesion review line count is stale: {relative}")
    reason = entry.get("reason")
    if not isinstance(reason, str) or len(reason) < 120:
        errors.append(f"production cohesion review reason is incomplete: {relative}")
    for field in ("responsibilities", "splitTriggers", "evidence"):
        values = entry.get(field)
        if not isinstance(values, list) or not values or not all(isinstance(v, str) and v for v in values):
            errors.append(f"production cohesion review {field} is incomplete: {relative}")
    for evidence_path in entry.get("evidence", []):
        if not (root / evidence_path).exists():
            errors.append(f"production cohesion review evidence is missing: {relative}: {evidence_path}")

# 官方 URLSession transport 不接受配置对象中的环境凭证或隐式全局 header。
transport_source = (source_root / "FoveaHTTP/URLSessionTransport.swift").read_text()
for required in (
    "configuration.urlCredentialStorage = nil",
    "configuration.httpAdditionalHeaders = nil",
    "configuration.httpCookieStorage = nil",
    "configuration.urlCache = nil",
):
    if required not in transport_source:
        errors.append(f"URLSession transport ambient state sanitization is missing: {required}")

# 零订阅者共享任务只能在有界 handoff lease 内存活。
shared_task_source = (source_root / "FoveaCore/SharedTaskRegistry.swift").read_text()
for required in (
    "handoffGraceNanoseconds",
    "expireOrphanedTask",
    "orphanLeaseID",
    "CancellationTombstone",
    "expireCancellationTombstone",
    "retainingCancelledTaskForNanoseconds",
):
    if required not in shared_task_source:
        errors.append(f"shared-task orphan cleanup contract is missing: {required}")


# 网络目的地策略必须同时覆盖缓存前 ACL、初始 task、redirect 与 execution identity。
destination_path = source_root / "FoveaHTTP/HTTPDestinationPolicy.swift"
if not destination_path.is_file():
    errors.append("exact HTTP destination policy is missing")
else:
    destination_source = destination_path.read_text()
    for required in ("maximumOriginCount = 256", "HTTPURLSecurityPolicy.permits", "destination-origins-v1"):
        if required not in destination_source:
            errors.append(f"HTTP destination policy is incomplete: {required}")
for relative, required in (
    ("Sources/FoveaHTTP/URLSessionTransport.swift", "destinationPolicy.permits(url)"),
    ("Sources/FoveaHTTP/HTTPRedirectPolicy.swift", "destinationPolicy.permits(url)"),
    ("Sources/FoveaCore/ProfileAccessPolicy.swift", "destinationPolicy.permits(request.url)"),
    ("Sources/FoveaSystem/FoveaSystemPipeline.swift", "transportPolicy.destinationPolicy"),
    ("Sources/FoveaHTTP/URLSessionTransportPolicy.swift", "destinationPolicy.executionFingerprint"),
):
    if required not in (root / relative).read_text():
        errors.append(f"destination policy boundary is incomplete in {relative}: {required}")

# namespace generation 是安全 fence，不得使用回绕算术。
namespace_source = (source_root / "FoveaCore/NamespaceRegistry.swift").read_text()
if "&+" in namespace_source or "isExhausted" not in namespace_source:
    errors.append("namespace generation must fail closed on UInt64 exhaustion")

# AkashicDisk 不保留 Fovea legacy overlay 或重复协议文件。
for obsolete_name in (
    "OriginalEncodedStoring.swift",
    "OriginalEncodedStore.swift",
    "OriginalEncodedStoreIdentity.swift",
    "OriginalEncodedStoreLimits.swift",
    "OriginalEncodedAccessJournal.swift",
    "OriginalEncodedPhysicalRemovalSummary.swift",
):
    if (source_root / "AkashicDisk" / obsolete_name).exists():
        errors.append(f"AkashicDisk legacy Fovea overlay must remain removed: {obsolete_name}")


# Persistent and runtime identity keys use explicit canonical bytes; synthesized Codable would
# permit noncanonical schema versions and identity components to bypass those constructors.
identity_source = (source_root / "FoveaCore/Identity.swift").read_text()
for identity_type in (
    "FetchBaseKey",
    "FetchVariantKey",
    "FetchExecutionKey",
    "DecodeKey",
    "RenderKey",
):
    declaration = re.search(
        rf"public struct {identity_type}:[^{{\n]+",
        identity_source,
    )
    if declaration is not None and "Codable" in declaration.group(0):
        errors.append(
            f"{identity_type} must use canonical identity encoding instead of synthesized Codable"
        )

# Runtime-only transport policies must not accidentally publish synthesized Codable schemas.
for relative in (
    "Sources/FoveaHTTP/HTTPDestinationPolicy.swift",
    "Sources/FoveaHTTP/URLSessionTransportPolicy.swift",
):
    text = (root / relative).read_text()
    if re.search(r"public (?:struct|enum) [^{:]+:[^{]*\bCodable\b", text):
        errors.append(f"runtime-only policy exposes an unversioned Codable schema: {relative}")

# 仅供实现使用的机制不得意外暴露为公共 API。
package_only_files = [
    "Sources/FoveaCore/NamespaceRegistry.swift",
    "Sources/FoveaCore/SharedTaskRegistry.swift",
    "Sources/FoveaCore/WallClock.swift",
    "Sources/FoveaHTTP/BoundedStagingAccumulator.swift",
    "Sources/FoveaHTTP/CredentialHeaderPolicy.swift",
    "Sources/FoveaHTTP/HTTPCachePolicy.swift",
]
for relative in package_only_files:
    path = root / relative
    if not path.is_file():
        errors.append(f"missing package-only implementation file: {relative}")
        continue
    if re.search(r"(?m)^\s*public\s+", path.read_text()):
        errors.append(f"implementation-only API became public: {relative}")

# 公共门面必须保持薄；HTTP、缓存选择和像素交付不得重新堆回 FoveaPipeline。
pipeline_path = source_root / "FoveaCore/FoveaPipeline.swift"
pipeline_source = pipeline_path.read_text()
public_initializer = pipeline_source.split("package init(", 1)[0]
if "profileAccessPolicy: ProfileAccessPolicy =" in public_initializer:
    errors.append("public FoveaPipeline initializer must require an explicit ProfileAccessPolicy")
pipeline_line_count = len(pipeline_path.read_text().splitlines())
if pipeline_line_count > 300:
    errors.append(
        f"FoveaPipeline facade regressed to {pipeline_line_count} lines; fixed coordinators must own orchestration"
    )

architecture_text = (root / "docs/ARCHITECTURE.md").read_text()
if "当前 Phase 0a 只实现 FetchExecutionKey single-flight" in architecture_text:
    errors.append("active architecture still denies the implemented DecodeKey single-flight")

# 平台模块必须具有真实显示生命周期，而不是只暴露错误策略空壳。
for adapter in ("FoveaUIKit", "FoveaAppKit"):
    view_path = source_root / adapter / "FoveaImageView.swift"
    if not view_path.is_file():
        errors.append(f"{adapter} must provide a concrete FoveaImageView lifecycle adapter")
        continue
    view_source = view_path.read_text()
    for required in ("ImageDisplaySession", "prepareForReuse", "accessibility:"):
        if required not in view_source:
            errors.append(f"{adapter} FoveaImageView lacks required lifecycle contract: {required}")

# 官方默认组合根必须把安全 transport、持久世代和 ImageIO decoder 显式收敛。
system_path = source_root / "FoveaSystem/FoveaSystemPipeline.swift"
if not system_path.is_file():
    errors.append("FoveaSystem safe composition root is missing")
else:
    system_source = system_path.read_text()
    for required in (
        "let transport = URLSessionTransport(",
        "policy: transportPolicy",
        "FoveaPersistentStores.open",
        "ImageIOImageDecoder()",
        "profileAccessPolicy",
    ):
        if required not in system_source:
            errors.append(f"FoveaSystem composition root is incomplete: {required}")

# SwiftUI 公共 body 只能发布一次阶段内容，禁止相邻重复输出同一 content 树。
swiftui_image_lines = (source_root / "FoveaSwiftUI/FoveaImage.swift").read_text().splitlines()
for first, second in zip(swiftui_image_lines, swiftui_image_lines[1:]):
    if first.strip() == "content" and second.strip() == "content":
        errors.append("FoveaImage body publishes the phase content tree more than once")
        break

# 使用 @main 的入口不得命名为 Swift 特殊文件 main.swift；旧工具链会把两者解释为双入口。
visible_swift = subprocess.run(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.swift"],
    cwd=root,
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
for relative in visible_swift:
    path = root / relative
    if path.name == "main.swift" and path.is_file() and "@main" in path.read_text():
        errors.append(f"@main entry must not use Swift's special main.swift filename: {relative}")

# 网络实验和 Gallery 必须是显式 executable，不得混入生产 Sources 模块。
for product, relative in (
    ("FoveaNetworkLab", "Tools/FoveaNetworkLab/FoveaNetworkLabMain.swift"),
    ("FoveaGalleryDemo", "Examples/FoveaGalleryDemo/FoveaGalleryDemoMain.swift"),
):
    if f'.executable(name: "{product}"' not in package:
        errors.append(f"{product} executable product is missing")
    if not (root / relative).is_file():
        errors.append(f"{product} source is missing: {relative}")

# 网络实验不得将自定义 URL/host/稳定 digest 写入证据，且 redirect 必须显式 allowlist。
network_lab_runner = root / "Tools/FoveaNetworkLab/NetworkLabRunner.swift"
network_lab_report = root / "Tools/FoveaNetworkLab/NetworkLabReport.swift"
network_lab_options = root / "Tools/FoveaNetworkLab/NetworkLabOptions.swift"
if not all(path.is_file() for path in (network_lab_runner, network_lab_report, network_lab_options)):
    errors.append("FoveaNetworkLab privacy and destination-policy sources are incomplete")
else:
    runner_source = network_lab_runner.read_text()
    report_source = network_lab_report.read_text()
    options_source = network_lab_options.read_text()
    for forbidden in ("urlHost", "urlDigest"):
        if forbidden in runner_source or forbidden in report_source:
            errors.append(f"FoveaNetworkLab must not persist custom destination identity: {forbidden}")
    for required in (
        "HTTPDestinationPolicy.allowOnly(allowedOrigins)",
        "originDisclosure",
        "privacySalt",
        "defaultRedirectOrigins",
    ):
        if required not in runner_source:
            errors.append(f"FoveaNetworkLab privacy/destination contract is incomplete: {required}")
    if 'case "--allow-origin"' not in options_source:
        errors.append("FoveaNetworkLab must require explicit cross-origin redirect admission")
    if "maximumCaseCount = 64" not in options_source:
        errors.append("FoveaNetworkLab must bound public network side effects")

# iOS 完整示例是独立 Xcode App，不得与研究型 FoveaLab 或 SwiftPM 产品混名。
workbench_root = root / "Examples/FoveaWorkbenchApp"
required_workbench_paths = (
    "project.yml",
    ".xcodegen-version",
    "FoveaWorkbench.xcodeproj/project.pbxproj",
    "FoveaWorkbench/App/FoveaWorkbenchApp.swift",
    "FoveaWorkbench/Models/WorkbenchScenario.swift",
    "FoveaWorkbench/Models/WorkbenchScenarioCatalog.swift",
    "FoveaWorkbench/Models/WorkbenchFeedItem.swift",
    "FoveaWorkbench/Models/WorkbenchRemoteAsset.swift",
    "FoveaWorkbench/Views/WorkbenchDiscoverView.swift",
    "FoveaWorkbench/Views/WorkbenchRemoteAssetViews.swift",
    "FoveaWorkbench/Views/FeedStressView.swift",
    "FoveaWorkbench/Networking/DemoURLProtocol.swift",
    "FoveaWorkbenchTests/FoveaWorkbenchIntegrationTests.swift",
    "FoveaWorkbenchTests/WorkbenchTestSupport.swift",
    "FoveaWorkbenchLiveTests/Info.plist",
    "FoveaWorkbenchLiveTests/FoveaWorkbenchLiveNetworkTests.swift",
    "FoveaWorkbenchUITests/FoveaWorkbenchUITests.swift",
    "README.md",
)
for relative in required_workbench_paths:
    if not (workbench_root / relative).is_file():
        errors.append(f"FoveaWorkbench required artifact is missing: {relative}")
for relative in (
    "scripts/generate-ios-example.sh",
    "scripts/verify-ios-example.py",
    "scripts/validate-ios-example-report.py",
    "docs/schemas/ios-example-verification.schema.json",
    "scripts/validate-production-coverage.py",
    "docs/schemas/production-coverage.schema.json",
    "scripts/check-structural-quality.py",
    "scripts/check-sensitive-material.py",
    "scripts/check-supply-chain.py",
    "docs/research/dependency-allowlist.json",
    "scripts/verify-documentation.py",
    "scripts/validate-documentation-report.py",
    "docs/schemas/documentation-verification.schema.json",
):
    if not (root / relative).is_file():
        errors.append(f"FoveaWorkbench verification artifact is missing: {relative}")
if (root / "Examples/FoveaLabApp").exists():
    errors.append("FoveaLab is reserved for research; the iOS example must remain FoveaWorkbench")
if "FoveaWorkbench" in package:
    errors.append("FoveaWorkbench must remain an independent example app, not a SwiftPM product")
workbench_project = (workbench_root / "project.yml").read_text() if workbench_root.exists() else ""
for required in ('name: FoveaWorkbench', 'iOS: "15.0"', 'deploymentTarget: "15.0"'):
    if required not in workbench_project:
        errors.append(f"FoveaWorkbench project contract is missing: {required}")
workbench_sources = sorted((workbench_root / "FoveaWorkbench").rglob("*.swift")) if workbench_root.exists() else []
for path in workbench_sources:
    text = path.read_text()
    relative = path.relative_to(root)
    if "import FoveaTesting" in text:
        errors.append(f"example app must not depend on test-support product: {relative}")
    if len(text.splitlines()) > 500:
        errors.append(f"example app source exceeds 500 lines and needs a cohesion review: {relative}")
    if re.search(r"\btry!\b|\bas!\b", text):
        errors.append(f"forced error/type conversion in example app: {relative}")
configuration_path = workbench_root / "FoveaWorkbench/Models/WorkbenchConfiguration.swift"
if configuration_path.is_file():
    configuration_source = configuration_path.read_text()
    if "var externalNetworkingEnabled = true" not in configuration_source:
        errors.append("FoveaWorkbench interactive defaults must exercise real HTTPS images")
    for required in (
        "static var deterministicDefaults",
        "value.externalNetworkingEnabled = false",
    ):
        if required not in configuration_source:
            errors.append(
                f"FoveaWorkbench deterministic test configuration is incomplete: {required}"
            )
    if "case customURL" in configuration_source:
        errors.append("FoveaWorkbench custom URL must remain session-only and excluded from CodingKeys")
workbench_model_path = workbench_root / "FoveaWorkbench/App/WorkbenchAppModel.swift"
workbench_launch_path = workbench_root / "FoveaWorkbench/App/WorkbenchLaunchState.swift"
workbench_error_path = workbench_root / "FoveaWorkbench/App/WorkbenchErrorDescription.swift"
workbench_state_source = "\n".join(
    path.read_text()
    for path in (workbench_model_path, workbench_launch_path, workbench_error_path)
    if path.is_file()
)
if "String(describing: error)" in workbench_state_source or "localizedDescription" in workbench_state_source:
    errors.append("FoveaWorkbench must not render arbitrary underlying error text")
if "isUITesting ? .deterministicDefaults : .defaults" not in workbench_state_source:
    errors.append("FoveaWorkbench UI automation must select deterministic networking explicitly")
gallery_path = root / "Examples/FoveaGalleryDemo/FoveaGalleryDemoMain.swift"
if gallery_path.is_file():
    gallery_source = gallery_path.read_text()
    if "String(describing: error)" in gallery_source or "localizedDescription" in gallery_source:
        errors.append("FoveaGalleryDemo must not render arbitrary underlying error text")
pipeline_factory_path = workbench_root / "FoveaWorkbench/App/WorkbenchPipelineFactory.swift"
if pipeline_factory_path.is_file():
    pipeline_factory_source = pipeline_factory_path.read_text()
    for required in (
        "HTTPDestinationPolicy.allowOnly(allowedOrigins)",
        "WorkbenchScenarioCatalog.livePresetURLs",
        "WorkbenchScenarioCatalog.additionalLiveRedirectOrigins",
        "WorkbenchRemoteAssetCatalog.allowedOriginURLs",
    ):
        if required not in pipeline_factory_source:
            errors.append(f"FoveaWorkbench real-network allowlist is incomplete: {required}")
    if "destinationPolicy = .secureDefault" in pipeline_factory_source:
        errors.append("FoveaWorkbench must not replace its explicit real-network allowlist with unrestricted HTTPS")
remote_asset_path = workbench_root / "FoveaWorkbench/Models/WorkbenchRemoteAsset.swift"
if remote_asset_path.is_file():
    remote_asset_source = remote_asset_path.read_text()
    for required in (
        "let author: String",
        "let license: String",
        "let ethicalReview: String",
        "let sourceKind: WorkbenchMediaSourceKind",
        "let originalPixelWidth: Int",
        "let originalPixelHeight: Int",
        "static var allowedOriginURLs: [URL]",
    ):
        if required not in remote_asset_source:
            errors.append(f"FoveaWorkbench real-media contract is incomplete: {required}")

media_generator_path = root / "scripts/generate-workbench-media-catalog.py"
media_catalog_path = workbench_root / "FoveaWorkbench/Resources/workbench-media-catalog.json"
local_media_root = workbench_root / "FoveaWorkbench/Resources/LocalMedia"
for path, label in (
    (media_generator_path, "real-media generator"),
    (media_catalog_path, "real-media catalog"),
    (local_media_root, "bundled real-media directory"),
):
    if not path.exists():
        errors.append(f"FoveaWorkbench {label} is missing: {path.relative_to(root)}")

if media_generator_path.is_file() and media_catalog_path.is_file():
    validation = subprocess.run(
        [sys.executable, str(media_generator_path), "--validate"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if validation.returncode != 0:
        errors.append(
            "FoveaWorkbench real-media catalog failed generator validation: "
            + validation.stdout.strip()
        )

    try:
        media_document = json.loads(media_catalog_path.read_text())
        media_assets = media_document.get("assets", [])
    except (json.JSONDecodeError, OSError) as error:
        errors.append(f"FoveaWorkbench real-media catalog is unreadable: {error}")
        media_document = {}
        media_assets = []

    if media_document.get("schemaVersion") != 1:
        errors.append("FoveaWorkbench real-media catalog schemaVersion must equal 1")
    if len(media_assets) < 400:
        errors.append("FoveaWorkbench must contain at least 400 reviewed real-media entries")
    identifiers = [asset.get("id") for asset in media_assets if isinstance(asset, dict)]
    if len(identifiers) != len(set(identifiers)):
        errors.append("FoveaWorkbench real-media identifiers must be unique")
    remote_assets = [asset for asset in media_assets if asset.get("sourceKind") == "remote"]
    bundled_assets = [asset for asset in media_assets if asset.get("sourceKind") == "bundled"]
    if len(remote_assets) < 400:
        errors.append("FoveaWorkbench must contain at least 400 reviewed remote images")
    if len(bundled_assets) < 16:
        errors.append("FoveaWorkbench must contain at least 16 reviewed bundled images")
    for asset in media_assets:
        identifier = asset.get("id", "unknown")
        if not asset.get("ethicalReview"):
            errors.append(f"FoveaWorkbench media entry lacks ethical review: {identifier}")
        source_page = asset.get("sourcePageURL", "")
        if not source_page.startswith("https://commons.wikimedia.org/"):
            errors.append(f"FoveaWorkbench media source is not an HTTPS Commons page: {identifier}")
        if asset.get("sourceKind") == "bundled":
            resource = local_media_root / str(asset.get("bundledResourceName", ""))
            if not resource.is_file() or resource.stat().st_size == 0:
                errors.append(f"FoveaWorkbench bundled media is missing: {identifier}")

for required in (
    "- FoveaWorkbenchLiveTests",
    'INFOPLIST_FILE: FoveaWorkbenchLiveTests/Info.plist',
    'FOVEA_RUN_LIVE_NETWORK: "0"',
):
    if required not in workbench_project:
        errors.append(f"FoveaWorkbench live-test scheme contract is incomplete: {required}")

live_info_path = workbench_root / "FoveaWorkbenchLiveTests/Info.plist"
if live_info_path.is_file():
    live_info_source = live_info_path.read_text()
    if "<key>FoveaRunLiveNetwork</key>" not in live_info_source or "$(FOVEA_RUN_LIVE_NETWORK)" not in live_info_source:
        errors.append("FoveaWorkbench live XCTest bundle must receive explicit build authorization")

verify_ios_paths = (
    root / "scripts/verify-ios-example.py",
    root / "scripts/ios_example_xcode.py",
)
verify_ios_source = "\n".join(
    path.read_text() for path in verify_ios_paths if path.is_file()
)
for required in (
    '"FOVEA_RUN_LIVE_NETWORK=1"',
    "require_no_skips=True",
    "reported skipped tests; live evidence was not executed",
):
    if required not in verify_ios_source:
        errors.append(f"FoveaWorkbench live verification gate is incomplete: {required}")

scenario_paths = (
    workbench_root / "FoveaWorkbench/Models/WorkbenchScenario.swift",
    workbench_root / "FoveaWorkbench/Models/WorkbenchScenarioCatalog.swift",
)
scenario_source = "\n".join(path.read_text() for path in scenario_paths if path.is_file())
for host in ("httpbin.org", "picsum.photos", "raw.githubusercontent.com", "www.gstatic.com"):
    if host not in scenario_source:
        errors.append(f"FoveaWorkbench required live origin is missing: {host}")
for required in ("environmentDependent", "scrolling-feed-lab", "feed(initialLayout:"):
    if required not in scenario_source:
        errors.append(f"FoveaWorkbench scenario matrix is incomplete: {required}")
unchecked_locations = [
    path.relative_to(root)
    for path in workbench_sources
    if "@unchecked Sendable" in path.read_text()
]
expected_unchecked = [Path("Examples/FoveaWorkbenchApp/FoveaWorkbench/Networking/DemoURLProtocol.swift")]
if unchecked_locations != expected_unchecked:
    errors.append(
        f"FoveaWorkbench unchecked Sendable must remain isolated to URLProtocol bridge: {unchecked_locations}"
    )

# 跨进程探针只属于验证图，不得成为生产 Sources 模块或运行时依赖。
if (source_root / "FoveaStoreProbe").exists():
    errors.append("FoveaStoreProbe must remain under Tools, not production Sources")
if '.executable(name: "FoveaStoreProbe"' in package:
    errors.append("FoveaStoreProbe must not be exposed as a public package product")
if 'name: "FoveaStoreProbe"' not in package:
    errors.append("StoreGeneration contention probe target is missing")

# 活动目录只保留一份当前架构文档和一份最新本地证据快照。
for obsolete in (root / "docs/archive", root / "docs/ARCHITECTURE_V2.md"):
    if obsolete.exists():
        errors.append(f"obsolete design artifact must be removed: {obsolete.relative_to(root)}")

if errors:
    print("Architecture boundary violation:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)

print("Architecture boundary check passed.")
