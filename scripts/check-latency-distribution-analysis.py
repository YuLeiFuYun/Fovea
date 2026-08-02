#!/usr/bin/env python3
"""用支配、相同与交叉分布验证分布诊断器的判定边界。"""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/analyze-latency-distributions.py"
ARTIFACT = ROOT / ".artifacts/mathematics/latency-distribution-verification.json"


def run_case(kind: str) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / f"{kind}.json"
        subprocess.run(
            ["python3", str(SCRIPT), "--synthetic", kind, "--iterations", "2000", "--output", str(output)],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(output.read_text())


def main() -> int:
    dominant = run_case("dominant")
    equal = run_case("equal")
    crossing = run_case("crossing")
    errors: list[str] = []
    if dominant["empiricalFSDViolation"] != 0:
        errors.append("dominant synthetic case has an empirical FSD violation")
    if equal["wasserstein1"] != 0:
        errors.append("equal synthetic case has nonzero W1")
    if crossing["empiricalFSDViolation"] <= 0:
        errors.append("crossing synthetic case did not expose an FSD violation")
    if crossing["dominanceClassification"] != "dominance-inconclusive-or-crossing":
        errors.append("crossing synthetic case was promoted to dominance")
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps({
        "schemaVersion": 1,
        "status": "failed" if errors else "passed",
        "cases": {
            "dominant": dominant["dominanceClassification"],
            "equal": equal["wassersteinClassification"],
            "crossing": crossing["dominanceClassification"],
        },
        "errors": errors,
    }, indent=2, sort_keys=True) + "\n")
    print(f"Latency distribution verification: errors={len(errors)}")
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
