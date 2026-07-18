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
found_forbidden = sorted(name for name in forbidden_products if re.search(rf'\b{re.escape(name)}\b', package))

errors = []
if unexpected:
    errors.append(f"unexpected Sources modules: {unexpected}")
if missing:
    errors.append(f"missing required Sources modules: {missing}")
if found_forbidden:
    errors.append(f"forbidden Phase 0a products: {found_forbidden}")

if errors:
    print("Phase 0a surface violation:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)

print("Phase 0a surface check passed.")
