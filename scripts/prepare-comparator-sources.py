#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "docs/research/comparator-lock.json"
RESEARCH_LOCK = ROOT / "docs/research/network-image-loader-test-sources.json"
CACHE_LOCK = ROOT / "docs/research/cache-comparator-lock.json"
DEFAULT_ROOT = ROOT / ".artifacts/comparators/sources"
DEFAULT_RESEARCH_ROOT = ROOT / ".artifacts/comparators/research-sources"
DEFAULT_CACHE_ROOT = ROOT / ".artifacts/cache-comparators/sources"
REPORT = ROOT / ".artifacts/comparators/checkout-report.json"


def run(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
    return result.stdout.strip()


def checkout(item: dict, destination: Path, refresh: bool) -> dict:
    if refresh and destination.exists():
        shutil.rmtree(destination)
    if not destination.exists():
        destination.mkdir(parents=True)
        run(["git", "init", "-q"], cwd=destination)
        run(["git", "remote", "add", "origin", item["repository"]], cwd=destination)
        run(["git", "fetch", "--no-tags", "--depth=1", "origin", item["exactCommit"]], cwd=destination)
        run(["git", "checkout", "--detach", "-q", "FETCH_HEAD"], cwd=destination)
    head = run(["git", "rev-parse", "HEAD"], cwd=destination)
    if head != item["exactCommit"]:
        raise SystemExit(f"{item['name']} HEAD mismatch: {head} != {item['exactCommit']}")
    dirty = bool(run(["git", "status", "--porcelain"], cwd=destination))
    if dirty:
        raise SystemExit(f"{item['name']} checkout is dirty")
    return {
        "exactCommit": head,
        "name": item["name"],
        "path": str(destination.relative_to(ROOT)),
        "tag": item["tag"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare exact detached comparator sources outside production dependencies.")
    parser.add_argument(
        "--include-reference",
        action="store_true",
        help="Also fetch locked cross-language research sources used by the challenge suite.",
    )
    parser.add_argument("--refresh", action="store_true", help="Delete and refetch comparator checkouts.")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--research-root", type=Path, default=DEFAULT_RESEARCH_ROOT)
    parser.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    args = parser.parse_args()

    lock = json.loads(LOCK.read_text())
    research_lock = json.loads(RESEARCH_LOCK.read_text())
    cache_lock = json.loads(CACHE_LOCK.read_text())
    checkout_root = args.root if args.root.is_absolute() else ROOT / args.root
    research_root = args.research_root if args.research_root.is_absolute() else ROOT / args.research_root
    cache_root = args.cache_root if args.cache_root.is_absolute() else ROOT / args.cache_root
    records: list[dict] = []
    for item in lock["comparators"]:
        if item["phase0bRole"] != "required":
            continue
        record = checkout(item, checkout_root / item["name"], args.refresh)
        record["sourceClass"] = "apple-platform-comparator"
        records.append(record)
    for item in cache_lock["comparators"]:
        record = checkout(item, cache_root / item["name"], args.refresh)
        record["sourceClass"] = "cache-comparator"
        records.append(record)
    if args.include_reference:
        for item in research_lock["sources"]:
            record = checkout(item, research_root / item["name"], args.refresh)
            record["sourceClass"] = "cross-language-research"
            records.append(record)

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(
        json.dumps(
            {
                "comparators": records,
                "includeReference": args.include_reference,
                "productionDependencyGraphModified": False,
                "schemaVersion": 2,
                "status": "passed",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    print(f"Prepared {len(records)} exact comparator checkouts")
    print(f"Report: {REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
