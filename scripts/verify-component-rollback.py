#!/usr/bin/env python3
"""Exercise public component rollback pins and restore the current exact graph."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / "docs/project-memory/component-pins.json"
PLAN = ROOT / "docs/project-memory/component-rollback-plan.json"
ARTIFACT = ROOT / ".artifacts/external-components/rollback.json"
LOG_DIR = ROOT / ".artifacts/external-components/rollback-logs"
COPY_PATHS = ("Sources", "Tests", "Tools", "Examples/FoveaGalleryDemo")


def run(command: list[str], cwd: Path, env: dict[str, str], timeout: int = 900) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=False, timeout=timeout)


def load_current() -> dict[str, dict[str, object]]:
    return json.loads(PINS.read_text())["components"]


def copy_source(destination: Path) -> None:
    shutil.copy2(ROOT / "Package.swift", destination / "Package.swift")
    for relative in COPY_PATHS:
        shutil.copytree(ROOT / relative, destination / relative,
                        ignore=shutil.ignore_patterns(".DS_Store", ".build", ".swiftpm", ".artifacts", "__pycache__", "*.pyc"))


def patch_package(path: Path, current: dict[str, dict[str, object]], component: str | None, revision: str | None) -> dict[str, str]:
    expected = {name: str(value["revision"]) for name, value in current.items()}
    if component is not None:
        old = expected[component]
        text = path.read_text()
        if text.count(old) != 1:
            raise RuntimeError(f"expected exactly one current pin for {component}")
        path.write_text(text.replace(old, str(revision)))
        expected[component] = str(revision)
    return expected


def resolved_revisions(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text())
    return {pin["identity"].lower(): pin["state"]["revision"] for pin in data.get("pins", [])}


def digest_logs(results: list[dict[str, object]]) -> str:
    rows = "\n".join(f"{item['id']}:{item['logSHA256']}" for item in results)
    return hashlib.sha256(rows.encode()).hexdigest()


def main() -> int:
    plan = json.loads(PLAN.read_text())
    current = load_current()
    if plan.get("currentPins") != {name: value["revision"] for name, value in current.items()}:
        raise SystemExit("rollback plan current pins drifted")
    env = os.environ.copy()
    selected = run([str(ROOT / "scripts/select-xcode.sh")], ROOT, env, 30)
    if selected.returncode != 0:
        print(selected.stdout)
        return selected.returncode
    env["DEVELOPER_DIR"] = selected.stdout.strip()
    expected_count = int(plan["expectedHostTestCount"])
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, object]] = []
    for scenario in plan["scenarios"]:
        with tempfile.TemporaryDirectory(prefix=f"fovea-rollback-{scenario['id']}-") as directory:
            copy = Path(directory) / "Fovea"
            copy.mkdir()
            copy_source(copy)
            expected = patch_package(copy / "Package.swift", current, scenario["component"], scenario["revision"])
            resolve = run(["xcrun", "swift", "package", "resolve"], copy, env)
            if resolve.returncode != 0:
                print(resolve.stdout)
                return resolve.returncode
            observed = resolved_revisions(copy / "Package.resolved")
            expected_lower = {name.lower(): revision for name, revision in expected.items()}
            if observed != expected_lower:
                print(f"{scenario['id']}: resolved pins drifted: {observed!r}")
                return 1
            test = run(["xcrun", "swift", "test"], copy, env)
            log_path = LOG_DIR / f"{scenario['id']}.log"
            log_path.write_text(test.stdout)
            counts = [int(value) for value in re.findall(r"Executed (\d+) tests", test.stdout)]
            count = max(counts, default=0)
            if test.returncode != 0 or count != expected_count:
                print(f"{scenario['id']}: host test failure return={test.returncode} count={count}")
                return 1
            results.append({
                "id": scenario["id"],
                "classification": scenario["classification"],
                "resolvedRevisions": observed,
                "testCount": count,
                "logSHA256": hashlib.sha256(test.stdout.encode()).hexdigest(),
            })
            print(f"{scenario['id']}: passed {count} tests")
    report = {
        "schemaVersion": 1,
        "status": "passed",
        "planID": plan["planID"],
        "results": results,
        "combinedLogSHA256": digest_logs(results),
        "hostPassDoesNotOverrideComponentCI": True,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"External component rollback passed: scenarios={len(results)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
