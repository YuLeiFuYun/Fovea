#!/usr/bin/env python3
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
allowed = {
    "ImageCraftCore",
    "ImageCraftImageIO",
    "AkashicCore",
    "AkashicMemory",
    "AkashicDisk",
    "FoveaCore",
    "FoveaHTTP",
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
    errors.append(f"forbidden Phase 0a products: {found_forbidden}")

# AkashicMemory is a generic cache engine, not an image adapter.
akashic_memory_files = sorted((source_root / "AkashicMemory").rglob("*.swift"))
for path in akashic_memory_files:
    text = path.read_text()
    for forbidden in ("import ImageCraft", "DecodedImage", "CGImage", "UIImage", "NSImage"):
        if forbidden in text:
            errors.append(
                f"AkashicMemory domain leak in {path.relative_to(root)}: {forbidden}"
            )
akashic_target = re.search(
    r'\.target\((?P<body>[^)]*name:\s*"AkashicMemory"[^)]*)\)', package
)
if akashic_target is None:
    errors.append("AkashicMemory target declaration not found")
elif "dependencies:" in akashic_target.group("body"):
    errors.append("AkashicMemory target must not declare product dependencies in Phase 0a")


# FoveaCore depends on storage contracts in AkashicCore, not the concrete disk product.
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
if not (source_root / "AkashicCore/OriginalEncodedStoring.swift").is_file():
    errors.append("OriginalEncodedStoring contract must live in AkashicCore")

if "public final class FoveaImageModel" in (source_root / "FoveaSwiftUI/FoveaImage.swift").read_text():
    errors.append("FoveaImageModel is an implementation detail and must remain package-only")

local_evidence = root / "evidence/local"
if local_evidence.is_dir():
    snapshots = [path for path in local_evidence.iterdir() if not path.name.startswith(".")]
    if len(snapshots) > 1:
        errors.append("evidence/local must contain at most one latest snapshot")

# Strict concurrency must not be weakened in production code.
for path in sorted(source_root.rglob("*.swift")):
    if "@unchecked Sendable" in path.read_text():
        errors.append(f"unchecked Sendable in production source: {path.relative_to(root)}")

# Implementation-only mechanics must not become public API accidentally.
package_only_files = [
    "Sources/AkashicCore/BlockingIOExecutor.swift",
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

# The active tree keeps one current architecture and one current local evidence snapshot.
for obsolete in (root / "docs/archive", root / "docs/ARCHITECTURE_V2.md"):
    if obsolete.exists():
        errors.append(f"obsolete design artifact must be removed: {obsolete.relative_to(root)}")

if errors:
    print("Phase 0a surface violation:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)

print("Phase 0a surface check passed.")
