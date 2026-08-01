#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/research/reference-provenance.json"
ALLOWED_KINDS = {
    "standard",
    "officialDocumentation",
    "languageProposal",
    "paper",
    "referenceImplementation",
    "buildTool",
}
ALLOWED_DISPOSITIONS = {"adopted", "reference", "candidate", "deferred"}
AUTHORITY_HOSTS = {
    "IETF": {"www.rfc-editor.org", "datatracker.ietf.org"},
    "Apple": {"developer.apple.com"},
    "Swift": {"github.com"},
    "USENIX NSDI": {"www.usenix.org"},
    "JPEG Committee": {"jpeg.org", "www.jpeg.org"},
    "C2PA": {"spec.c2pa.org", "c2pa.org"},
    "kean/Nuke": {"github.com"},
    "onevcat/Kingfisher": {"github.com"},
    "SDWebImage/SDWebImage": {"github.com"},
    "yonaskolb/XcodeGen": {"github.com"},
}


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    data = json.loads(MANIFEST.read_text())
    if data.get("schemaVersion") != 1:
        fail("reference provenance schemaVersion must be 1")
    reviewed_on = dt.date.fromisoformat(data["reviewedOn"])
    if reviewed_on > dt.date.today():
        fail("reference provenance reviewedOn is in the future")
    entries = data.get("entries")
    if not isinstance(entries, list) or not entries:
        fail("reference provenance must contain entries")

    ids: set[str] = set()
    urls: set[str] = set()
    for entry in entries:
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier.startswith("REF-"):
            fail(f"invalid reference id: {identifier!r}")
        if identifier in ids:
            fail(f"duplicate reference id: {identifier}")
        ids.add(identifier)

        kind = entry.get("kind")
        disposition = entry.get("disposition")
        if kind not in ALLOWED_KINDS:
            fail(f"invalid reference kind for {identifier}: {kind}")
        if disposition not in ALLOWED_DISPOSITIONS:
            fail(f"invalid reference disposition for {identifier}: {disposition}")

        url = entry.get("url")
        parsed = urlparse(url if isinstance(url, str) else "")
        if parsed.scheme != "https" or not parsed.hostname:
            fail(f"reference URL must be HTTPS for {identifier}: {url!r}")
        if url in urls:
            fail(f"duplicate reference URL: {url}")
        urls.add(url)

        authority = entry.get("authority")
        allowed_hosts = AUTHORITY_HOSTS.get(authority)
        if allowed_hosts is None or parsed.hostname not in allowed_hosts:
            fail(
                f"authority/host mismatch for {identifier}: {authority!r} / {parsed.hostname!r}"
            )

        applies_to = entry.get("appliesTo")
        if not isinstance(applies_to, list) or not applies_to:
            fail(f"reference {identifier} must declare appliesTo paths")
        for relative in applies_to:
            path = ROOT / relative
            if not path.is_file():
                fail(f"reference {identifier} points to missing path: {relative}")

        note = entry.get("evidenceNote")
        if not isinstance(note, str) or len(note.strip()) < 20:
            fail(f"reference {identifier} needs a substantive evidenceNote")

        if disposition == "adopted" and not any(
            str(relative).startswith(("Sources/", "Examples/", "scripts/"))
            or str(relative) == "Package.swift"
            for relative in applies_to
        ):
            fail(f"adopted reference {identifier} must point to implementation evidence")

    print(f"Reference provenance valid: {len(entries)} entries reviewed {reviewed_on}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
