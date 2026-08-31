#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUDGET = ROOT / "docs/public-api-budget.json"
PRODUCTS = ROOT / ".build/out/Products/Debug-iphonesimulator"
MODULE = PRODUCTS / "FoveaUIKit.swiftmodule/arm64-apple-ios-simulator.swiftmodule"
EXPECTED_SPI_TITLES = {
    "FoveaAnimationPresentationDiagnosticsSnapshot",
    "acceptedTargetCount",
    "consumedTargetCount",
    "supersededPendingTargetCount",
    "rejectedNonmonotonicTargetCount",
    "lifecycleClearedPendingTargetCount",
    "hasPendingTarget",
    "lastAcceptedTargetNanoseconds",
    "isDisplayLinkPaused",
    "effectiveVisibility",
    "animationPresentationDiagnostics",
    "isHidden",
    "alpha",
    "didMoveToSuperview()",
    "layoutSubviews()",
    "startSyntheticAnimationPresentationBenchmark(frameCount:frameDurationNanoseconds:providerDelayNanoseconds:)",
}


def output(command: list[str], *, env: dict[str, str]) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"{completed.stdout}{completed.stderr}"
        )
    return completed.stdout.strip()


def public_budget_symbols(path: pathlib.Path) -> list[dict[str, object]]:
    data = json.loads(path.read_text())
    results: list[dict[str, object]] = []
    for symbol in data.get("symbols", []):
        if symbol.get("accessLevel") not in {"public", "open"}:
            continue
        precise = symbol.get("identifier", {}).get("precise", "")
        if "::SYNTHESIZED::" in precise or "location" not in symbol:
            continue
        results.append(symbol)
    return results


def extract(
    destination: pathlib.Path,
    *,
    env: dict[str, str],
    sdk: str,
    include_spi: bool,
) -> pathlib.Path:
    destination.mkdir(parents=True, exist_ok=True)
    command = [
        "xcrun",
        "swift-symbolgraph-extract",
        "-module-name",
        "FoveaUIKit",
        "-I",
        str(PRODUCTS),
        "-F",
        str(PRODUCTS / "PackageFrameworks"),
        "-target",
        "arm64-apple-ios15.0-simulator",
        "-sdk",
        sdk,
        "-minimum-access-level",
        "public",
    ]
    if include_spi:
        command.append("-include-spi-symbols")
    command += ["-output-dir", str(destination)]
    output(command, env=env)
    result = destination / "FoveaUIKit.symbols.json"
    if not result.is_file():
        raise SystemExit("FoveaUIKit symbol graph was not generated")
    return result


def main() -> int:
    budget = json.loads(BUDGET.read_text())
    maximum = (budget.get("modules") or {}).get("FoveaUIKit")
    if not isinstance(maximum, int) or maximum < 0:
        raise SystemExit("invalid FoveaUIKit public API budget")

    env = os.environ.copy()
    env["DEVELOPER_DIR"] = output([str(ROOT / "scripts/select-xcode.sh")], env=env)
    output(
        [
            "xcrun",
            "swift",
            "build",
            "--target",
            "FoveaUIKit",
            "--triple",
            "arm64-apple-ios15.0-simulator",
            "-Xswiftc",
            "-warnings-as-errors",
        ],
        env=env,
    )
    if not MODULE.is_file():
        raise SystemExit(f"missing rebuilt FoveaUIKit module: {MODULE}")
    sdk = output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], env=env)

    with tempfile.TemporaryDirectory(prefix="foveauikit-api-budget-") as temporary:
        root = pathlib.Path(temporary)
        default_graph = extract(root / "default", env=env, sdk=sdk, include_spi=False)
        spi_graph = extract(root / "spi", env=env, sdk=sdk, include_spi=True)
        default_symbols = public_budget_symbols(default_graph)
        spi_symbols = public_budget_symbols(spi_graph)
        consumer = root / "public-consumer.swift"
        consumer.write_text(
            "import FoveaUIKit\n"
            "import UIKit\n"
            "func exercise(_ view: FoveaImageView) {\n"
            "    view.isHidden = true\n"
            "    view.alpha = 0.5\n"
            "    view.layoutSubviews()\n"
            "    view.didMoveToSuperview()\n"
            "}\n"
        )
        output(
            [
                "xcrun",
                "swiftc",
                "-typecheck",
                str(consumer),
                "-I",
                str(PRODUCTS),
                "-F",
                str(PRODUCTS / "PackageFrameworks"),
                "-target",
                "arm64-apple-ios15.0-simulator",
                "-sdk",
                sdk,
            ],
            env=env,
        )

    default_titles = {
        str(symbol.get("names", {}).get("title", "")) for symbol in default_symbols
    }
    if len(default_symbols) > maximum:
        raise SystemExit(
            f"FoveaUIKit public API budget exceeded: {len(default_symbols)} > {maximum}"
        )
    leaked = sorted(EXPECTED_SPI_TITLES & default_titles)
    if leaked:
        raise SystemExit(f"FoveaUIKit SPI symbols leaked into default graph: {leaked}")

    spi_by_title = {
        str(symbol.get("names", {}).get("title", "")): symbol for symbol in spi_symbols
    }
    missing = sorted(EXPECTED_SPI_TITLES - set(spi_by_title))
    if missing:
        raise SystemExit(f"FoveaUIKit expected SPI symbols missing: {missing}")
    non_spi = sorted(
        title
        for title in EXPECTED_SPI_TITLES
        if spi_by_title[title].get("spi") is not True
    )
    if non_spi:
        raise SystemExit(f"FoveaUIKit diagnostic/lifecycle symbols are not SPI: {non_spi}")

    print(
        "FoveaUIKit API budget passed: "
        f"default={len(default_symbols)}/{maximum} "
        f"spi={len(spi_symbols)} expectedSPI={len(EXPECTED_SPI_TITLES)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
