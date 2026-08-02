#!/usr/bin/env python3
from __future__ import annotations

import base64
import binascii
import datetime as dt
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from swift_tooling import build_product, selected_environment
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP4/x8AAwAB/2+Bq7YAAAAASUVORK5CYII="
)
OVERSIZED_BODY = PNG * 64
HTML_BODY = b"<html><body>not an image</body></html>"
ETAG = '"fovea-loopback-v1"'


def png_chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    signature = b"\x89PNG\r\n\x1a\n"
    if not data.startswith(signature):
        raise ValueError("loopback PNG fixture has an invalid signature")
    chunks: list[tuple[bytes, bytes]] = []
    offset = len(signature)
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("loopback PNG fixture has a truncated chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise ValueError("loopback PNG fixture has an invalid chunk length")
        chunk_type = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : chunk_end])[0]
        actual_crc = binascii.crc32(chunk_type + payload) & 0xFFFF_FFFF
        if expected_crc != actual_crc:
            raise ValueError(
                f"loopback PNG fixture has an invalid {chunk_type.decode('ascii')} CRC"
            )
        chunks.append((chunk_type, payload))
        offset = chunk_end
        if chunk_type == b"IEND":
            if offset != len(data):
                raise ValueError("loopback PNG fixture has trailing bytes")
            return chunks
    raise ValueError("loopback PNG fixture has no terminal chunk")


def validate_png_fixture(data: bytes) -> None:
    image_payload = b"".join(
        payload for chunk_type, payload in png_chunks(data) if chunk_type == b"IDAT"
    )
    try:
        zlib.decompress(image_payload)
    except zlib.error as error:
        raise ValueError("loopback PNG fixture has an invalid compressed payload") from error


class OriginState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.counts: dict[str, int] = {}
        self.not_modified = 0

    def record(self, path: str) -> None:
        with self.lock:
            self.counts[path] = self.counts.get(path, 0) + 1

    def record_not_modified(self) -> None:
        with self.lock:
            self.not_modified += 1


class OriginHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state: OriginState

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract.
        path = self.path.split("?", 1)[0]
        self.state.record(path)
        if path == "/cache.png":
            if self.headers.get("If-None-Match") == ETAG:
                self.state.record_not_modified()
                self.send_response(304)
                self.send_header("Cache-Control", "max-age=0")
                self.send_header("ETag", ETAG)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_image(cache_control="max-age=0", etag=ETAG)
            return
        if path == "/no-store.png":
            self.send_image(cache_control="no-store")
            return
        if path == "/redirect.png":
            self.send_response(302)
            self.send_header("Location", "/cache.png")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/slow.png":
            time.sleep(0.15)
            self.send_image(cache_control="max-age=60")
            return
        if path == "/missing-type.png":
            self.send_image(cache_control="max-age=60", content_type=None)
            return
        if path == "/html":
            self.send_payload(HTML_BODY, content_type="text/html", cache_control="no-store")
            return
        if path == "/too-large.png":
            self.send_payload(OVERSIZED_BODY, content_type="image/png", cache_control="no-store")
            return
        if path == "/status-401":
            self.send_response(401)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/redirect-remote.png":
            self.send_response(302)
            self.send_header("Location", "http://example.invalid/image.png")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_image(
        self,
        *,
        cache_control: str,
        etag: str | None = None,
        content_type: str | None = "image/png",
    ) -> None:
        self.send_payload(
            PNG,
            content_type=content_type,
            cache_control=cache_control,
            etag=etag,
        )

    def send_payload(
        self,
        body: bytes,
        *,
        content_type: str | None,
        cache_control: str,
        etag: str | None = None,
    ) -> None:
        self.send_response(200)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", cache_control)
        if etag is not None:
            self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def log_message(self, format: str, *args: object) -> None:
        return


def run_process(command: list[str], env: dict[str, str], timeout: int) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
        raise RuntimeError(f"loopback network lab timed out: {stderr[-1000:]}")



