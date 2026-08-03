#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from ios_example_process import inactivity_expired, terminate_process_group

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_ROOT = ROOT / ".artifacts/docs"
DERIVED_DATA = ARTIFACT_ROOT / "DerivedData"
LOG = ARTIFACT_ROOT / "docbuild.log"
DOC_BUILD_DESTINATIONS = (
    ("macOS", "platform=macOS"),
    ("iOS", "generic/platform=iOS Simulator"),
)
DOC_BUILD_TOTAL_TIMEOUT_SECONDS = 900
DOC_BUILD_INACTIVITY_TIMEOUT_SECONDS = 180
REPORT = ARTIFACT_ROOT / "documentation.json"
PUBLIC_API_BUDGET = ROOT / "docs/public-api-budget.json"
PRODUCTION_MODULES = {
    "FoveaAdvancedSystem",
    "FoveaAppKit",
    "FoveaCore",
    "FoveaHTTP",
    "FoveaObservability",
    "FoveaPersistence",
    "FoveaSwiftUI",
    "FoveaStorage",
    "FoveaSystem",
    "FoveaUIKit",
}
PUBLIC_TYPE_KINDS = {
    "swift.class",
    "swift.struct",
    "swift.enum",
    "swift.protocol",
    "swift.typealias",
}


def run_documentation_build(
    command: list[str],
    *,
    env: dict[str, str],
    platform_name: str,
    log: Path = LOG,
) -> tuple[int, str | None]:
    log.parent.mkdir(parents=True, exist_ok=True)
    started_at = last_activity_at = time.monotonic()
    failure: str | None = None
    return_code: int | None = None
    with log.open("a", encoding="utf-8") as stream:
        stream.write(f"===== {platform_name} documentation build =====\n")
        stream.flush()
        last_size = log.stat().st_size
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        while True:
            return_code = process.poll()
            if return_code is not None:
                break
            time.sleep(1)
            now = time.monotonic()
            current_size = log.stat().st_size
            if current_size != last_size:
                last_size = current_size
                last_activity_at = now
            if inactivity_expired(
                last_activity_at, now, DOC_BUILD_INACTIVITY_TIMEOUT_SECONDS
            ):
                failure = (
                    f"{platform_name} documentation build made no log progress for "
                    f"{DOC_BUILD_INACTIVITY_TIMEOUT_SECONDS} seconds"
                )
                terminate_process_group(process)
                break
            if now - started_at >= DOC_BUILD_TOTAL_TIMEOUT_SECONDS:
                failure = (
                    f"{platform_name} documentation build exceeded total timeout of "
                    f"{DOC_BUILD_TOTAL_TIMEOUT_SECONDS} seconds"
                )
                terminate_process_group(process)
                break
    if failure is not None:
        with log.open("a", encoding="utf-8") as stream:
            stream.write(f"\n=== {failure} ===\n")
        return -1, failure
    return int(return_code or 0), None


