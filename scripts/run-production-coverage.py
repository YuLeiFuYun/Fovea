#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV = os.environ.copy()
if not ENV.get("DEVELOPER_DIR"):
    selection = subprocess.run(
        [str(ROOT / "scripts/select-xcode.sh")],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env=ENV,
    )
    if selection.returncode != 0:
        raise SystemExit(selection.stderr.strip() or "unable to select Xcode")
    ENV["DEVELOPER_DIR"] = selection.stdout.strip()
ARTIFACT = ROOT / ".artifacts/coverage/production-coverage.json"
THRESHOLDS = {
    "lines": 85.0,
    "functions": 85.0,
    "regions": 78.0,
}
MODULE_LINE_THRESHOLDS = {
    "AkashicCore": 85.0,
    "AkashicDisk": 85.0,
    "AkashicMemory": 85.0,
    "FoveaAppKit": 80.0,
    "FoveaCore": 85.0,
    "FoveaHTTP": 85.0,
    "FoveaPersistence": 75.0,
    "FoveaSwiftUI": 35.0,
    "FoveaSystem": 75.0,
    "ImageCraftCore": 90.0,
    "ImageCraftImageIO": 85.0,
}


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        env=ENV,
    )


def percentage(covered: int, count: int) -> float:
    return 100.0 if count == 0 else covered * 100.0 / count


def main() -> int:
    test = run(
        [
            "xcrun",
            "swift",
            "test",
            "--enable-code-coverage",
            "-Xswiftc",
            "-warnings-as-errors",
        ]
    )
    if test.returncode != 0:
        print(test.stdout)
        return test.returncode

    path_result = run(["xcrun", "swift", "test", "--show-codecov-path"])
    if path_result.returncode != 0:
        print(path_result.stdout)
        return path_result.returncode
    coverage_path = Path(path_result.stdout.strip())
    if not coverage_path.is_file():
        print(f"coverage export missing: {coverage_path}", file=sys.stderr)
        return 1

    raw = json.loads(coverage_path.read_text())
    aggregate = {metric: [0, 0] for metric in THRESHOLDS}
    modules: dict[str, dict[str, list[int]]] = defaultdict(
        lambda: {metric: [0, 0] for metric in THRESHOLDS}
    )
    root_prefix = f"{ROOT}/"
    included_files = 0
    for file in raw["data"][0]["files"]:
        filename = file["filename"]
        if not filename.startswith(f"{root_prefix}Sources/"):
            continue
        relative = filename.removeprefix(root_prefix)
        if relative.startswith("Sources/FoveaTesting/"):
            continue
        parts = Path(relative).parts
        if len(parts) < 3:
            continue
        included_files += 1
        module = parts[1]
        for metric in THRESHOLDS:
            summary = file["summary"][metric]
            aggregate[metric][0] += summary["covered"]
            aggregate[metric][1] += summary["count"]
            modules[module][metric][0] += summary["covered"]
            modules[module][metric][1] += summary["count"]

    if included_files == 0:
        print("coverage export contains no production source files", file=sys.stderr)
        return 1

    totals = {
        metric: {
            "covered": covered,
            "count": count,
            "percent": percentage(covered, count),
            "minimumPercent": THRESHOLDS[metric],
        }
        for metric, (covered, count) in aggregate.items()
    }
    module_summaries = {
        module: {
            metric: {
                "covered": values[0],
                "count": values[1],
                "percent": percentage(values[0], values[1]),
            }
            for metric, values in metrics.items()
        }
        for module, metrics in sorted(modules.items())
    }
    aggregate_failures = [
        metric
        for metric, summary in totals.items()
        if summary["percent"] < summary["minimumPercent"]
    ]
    module_failures = []
    for module, minimum in MODULE_LINE_THRESHOLDS.items():
        summary = module_summaries.get(module)
        if summary is None:
            module_failures.append({
                "module": module,
                "reason": "missing-from-coverage-export",
                "minimumLinePercent": minimum,
            })
        elif summary["lines"]["percent"] < minimum:
            module_failures.append({
                "module": module,
                "reason": "line-coverage-below-minimum",
                "linePercent": summary["lines"]["percent"],
                "minimumLinePercent": minimum,
            })
    failures = aggregate_failures or module_failures
    head = run(["git", "rev-parse", "HEAD"])
    if head.returncode != 0:
        print(head.stdout)
        return head.returncode
    report = {
        "schemaVersion": 1,
        "verifiedCommit": head.stdout.strip(),
        "scope": "Sources excluding FoveaTesting and generated files",
        "includedFileCount": included_files,
        "totals": totals,
        "modules": module_summaries,
        "moduleLineThresholds": MODULE_LINE_THRESHOLDS,
        "status": "passed" if not failures else "failed",
        "failedMetrics": aggregate_failures,
        "failedModules": module_failures,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    summary = ", ".join(
        f"{metric}={values['percent']:.2f}% (min {values['minimumPercent']:.2f}%)"
        for metric, values in totals.items()
    )
    print(f"Production coverage {report['status']}: {summary}")
    print(f"Artifact: {ARTIFACT.relative_to(ROOT)}")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
