#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import plistlib
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
RUNNER_PATH = ROOT / "scripts/run-w5-animated-simulator-lab.py"
SPEC = importlib.util.spec_from_file_location("fovea_w5_simulator_runner", RUNNER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("failed to load W5 simulator runner")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def write_app(root: Path, *, bundle_id: str = "dev.fovea.test") -> Path:
    app = root / "Digest.app"
    app.mkdir()
    (app / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Digest"})
    )
    (app / "Digest").write_bytes(b"executable-v1")
    (app / "Resource.txt").write_text("resource-v1")
    nested = app / "Nested"
    nested.mkdir()
    (nested / "Fixture.bin").write_bytes(b"fixture")
    return app


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="fovea-w5-app-digest-") as temporary:
        app = write_app(Path(temporary))
        first = runner.app_bundle_identity(
            app, scheme="Digest", expected_bundle_id="dev.fovea.test"
        )
        second = runner.app_bundle_identity(
            app, scheme="Digest", expected_bundle_id="dev.fovea.test"
        )
        assert first == second
        assert first["bundleFileCount"] == 4, first
        assert first["bundleSymlinkCount"] == 0, first
        assert first["executableSHA256"] == hashlib.sha256(b"executable-v1").hexdigest()
        (app / "Resource.txt").write_text("resource-v2")
        changed = runner.app_bundle_identity(
            app, scheme="Digest", expected_bundle_id="dev.fovea.test"
        )
        assert changed["bundleTreeDigest"] != first["bundleTreeDigest"]
        assert changed["executableSHA256"] == first["executableSHA256"]
        first_container = Path(temporary) / "container-a"
        second_container = Path(temporary) / "container-b"
        first_result, first_failure = runner.benchmark_result_paths(
            first_container, "result.json"
        )
        second_result, second_failure = runner.benchmark_result_paths(
            second_container, "result.json"
        )
        assert first_result != second_result
        assert first_result == first_container / "Documents/result.json"
        assert first_failure == first_container / "Documents/result.json.failure"
        assert second_result == second_container / "Documents/result.json"
        assert second_failure == second_container / "Documents/result.json.failure"
        assert runner.COMPARATOR_ISOLATION_MODE == "shutdown-boot-between-comparators-v1"
        assert runner.EXPECTED_FRESH_SIMULATOR_INSTABILITIES == {
            ("FLAnimatedImage", "GIF-VARIABLE-DELAY-60"): (
                "w5-player-timing-timeout:count=0:progression=0",
                "w5-player-timing-timeout:count=1:progression=0",
            )
        }
        try:
            runner.app_bundle_identity(
                app, scheme="Digest", expected_bundle_id="dev.fovea.wrong"
            )
        except RuntimeError as error:
            assert "bundle identifier mismatch" in str(error)
        else:
            raise AssertionError("bundle identifier mismatch must fail closed")
    print("W5 simulator app-bundle identity contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
