#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
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
    "FoveaAppKit": 80.0,
    "FoveaCore": 85.0,
    "FoveaHTTP": 85.0,
    "FoveaPersistence": 75.0,
    "FoveaObservability": 85.0,
    "FoveaSwiftUI": 65.0,
    "FoveaSystem": 75.0,
}
CRITICAL_FILE_LINE_THRESHOLDS = {
    "Sources/FoveaCore/AsyncPermitPool.swift": 90.0,
    "Sources/FoveaCore/DecodeStage.swift": 85.0,
    "Sources/FoveaCore/FetchStage.swift": 90.0,
    "Sources/FoveaCore/ImageLoading.swift": 90.0,
    "Sources/FoveaCore/PipelineCache.swift": 80.0,
    "Sources/FoveaCore/ProfileAccessPolicy.swift": 90.0,
    "Sources/FoveaCore/SharedTaskRegistry.swift": 90.0,
    "Sources/FoveaHTTP/URLSessionEventRouter.swift": 80.0,
    "Sources/FoveaHTTP/URLSessionTransport.swift": 90.0,
    "Sources/FoveaPersistence/FoveaPersistentStores.swift": 80.0,
    "Sources/FoveaSwiftUI/FoveaImage.swift": 50.0,
    "Sources/FoveaSystem/FoveaSystemPipeline.swift": 85.0,
}
NONTRIVIAL_FILE_LINE_FLOOR = 50.0
NONTRIVIAL_FILE_MINIMUM_LINES = 20


def run(command: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        env=env or ENV,
    )


def command_output(command: list[str], *, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        env=env,
    )
    return completed.stdout.strip()