def command_output(command: list[str], *, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def workspace_tree() -> tuple[str, bool]:
    dirty = bool(command_output(["git", "status", "--porcelain"]))
    with tempfile.TemporaryDirectory(prefix="fovea-docs-index-") as temporary:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(Path(temporary) / "index")
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


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentage(documented: int, total: int) -> float:
    return 100.0 if total == 0 else documented * 100.0 / total


def fovea_owned_warning_lines(text: str) -> list[str]:
    root = ROOT.as_posix().rstrip("/") + "/"
    prefixes = tuple(root + value for value in ("Sources/", "Tests/", "Tools/", "Examples/"))
    results: list[str] = []
    for line in text.splitlines():
        normalized = line.replace("\\", "/")
        if "warning:" not in normalized.lower():
            continue
        if normalized.startswith(prefixes) or "from project 'Fovea'" in normalized:
            results.append(line)
    return results


def main() -> int:
    try:
        public_api_budget = json.loads(PUBLIC_API_BUDGET.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f"Invalid public API budget: {error}", file=sys.stderr)
        return 1
    if public_api_budget.get("schemaVersion") != 1:
        print("Public API budget schemaVersion must be 1", file=sys.stderr)
        return 1
    module_budgets = public_api_budget.get("modules")
    if not isinstance(module_budgets, dict) or set(module_budgets) != PRODUCTION_MODULES:
        print("Public API budget modules do not match production modules", file=sys.stderr)
        return 1
    minimum_documentation_percent = public_api_budget.get(
        "minimumDocumentedPublicSymbolPercent"
    )
    maximum_total_symbols = public_api_budget.get("maximumTotalPublicSymbols")
    if not isinstance(minimum_documentation_percent, (int, float)) or not 0 <= minimum_documentation_percent <= 100:
        print("Invalid public API documentation budget", file=sys.stderr)
        return 1
    if not isinstance(maximum_total_symbols, int) or maximum_total_symbols < 0:
        print("Invalid total public API symbol budget", file=sys.stderr)
        return 1

    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    if os.environ.get("FOVEA_REUSE_DOCC_DERIVED_DATA") != "1":
        shutil.rmtree(DERIVED_DATA, ignore_errors=True)
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = command_output([str(ROOT / "scripts/select-xcode.sh")])
    LOG.write_text("")
    for platform_name, destination in DOC_BUILD_DESTINATIONS:
        platform_derived_data = DERIVED_DATA / platform_name
        command = [
            "xcodebuild",
            "docbuild",
            "-scheme",
            "Fovea-Package",
            "-destination",
            destination,
            "-derivedDataPath",
            str(platform_derived_data),
            "APPINTENTS_METADATA_PROCESSING_ENABLED=NO",
        ]
        return_code, failure = run_documentation_build(
            command, env=env, platform_name=platform_name
        )
        if return_code != 0:
            detail = failure or f"exit {return_code}"
            print(f"{platform_name} documentation build failed: {detail}", file=sys.stderr)
            print("\n".join(LOG.read_text(errors="replace").splitlines()[-120:]), file=sys.stderr)
            return 124 if return_code < 0 else return_code

    owned_warnings = fovea_owned_warning_lines(LOG.read_text(errors="replace"))
    if owned_warnings:
        print("Fovea-owned documentation build warnings are forbidden:", file=sys.stderr)
        for line in owned_warnings[:100]:
            print(f"- {line}", file=sys.stderr)
        return 2

    graph_paths = list(
        DERIVED_DATA.glob(
            "**/Build/Intermediates.noindex/**/symbol-graph/swift/*/*.symbols.json"
        )
    )
    candidate_graphs: dict[str, list[Path]] = {}
    for path in graph_paths:
        data = json.loads(path.read_text())
        module = data.get("module", {}).get("name")
        if module in PRODUCTION_MODULES:
            candidate_graphs.setdefault(module, []).append(path)

    def graph_score(module: str, path: Path) -> tuple[int, int]:
        path_text = str(path)
        platform_preference = 0
        if module == "FoveaUIKit" and f"{os.sep}iOS{os.sep}" in path_text:
            platform_preference = 2
        elif module == "FoveaAppKit" and f"{os.sep}macOS{os.sep}" in path_text:
            platform_preference = 2
        symbol_count = len(json.loads(path.read_text()).get("symbols", []))
        return platform_preference, symbol_count

    by_module = {
        module: max(paths, key=lambda path: graph_score(module, path))
        for module, paths in candidate_graphs.items()
    }

    missing_modules = sorted(PRODUCTION_MODULES - by_module.keys())
    modules: dict[str, dict[str, object]] = {}
    missing_public_types: list[dict[str, str]] = []
    undocumented_symbols: list[dict[str, str]] = []
    total_types = documented_types = total_symbols = documented_symbols = 0
    for module in sorted(PRODUCTION_MODULES):
        path = by_module.get(module)
        if path is None:
            continue
        data = json.loads(path.read_text())
        module_type_total = module_type_documented = 0
        module_symbol_total = module_symbol_documented = 0
        for symbol in data.get("symbols", []):
            if symbol.get("accessLevel") not in {"public", "open"}:
                continue
            precise = symbol.get("identifier", {}).get("precise", "")
            if "::SYNTHESIZED::" in precise or "location" not in symbol:
                continue
            has_docs = bool(symbol.get("docComment", {}).get("lines"))
            kind = symbol.get("kind", {}).get("identifier", "")
            name = ".".join(symbol.get("pathComponents", []))
            module_symbol_total += 1
            module_symbol_documented += int(has_docs)
            if not has_docs and len(undocumented_symbols) < 500:
                undocumented_symbols.append(
                    {"module": module, "kind": kind, "symbol": name}
                )
            if kind in PUBLIC_TYPE_KINDS:
                module_type_total += 1
                module_type_documented += int(has_docs)
                if not has_docs:
                    missing_public_types.append(
                        {"module": module, "kind": kind, "symbol": name}
                    )
        total_types += module_type_total
        documented_types += module_type_documented
        total_symbols += module_symbol_total
        documented_symbols += module_symbol_documented
        modules[module] = {
            "publicTypeCount": module_type_total,
            "documentedPublicTypeCount": module_type_documented,
            "publicTypeDocumentationPercent": percentage(
                module_type_documented, module_type_total
            ),
            "publicSymbolCount": module_symbol_total,
            "documentedPublicSymbolCount": module_symbol_documented,
            "publicSymbolDocumentationPercent": percentage(
                module_symbol_documented, module_symbol_total
            ),
        }

    archives = sorted(
        {
            path.stem
            for path in DERIVED_DATA.glob("**/*.doccarchive")
            if path.stem in PRODUCTION_MODULES
        }
    )
    tree, dirty = workspace_tree()
    public_type_percent = percentage(documented_types, total_types)
    public_symbol_percent = percentage(documented_symbols, total_symbols)
    budget_violations = {
        module: {
            "actual": int(modules.get(module, {}).get("publicSymbolCount", 0)),
            "maximum": maximum,
        }
        for module, maximum in module_budgets.items()
        if not isinstance(maximum, int)
        or maximum < 0
        or int(modules.get(module, {}).get("publicSymbolCount", 0)) > maximum
    }
    if total_symbols > maximum_total_symbols:
        budget_violations["__total__"] = {
            "actual": total_symbols,
            "maximum": maximum_total_symbols,
        }
    status = (
        "passed"
        if not missing_modules
        and not missing_public_types
        and public_symbol_percent >= minimum_documentation_percent
        and not budget_violations
        and set(archives) == PRODUCTION_MODULES
        else "failed"
    )
    report = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "verifiedCommit": command_output(["git", "rev-parse", "HEAD"]),
        "verifiedTree": tree,
        "includesWorkingTreeChanges": dirty,
        "status": status,
        "xcodeVersion": command_output(["xcodebuild", "-version"], env=env),
        "log": str(LOG.relative_to(ROOT)),
        "logSha256": sha256(LOG),
        "archives": archives,
        "foveaOwnedWarningLines": len(owned_warnings),
        "modules": modules,
        "totals": {
            "publicTypeCount": total_types,
            "documentedPublicTypeCount": documented_types,
            "publicTypeDocumentationPercent": public_type_percent,
            "publicTypeMinimumPercent": 100.0,
            "publicSymbolCount": total_symbols,
            "documentedPublicSymbolCount": documented_symbols,
            "publicSymbolDocumentationPercent": public_symbol_percent,
            "publicSymbolMinimumPercent": minimum_documentation_percent,
            "publicSymbolMaximumCount": maximum_total_symbols,
        },
        "publicAPIBudget": {
            "path": str(PUBLIC_API_BUDGET.relative_to(ROOT)),
            "sha256": sha256(PUBLIC_API_BUDGET),
            "violations": budget_violations,
        },
        "missingModules": missing_modules,
        "missingPublicTypes": missing_public_types,
        "undocumentedSymbols": undocumented_symbols,
    }
    REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Documentation verification "
        f"{status}: types={documented_types}/{total_types} "
        f"({public_type_percent:.2f}%), symbols={documented_symbols}/{total_symbols} "
        f"({public_symbol_percent:.2f}%)"
    )
    print(f"Artifact: {REPORT.relative_to(ROOT)} sha256:{sha256(REPORT)}")
    if status != "passed":
        if missing_modules:
            print(f"Missing symbol graphs: {missing_modules}", file=sys.stderr)
        if missing_public_types:
            print(f"Undocumented public types: {missing_public_types}", file=sys.stderr)
        if public_symbol_percent < minimum_documentation_percent:
            print(
                "Public symbol documentation below budget: "
                f"{public_symbol_percent:.2f}% < {minimum_documentation_percent:.2f}%",
                file=sys.stderr,
            )
        if budget_violations:
            print(f"Public API budget violations: {budget_violations}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
