#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")
TEST_DEFINITION = re.compile(r"\*\*([A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+-\d{3})\*\*")
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")

errors: list[str] = []
markdown_files = sorted(
    {
        *ROOT.glob("*.md"),
        *DOCS.rglob("*.md"),
        *(ROOT / "Examples").rglob("*.md"),
        *(ROOT / "evidence").rglob("*.md"),
    }
)

for obsolete in (DOCS / "archive", DOCS / "ARCHITECTURE_V2.md"):
    if obsolete.exists():
        errors.append(f"obsolete document exists: {obsolete.relative_to(ROOT)}")

for path in markdown_files:
    text = path.read_text()
    if "docs/archive/" in text or "ARCHITECTURE_V2.md" in text:
        errors.append(f"obsolete architecture reference: {path.relative_to(ROOT)}")

    heading_numbers: dict[int, list[int]] = defaultdict(list)
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = HEADING.match(line)
        if not match:
            continue
        title = match.group(2)
        numbered = re.match(r"(\d+)\.\s", title)
        if numbered:
            heading_numbers[len(match.group(1))].append(int(numbered.group(1)))
    for level, numbers in heading_numbers.items():
        for previous, current in zip(numbers, numbers[1:]):
            if current == previous:
                errors.append(
                    f"duplicate numbered heading in {path.relative_to(ROOT)} at level {level}: {current}"
                )

    for match in MARKDOWN_LINK.finditer(text):
        raw_target = match.group(1).strip().split()[0].strip("<>")
        if not raw_target or raw_target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        file_target = raw_target.split("#", 1)[0]
        if not file_target:
            continue
        resolved = (path.parent / file_target).resolve()
        try:
            resolved.relative_to(ROOT.resolve())
        except ValueError:
            errors.append(
                f"local link escapes repository in {path.relative_to(ROOT)}: {raw_target}"
            )
            continue
        if not resolved.exists():
            errors.append(f"broken local link in {path.relative_to(ROOT)}: {raw_target}")

definitions: dict[str, list[str]] = defaultdict(list)
for path in sorted((DOCS / "specifications").glob("*.md")):
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        for identifier in TEST_DEFINITION.findall(line):
            definitions[identifier].append(f"{path.relative_to(ROOT)}:{line_number}")
for path in sorted((DOCS / "adr").glob("*.md")):
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        for identifier in TEST_DEFINITION.findall(line):
            definitions[identifier].append(f"{path.relative_to(ROOT)}:{line_number}")

for identifier, locations in sorted(definitions.items()):
    if len(locations) > 1:
        errors.append(f"duplicate test definition {identifier}: {', '.join(locations)}")

required_ids_path = DOCS / "current-required-ids.json"
required_ids_data = json.loads(required_ids_path.read_text())
if required_ids_data.get("schemaVersion") != 1:
    errors.append("current required ID manifest schema mismatch")
required_current_ids = set(required_ids_data.get("ids", []))
if not required_current_ids:
    errors.append("current required ID manifest must not be empty")
all_docs_text = "\n".join(path.read_text() for path in markdown_files)
traceability = json.loads((DOCS / "test-traceability.json").read_text())
traceability_ids = {entry["id"] for entry in traceability.get("requirements", [])}
for identifier in sorted(required_current_ids):
    if identifier not in all_docs_text:
        errors.append(f"current required ID missing from active docs: {identifier}")
    if identifier not in traceability_ids:
        errors.append(f"current required ID missing from traceability manifest: {identifier}")

if errors:
    print("Documentation checks failed:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"Documentation checks passed: {len(markdown_files)} Markdown files, "
    f"{len(definitions)} explicit test definitions."
)
