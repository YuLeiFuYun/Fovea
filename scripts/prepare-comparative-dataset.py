#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbench/Resources/workbench-media-catalog.json"
OUTPUT = ROOT / "Benchmarks/ComparativeLab/dataset-selection.json"
COUNT = 128
WIDTH = 960


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def main() -> int:
    catalog_bytes = CATALOG.read_bytes()
    catalog = json.loads(catalog_bytes)
    remote = sorted(
        (item for item in catalog["assets"] if item.get("sourceKind") == "remote"),
        key=lambda item: item["id"],
    )
    if len(remote) < COUNT:
        print(f"catalog has only {len(remote)} remote assets", file=sys.stderr)
        return 1
    selected = []
    for item in remote[:COUNT]:
        file_name = item["fileName"]
        selected.append(
            {
                "assetID": item["id"],
                "category": item["category"],
                "expectedMimeType": item["mimeType"],
                "fileName": file_name,
                "license": item["license"],
                "licenseURL": item["licenseURL"],
                "originalPixelHeight": item["originalPixelHeight"],
                "originalPixelWidth": item["originalPixelWidth"],
                "requestURL": (
                    "https://commons.wikimedia.org/wiki/Special:Redirect/file/"
                    f"{quote(file_name, safe='')}?width={WIDTH}"
                ),
                "sourcePageURL": item["sourcePageURL"],
            }
        )
    payload = {
        "assetCount": COUNT,
        "assets": selected,
        "catalogSHA256": hashlib.sha256(catalog_bytes).hexdigest(),
        "requestWidthPixels": WIDTH,
        "schemaVersion": 1,
        "selectionRule": "remote-assets-lexicographic-asset-id-first-128",
        "sourceCatalog": str(CATALOG.relative_to(ROOT)),
        "status": "selection-locked-by-rule-bytes-not-yet-captured",
    }
    payload["selectionSHA256"] = hashlib.sha256(canonical(payload["assets"])).hexdigest()
    OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(
        f"Comparative dataset selection prepared: assets={COUNT} "
        f"sha256:{payload['selectionSHA256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
