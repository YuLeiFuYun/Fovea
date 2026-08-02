#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SELECTION = ROOT / "Benchmarks/ComparativeLab/dataset-selection.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/comparative-dataset"
USER_AGENT = "FoveaComparativeLab/1.0 (deterministic research fixture capture)"
SUPPORTED_MIME = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
API_ENDPOINT = "https://commons.wikimedia.org/w/api.php"

sys.path.insert(0, str(ROOT / "scripts"))
from image_metadata import ImageMetadataError, contains_sensitive_image_metadata, sanitize_image_metadata  # noqa: E402


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_mime(value: str | None, data: bytes) -> str:
    base = (value or "").split(";", 1)[0].strip().lower()
    if base in SUPPORTED_MIME:
        return base
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    raise ValueError(f"unsupported image MIME: {base or 'unknown'}")


def dimensions(path: Path) -> tuple[int, int]:
    result = subprocess.run(
        ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    width_match = re.search(r"pixelWidth:\s*(\d+)", result.stdout)
    height_match = re.search(r"pixelHeight:\s*(\d+)", result.stdout)
    if width_match is None or height_match is None:
        raise ValueError(f"unable to inspect image dimensions: {path.name}")
    width, height = int(width_match.group(1)), int(height_match.group(1))
    if width <= 0 or height <= 0:
        raise ValueError(f"invalid image dimensions: {path.name}")
    return width, height


def curl_bytes(url: str, *, attempts: int = 6) -> tuple[bytes, str, str]:
    last_error = "unknown curl failure"
    for attempt in range(attempts):
        with tempfile.TemporaryDirectory(prefix="fovea-capture-http-") as temp:
            temp_path = Path(temp)
            body_path = temp_path / "body"
            command = [
                "/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                "--connect-timeout", "15", "--max-time", "90", "--user-agent", USER_AGENT,
                "--header", "Accept: image/webp,image/png,image/jpeg,application/json,*/*;q=0.5",
                "--output", str(body_path), "--write-out", "%{content_type}\n%{url_effective}\n", url,
            ]
            result = subprocess.run(command, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode == 0:
                data = body_path.read_bytes()
                if not data:
                    last_error = "empty response"
                elif len(data) > 32 * 1024 * 1024:
                    last_error = "response exceeds 32 MiB capture limit"
                else:
                    lines = result.stdout.splitlines()
                    return data, lines[0] if lines else "", lines[1] if len(lines) > 1 else url
            else:
                last_error = result.stderr.strip() or f"curl exit {result.returncode}"
        if attempt + 1 < attempts:
            rate_limited = "429" in last_error
            delay = (20 if rate_limited else 2) * (attempt + 1)
            print(f"Retrying remote fetch after {delay}s: {last_error.splitlines()[-1]}", flush=True)
            time.sleep(delay)
    raise ValueError(last_error)


def title_key(value: str) -> str:
    value = value.removeprefix("File:").replace("_", " ").strip()
    return unicodedata.normalize("NFC", value).casefold()


def resolve_thumbnail_urls(assets: list[dict[str, Any]]) -> dict[str, str]:
    resolved: dict[str, str] = {}
    for offset in range(0, len(assets), 40):
        batch = assets[offset : offset + 40]
        params = {
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "prop": "imageinfo",
            "iiprop": "url|mime|size",
            "iiurlwidth": "960",
            "redirects": "1",
            "maxlag": "5",
            "titles": "|".join(f"File:{asset['fileName']}" for asset in batch),
        }
        url = f"{API_ENDPOINT}?{urllib.parse.urlencode(params)}"
        data, _, _ = curl_bytes(url)
        payload = json.loads(data)
        for page in payload.get("query", {}).get("pages", []):
            info = (page.get("imageinfo") or [{}])[0]
            remote = info.get("thumburl") or info.get("url")
            if remote:
                resolved[title_key(page.get("title", ""))] = remote
        print(f"Resolved {min(offset + len(batch), len(assets))}/{len(assets)} fixture URLs", flush=True)
    missing = [asset["fileName"] for asset in assets if title_key(asset["fileName"]) not in resolved]
    if missing:
        raise ValueError(f"MediaWiki API did not resolve {len(missing)} files; first={missing[0]}")
    return {asset["assetID"]: resolved[title_key(asset["fileName"])] for asset in assets}


def stable_basename(index: int, asset_id: str) -> str:
    return f"{index:03d}-{hashlib.sha256(asset_id.encode()).hexdigest()[:16]}"


def verify_record(output: Path, record: dict[str, Any]) -> None:
    path = output / record["resourcePath"]
    if not path.is_file() or sha256_file(path) != record["sha256"]:
        raise ValueError(f"captured fixture digest mismatch: {record['resourcePath']}")
    data = path.read_bytes()
    if contains_sensitive_image_metadata(data):
        raise ValueError(f"captured fixture contains metadata: {record['resourcePath']}")
    width, height = dimensions(path)
    if width != record["pixelWidth"] or height != record["pixelHeight"]:
        raise ValueError(f"captured fixture dimension mismatch: {record['resourcePath']}")


def capture_one(index: int, asset: dict[str, Any], download_url: str, output: Path) -> dict[str, Any]:
    assets_dir, records_dir = output / "assets", output / ".records"
    record_path = records_dir / f"{index:03d}.json"
    if record_path.is_file():
        record = json.loads(record_path.read_text())
        if record.get("assetID") == asset["assetID"]:
            verify_record(output, record)
            return record
    raw, declared_mime, final_url = curl_bytes(download_url)
    mime = normalize_mime(declared_mime, raw)
    sanitized = sanitize_image_metadata(raw)
    if contains_sensitive_image_metadata(sanitized):
        raise ValueError(f"metadata sanitizer failed for {asset['assetID']}")
    suffix = SUPPORTED_MIME[mime]
    destination = assets_dir / f"{stable_basename(index, asset['assetID'])}{suffix}"
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_bytes(sanitized)
    width, height = dimensions(temporary)
    os.replace(temporary, destination)
    record = {
        "assetID": asset["assetID"], "resourcePath": f"assets/{destination.name}",
        "sha256": sha256_bytes(sanitized), "byteCount": len(sanitized),
        "pixelWidth": width, "pixelHeight": height, "mimeType": mime,
        "sourceRequestURL": asset["requestURL"], "resolvedSourceURL": final_url,
        "sourcePageURL": asset["sourcePageURL"], "license": asset["license"],
        "licenseURL": asset["licenseURL"],
    }
    record_path.write_text(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    return record


def verify_existing(output: Path, selection_digest: str) -> dict[str, Any]:
    manifest_path = output / "captured-dataset.json"
    if not manifest_path.is_file():
        raise ValueError("captured manifest is missing")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("selectionDigest") != selection_digest:
        raise ValueError("captured manifest schema or selection digest mismatch")
    entries = manifest.get("assets")
    if not isinstance(entries, list) or len(entries) != 128:
        raise ValueError("captured dataset must contain exactly 128 assets")
    for entry in entries:
        verify_record(output, entry)
    canonical = json.dumps(entries, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
    if sha256_bytes(canonical) != manifest.get("datasetDigest"):
        raise ValueError("captured dataset aggregate digest mismatch")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture and freeze the Comparative Lab W1 image bytes.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--delay", type=float, default=0.75)
    args = parser.parse_args()
    output = args.output.resolve()
    selection_bytes = SELECTION.read_bytes()
    selection_digest = hashlib.sha256(selection_bytes).hexdigest()
    if args.refresh and output.exists():
        shutil.rmtree(output)
    if (output / "captured-dataset.json").is_file():
        manifest = verify_existing(output, selection_digest)
        print(f"Comparative dataset verified: assets=128 bytes={manifest['totalByteCount']} sha256:{manifest['datasetDigest']}")
        return 0
    selection = json.loads(selection_bytes)
    assets = selection.get("assets")
    if selection.get("schemaVersion") != 1 or not isinstance(assets, list) or len(assets) != 128:
        raise SystemExit("selection manifest must contain exactly 128 schema-v1 assets")
    output.mkdir(parents=True, exist_ok=True)
    (output / "assets").mkdir(exist_ok=True)
    (output / ".records").mkdir(exist_ok=True)
    try:
        remote_urls = resolve_thumbnail_urls(assets)
        records: list[dict[str, Any]] = []
        for index, asset in enumerate(assets):
            record = capture_one(index, asset, remote_urls[asset["assetID"]], output)
            records.append(record)
            print(f"Captured {index + 1}/{len(assets)} fixtures", flush=True)
            if args.delay > 0 and index + 1 < len(assets):
                time.sleep(args.delay)
        canonical = json.dumps(records, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
        manifest = {
            "schemaVersion": 1, "capturePolicy": "immutable-unless-explicit-refresh",
            "selectionManifest": str(SELECTION.relative_to(ROOT)), "selectionDigest": selection_digest,
            "datasetDigest": sha256_bytes(canonical), "assetCount": len(records),
            "totalByteCount": sum(item["byteCount"] for item in records),
            "metadataStripped": True, "assets": records,
        }
        temporary = output / "captured-dataset.json.tmp"
        temporary.write_text(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
        os.replace(temporary, output / "captured-dataset.json")
        verify_existing(output, selection_digest)
        shutil.rmtree(output / ".records", ignore_errors=True)
        print(f"Comparative dataset captured: assets=128 bytes={manifest['totalByteCount']} sha256:{manifest['datasetDigest']}")
        print(f"Artifact: {output}")
        return 0
    except (OSError, ValueError, ImageMetadataError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Comparative dataset capture failed; resumable state retained: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
