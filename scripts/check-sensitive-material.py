#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

from image_metadata import ImageMetadataError, contains_sensitive_image_metadata

ROOT = Path(__file__).resolve().parents[1]
MAX_TEXT_BYTES = 2 * 1024 * 1024
MAX_SECRET_SCAN_BYTES = 16 * 1024 * 1024
FORBIDDEN_SUFFIXES = {
    ".p12",
    ".pfx",
    ".mobileprovision",
    ".profraw",
    ".profdata",
}
FORBIDDEN_NAMES = {".DS_Store", ".env"}
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
TEXT_SUFFIXES = {
    ".swift", ".py", ".sh", ".yml", ".yaml", ".json", ".md", ".txt",
    ".plist", ".xcconfig", ".pbxproj", ".toml", ".lock",
}


def repository_files() -> list[Path]:
    output = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout
    return [ROOT / item.decode() for item in output.split(b"\0") if item]


def is_test_or_documentation(path: Path) -> bool:
    relative = path.relative_to(ROOT)
    parts = set(relative.parts)
    return (
        "Tests" in parts
        or "FoveaTesting" in parts
        or any(part.endswith("Tests") for part in parts)
        or relative.parts[0] == "docs"
    )


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def byte_line_number(data: bytes, offset: int) -> int:
    return data.count(b"\n", 0, offset) + 1


def secret_byte_patterns() -> dict[str, re.Pattern[bytes]]:
    return {
        "private-key": re.compile(
            re.escape(("-" * 5 + "BEGIN ").encode())
            + rb"(?:RSA |EC |OPENSSH )?PRIVATE KEY"
            + re.escape(("-" * 5).encode())
        ),
        "aws-access-key": re.compile((("AK" + "IA").encode()) + rb"[0-9A-Z]{16}"),
        "google-api-key": re.compile((("AI" + "za").encode()) + rb"[0-9A-Za-z_-]{30,}"),
        "github-token": re.compile((("gh").encode() + rb"[pousr]_") + rb"[0-9A-Za-z]{20,}"),
        "slack-token": re.compile((("xo").encode() + rb"x[baprs]-") + rb"[0-9A-Za-z-]{10,}"),
    }


def main() -> int:
    violations: list[tuple[str, Path, int | None]] = []
    binary_secret_patterns = secret_byte_patterns()
    absolute_home = re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+/")
    signed_url = re.compile(
        r"https?://[^\s\"'<>]+[?&]"
        r"(?:access[_-]?token|auth|key|secret|sig|signature|token)="
        r"[^\s\"'<>]+",
        re.IGNORECASE,
    )

    for path in repository_files():
        relative = path.relative_to(ROOT)
        if any(part in {".build", ".artifacts", "DerivedData"} for part in relative.parts):
            continue
        if path.is_symlink():
            violations.append(("repository-symlink", relative, None))
            continue
        if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            violations.append(("forbidden-file", relative, None))
        if "xcuserdata" in relative.parts:
            violations.append(("xcode-user-data", relative, None))
        if path.name.startswith(".env") and path.name not in {".env.example", ".env.sample"}:
            violations.append(("environment-file", relative, None))
        if not path.is_file():
            continue

        size = path.stat().st_size
        data: bytes | None = None
        if size <= MAX_SECRET_SCAN_BYTES:
            data = path.read_bytes()
            for rule, pattern in binary_secret_patterns.items():
                for match in pattern.finditer(data):
                    violations.append((rule, relative, byte_line_number(data, match.start())))
        if path.suffix.lower() in IMAGE_SUFFIXES and data is not None:
            try:
                if contains_sensitive_image_metadata(data):
                    violations.append(("embedded-image-metadata", relative, None))
            except ImageMetadataError:
                violations.append(("malformed-image-container", relative, None))
        if size > MAX_TEXT_BYTES:
            continue
        if path.suffix.lower() not in TEXT_SUFFIXES and path.name not in {"Package.swift", "Dockerfile"}:
            try:
                text = path.read_text()
            except UnicodeDecodeError:
                continue
        else:
            try:
                text = path.read_text()
            except UnicodeDecodeError:
                violations.append(("invalid-text-encoding", relative, None))
                continue
        for match in absolute_home.finditer(text):
            violations.append(("absolute-home-path", relative, line_number(text, match.start())))
        if not is_test_or_documentation(path):
            for match in signed_url.finditer(text):
                violations.append(("credential-bearing-url", relative, line_number(text, match.start())))

    if violations:
        print("Sensitive material check failed:", file=sys.stderr)
        for rule, path, line in sorted(set(violations), key=lambda item: (str(item[1]), item[2] or 0, item[0])):
            location = f"{path}:{line}" if line is not None else str(path)
            print(f"- {rule}: {location}", file=sys.stderr)
        return 1
    print(f"Sensitive material check passed: {len(repository_files())} repository files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