def validate(
    lab: dict[str, Any],
    state: OriginState,
    success_urls: list[str],
    expected_failures: dict[str, str],
) -> dict[str, bool]:
    cases = lab.get("cases", [])
    expected_count = len(success_urls) + len(expected_failures)
    if len(cases) != expected_count:
        raise ValueError("loopback report case count mismatch")
    by_id = {case.get("caseID"): case for case in cases}
    successful = [
        by_id.get(f"custom-{index:03d}")
        for index in range(1, len(success_urls) + 1)
    ]
    failures = {
        url: by_id.get(f"custom-{index:03d}")
        for index, url in enumerate(
            expected_failures,
            start=len(success_urls) + 1,
        )
    }
    if any(case is None for case in successful) or any(case is None for case in failures.values()):
        raise ValueError("loopback report case identities mismatch")
    cache, no_store, redirect, slow, missing_type = successful
    assert cache is not None and no_store is not None and redirect is not None
    assert slow is not None and missing_type is not None
    expected_failures_observed = all(
        case is not None
        and case.get("expectationSatisfied") is True
        and case.get("failureReason") == expected_failures[url]
        for url, case in failures.items()
    )
    serialized_lab = json.dumps(lab, sort_keys=True)
    custom_destinations_redacted = (
        "127.0.0.1" not in serialized_lab
        and all(url not in serialized_lab for url in success_urls)
        and all(url not in serialized_lab for url in expected_failures)
    )
    invariants = {
        "allClientInvariants": lab.get("allInvariantsSatisfied") is True,
        "allExpectationsSatisfied": lab.get("allExpectationsSatisfied") is True,
        "cacheRevalidatedWith304": state.not_modified >= 1 and cache.get("repeatFetchStarted", 0) >= 1,
        "noStoreRefetched": state.counts.get("/no-store.png", 0) >= 2 and no_store.get("repeatFetchStarted", 0) >= 1,
        "redirectCollectedMultipleTransactions": redirect.get("networkTransactionCount", 0) >= 2,
        "slowConcurrentSubscribersShared": slow.get("singleFlightObserved") is True
        and slow.get("concurrentElapsedNanoseconds", 0) >= 100_000_000,
        "missingContentTypeWasObservable": missing_type.get("responseAnomalyObserved") is True,
        "expectedFailuresObserved": expected_failures_observed,
        "loopbackDidNotUseProxy": all(
            (case or {}).get("proxyConnectionCount", 0) == 0 for case in successful
        ),
        "customDestinationsWereRedacted": custom_destinations_redacted,
    }
    if not all(invariants.values()):
        raise ValueError(f"loopback invariants failed: {invariants}")
    return invariants


def main() -> int:
    validate_png_fixture(PNG)
    state = OriginState()
    OriginHandler.state = state
    server = ThreadingHTTPServer(("127.0.0.1", 0), OriginHandler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="fovea-loopback-origin", daemon=True)
    thread.start()
    port = server.server_address[1]
    success_urls = [
        f"http://127.0.0.1:{port}/cache.png",
        f"http://127.0.0.1:{port}/no-store.png",
        f"http://127.0.0.1:{port}/redirect.png",
        f"http://127.0.0.1:{port}/slow.png",
        f"http://127.0.0.1:{port}/missing-type.png",
    ]
    expected_failures = {
        f"http://127.0.0.1:{port}/html": "non-image-response",
        f"http://127.0.0.1:{port}/too-large.png": "encoded-body-limit-exceeded",
        f"http://127.0.0.1:{port}/status-401": "unsupported-http-status",
        f"http://127.0.0.1:{port}/redirect-remote.png": "insecure-redirect",
    }
    try:
        env = selected_environment(ROOT)
        try:
            executable = build_product(ROOT, env, "FoveaNetworkLab")
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            print(str(error), file=sys.stderr)
            return 1
        command = [
            str(executable),
            "--live",
            "--maximum-transport-bytes",
            "1024",
        ]
        for url in success_urls:
            command.extend(["--url", url])
        for url, reason in expected_failures.items():
            command.extend(["--expect-failure", reason, url])
        completed = run_process(command, env, 120)
        if completed.returncode != 0:
            print(completed.stdout, file=sys.stderr)
            print(completed.stderr, file=sys.stderr)
            return 1
        lab = json.loads(completed.stdout)
        invariants = validate(lab, state, success_urls, expected_failures)
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        artifact = {
            "schemaVersion": 1,
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "verifiedCommit": commit,
            "status": "passed",
            "originRequestCounts": state.counts,
            "notModifiedCount": state.not_modified,
            "invariants": invariants,
            "lab": lab,
            "stderrLineCount": len(completed.stderr.splitlines()),
        }
        output = ROOT / ".artifacts/loopback-network/network-lab.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
        print(f"Loopback network laboratory passed: {output.relative_to(ROOT)}")
        return 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"Loopback network laboratory failed: {error}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