def workspace_tree() -> tuple[str, bool]:
    dirty = bool(command_output(["git", "status", "--porcelain"]))
    with tempfile.TemporaryDirectory(prefix="fovea-coverage-index-") as temporary:
        index = Path(temporary) / "index"
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(index)
        command_output(["git", "read-tree", "HEAD"], env=env)
        subprocess.run(
            ["git", "add", "-A", "--", "."],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        tree = command_output(["git", "write-tree"], env=env)
    return tree, dirty


def percentage(covered: int, count: int) -> float:
    return 100.0 if count == 0 else covered * 100.0 / count


def metric_summary(covered: int, count: int) -> dict[str, int | float]:
    return {
        "covered": covered,
        "count": count,
        "percent": percentage(covered, count),
    }


def production_relative(filename: str) -> str | None:
    try:
        relative = Path(filename).resolve().relative_to(ROOT.resolve())
    except ValueError:
        return None
    value = relative.as_posix()
    if not value.startswith("Sources/") or value.startswith("Sources/FoveaTesting/"):
        return None
    return value


def uncovered_functions(raw: dict[str, object]) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    for function in raw.get("functions", []):
        if not isinstance(function, dict) or function.get("count") != 0:
            continue
        filenames = function.get("filenames")
        if not isinstance(filenames, list):
            continue
        relative = next(
            (
                production_relative(filename)
                for filename in filenames
                if isinstance(filename, str) and production_relative(filename) is not None
            ),
            None,
        )
        if relative is None:
            continue
        regions = function.get("regions")
        start_line = None
        if isinstance(regions, list) and regions and isinstance(regions[0], list) and regions[0]:
            start_line = regions[0][0]
        results.append(
            {
                "file": relative,
                "startLine": start_line,
                "symbol": str(function.get("name", "unknown"))[:512],
            }
        )
    return sorted(results, key=lambda item: (str(item["file"]), item["startLine"] or 0))


def main() -> int:
    test = run(
        [
            "python3",
            "scripts/run-swift-strict.py",
            "test",
            "--enable-code-coverage",
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

    raw = json.loads(coverage_path.read_text())["data"][0]
    aggregate = {metric: [0, 0] for metric in THRESHOLDS}
    modules: dict[str, dict[str, list[int]]] = defaultdict(
        lambda: {metric: [0, 0] for metric in THRESHOLDS}
    )
    files: dict[str, dict[str, dict[str, int | float]]] = {}
    for file in raw["files"]:
        relative = production_relative(file["filename"])
        if relative is None:
            continue
        parts = Path(relative).parts
        if len(parts) < 3:
            continue
        module = parts[1]
        file_metrics: dict[str, dict[str, int | float]] = {}
        for metric in THRESHOLDS:
            summary = file["summary"][metric]
            covered = int(summary["covered"])
            count = int(summary["count"])
            aggregate[metric][0] += covered
            aggregate[metric][1] += count
            modules[module][metric][0] += covered
            modules[module][metric][1] += count
            file_metrics[metric] = metric_summary(covered, count)
        files[relative] = file_metrics

    if not files:
        print("coverage export contains no production source files", file=sys.stderr)
        return 1

    totals = {
        metric: {
            **metric_summary(covered, count),
            "minimumPercent": THRESHOLDS[metric],
        }
        for metric, (covered, count) in aggregate.items()
    }
    module_summaries = {
        module: {
            metric: metric_summary(values[0], values[1])
            for metric, values in metrics.items()
        }
        for module, metrics in sorted(modules.items())
    }
    aggregate_failures = [
        metric
        for metric, summary in totals.items()
        if summary["percent"] < summary["minimumPercent"]
    ]
    module_failures: list[dict[str, object]] = []
    for module, minimum in MODULE_LINE_THRESHOLDS.items():
        summary = module_summaries.get(module)
        if summary is None:
            module_failures.append(
                {
                    "module": module,
                    "reason": "missing-from-coverage-export",
                    "minimumLinePercent": minimum,
                }
            )
        elif summary["lines"]["percent"] < minimum:
            module_failures.append(
                {
                    "module": module,
                    "reason": "line-coverage-below-minimum",
                    "linePercent": summary["lines"]["percent"],
                    "minimumLinePercent": minimum,
                }
            )

    file_failures: list[dict[str, object]] = []
    for path, minimum in CRITICAL_FILE_LINE_THRESHOLDS.items():
        summary = files.get(path)
        if summary is None:
            file_failures.append(
                {
                    "file": path,
                    "reason": "missing-from-coverage-export",
                    "minimumLinePercent": minimum,
                }
            )
        elif summary["lines"]["percent"] < minimum:
            file_failures.append(
                {
                    "file": path,
                    "reason": "critical-file-line-coverage-below-minimum",
                    "linePercent": summary["lines"]["percent"],
                    "minimumLinePercent": minimum,
                }
            )
    for path, summary in files.items():
        lines = summary["lines"]
        if (
            lines["count"] >= NONTRIVIAL_FILE_MINIMUM_LINES
            and lines["percent"] < NONTRIVIAL_FILE_LINE_FLOOR
            and path not in CRITICAL_FILE_LINE_THRESHOLDS
        ):
            file_failures.append(
                {
                    "file": path,
                    "reason": "nontrivial-file-line-coverage-below-floor",
                    "linePercent": lines["percent"],
                    "minimumLinePercent": NONTRIVIAL_FILE_LINE_FLOOR,
                }
            )

    verified_tree, includes_working_tree_changes = workspace_tree()
    report = {
        "schemaVersion": 2,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "verifiedCommit": command_output(["git", "rev-parse", "HEAD"]),
        "verifiedTree": verified_tree,
        "includesWorkingTreeChanges": includes_working_tree_changes,
        "scope": "Sources excluding FoveaTesting and generated files",
        "includedFileCount": len(files),
        "totals": totals,
        "modules": module_summaries,
        "files": dict(sorted(files.items())),
        "moduleLineThresholds": MODULE_LINE_THRESHOLDS,
        "criticalFileLineThresholds": CRITICAL_FILE_LINE_THRESHOLDS,
        "nontrivialFileLineFloor": {
            "minimumExecutableLines": NONTRIVIAL_FILE_MINIMUM_LINES,
            "minimumPercent": NONTRIVIAL_FILE_LINE_FLOOR,
        },
        "uncoveredFunctions": uncovered_functions(raw),
        "status": "passed"
        if not (aggregate_failures or module_failures or file_failures)
        else "failed",
        "failedMetrics": aggregate_failures,
        "failedModules": module_failures,
        "failedFiles": file_failures,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    summary = ", ".join(
        f"{metric}={values['percent']:.2f}% (min {values['minimumPercent']:.2f}%)"
        for metric, values in totals.items()
    )
    print(f"Production coverage {report['status']}: {summary}")
    if file_failures:
        for failure in file_failures:
            print(
                f"file coverage failure: {failure['file']} "
                f"{failure.get('linePercent', 'missing')}% < {failure['minimumLinePercent']}%",
                file=sys.stderr,
            )
    print(f"Artifact: {ARTIFACT.relative_to(ROOT)}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
