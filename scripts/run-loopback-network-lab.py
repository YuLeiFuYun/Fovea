#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zr0sAAAAASUVORK5CYII="
)
ETAG = '"fovea-loopback-v1"'


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
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_image(self, *, cache_control: str, etag: str | None = None) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", cache_control)
        if etag is not None:
            self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(PNG)))
        self.end_headers()
        self.wfile.write(PNG)
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


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def validate(lab: dict[str, Any], state: OriginState, urls: list[str]) -> dict[str, bool]:
    cases = lab.get("cases", [])
    if len(cases) != len(urls):
        raise ValueError("loopback report case count mismatch")
    by_digest = {case.get("urlDigest"): case for case in cases}
    ordered = [by_digest.get(sha256_text(url)) for url in urls]
    if any(case is None for case in ordered):
        raise ValueError("loopback report URL identities mismatch")
    cache, no_store, redirect, slow = ordered
    assert cache is not None and no_store is not None and redirect is not None and slow is not None
    invariants = {
        "allClientInvariants": lab.get("allInvariantsSatisfied") is True,
        "cacheRevalidatedWith304": state.not_modified >= 1 and cache.get("repeatFetchStarted", 0) >= 1,
        "noStoreRefetched": state.counts.get("/no-store.png", 0) >= 2 and no_store.get("repeatFetchStarted", 0) >= 1,
        "redirectCollectedMultipleTransactions": redirect.get("networkTransactionCount", 0) >= 2,
        "slowConcurrentSubscribersShared": slow.get("singleFlightObserved") is True
        and slow.get("concurrentElapsedNanoseconds", 0) >= 100_000_000,
        "loopbackDidNotUseProxy": all((case or {}).get("proxyConnectionCount", 0) == 0 for case in ordered),
    }
    if not all(invariants.values()):
        raise ValueError(f"loopback invariants failed: {invariants}")
    return invariants


def main() -> int:
    state = OriginState()
    OriginHandler.state = state
    server = ThreadingHTTPServer(("127.0.0.1", 0), OriginHandler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="fovea-loopback-origin", daemon=True)
    thread.start()
    port = server.server_address[1]
    urls = [
        f"http://127.0.0.1:{port}/cache.png",
        f"http://127.0.0.1:{port}/no-store.png",
        f"http://127.0.0.1:{port}/redirect.png",
        f"http://127.0.0.1:{port}/slow.png",
    ]
    try:
        env = os.environ.copy()
        env["DEVELOPER_DIR"] = subprocess.run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        build = subprocess.run(
            ["xcrun", "swift", "build", "--product", "FoveaNetworkLab", "-Xswiftc", "-warnings-as-errors"],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if build.returncode != 0:
            print(build.stdout, file=sys.stderr)
            print(build.stderr, file=sys.stderr)
            return 1
        command = ["xcrun", "swift", "run", "--skip-build", "FoveaNetworkLab", "--live"]
        for url in urls:
            command.extend(["--url", url])
        completed = run_process(command, env, 120)
        if completed.returncode != 0:
            print(completed.stdout, file=sys.stderr)
            print(completed.stderr, file=sys.stderr)
            return 1
        lab = json.loads(completed.stdout)
        invariants = validate(lab, state, urls)
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
