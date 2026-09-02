#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = ROOT / "Benchmarks/ComparativeLab/Fixtures"
MANIFEST_PATH = FIXTURE_DIR / "animated-player-fixtures.json"
UNIFORM_ID = "GIF-UNIFORM-50MS-60"
UNIFORM_FILE = "gif-uniform-50ms-60-indexed.gif.fixture"
UNIFORM_DURATION_MS = 50
APNG_VARIABLE_ID = "APNG-VARIABLE-DELAY-60"
APNG_VARIABLE_FILE = "apng-variable-delay-60-indexed.png.fixture"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest() -> dict[str, object]:
    value = json.loads(MANIFEST_PATH.read_text())
    if value.get("schemaVersion") != 1:
        raise RuntimeError("animated fixture manifest schema mismatch")
    fixtures = value.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise RuntimeError("animated fixture manifest has no fixtures")
    return value


def reference_identity(manifest: dict[str, object]) -> list[list[int]]:
    fixtures = manifest["fixtures"]
    assert isinstance(fixtures, list)
    variable = next(
        (item for item in fixtures if isinstance(item, dict) and item.get("id") == "GIF-VARIABLE-DELAY-60"),
        None,
    )
    if variable is None:
        raise RuntimeError("variable-delay reference fixture is missing")
    identity = variable.get("frameIdentityRGB")
    if not isinstance(identity, list) or len(identity) != 60:
        raise RuntimeError("variable-delay reference frame identity is invalid")
    return [[int(channel) for channel in rgb] for rgb in identity]



def variable_fixture(manifest: dict[str, object]) -> dict[str, object]:
    fixtures = manifest["fixtures"]
    assert isinstance(fixtures, list)
    variable = next(
        (item for item in fixtures if isinstance(item, dict) and item.get("id") == "GIF-VARIABLE-DELAY-60"),
        None,
    )
    if variable is None:
        raise RuntimeError("variable-delay reference fixture is missing")
    return variable


def write_apng_variable_fixture(variable: dict[str, object]) -> dict[str, object]:
    identity = variable.get("frameIdentityRGB")
    durations_ns = variable.get("frameDurationsNanoseconds")
    if not isinstance(identity, list) or not isinstance(durations_ns, list) or len(identity) != len(durations_ns):
        raise RuntimeError("variable-delay APNG reference is invalid")
    durations_ms = [int(value) // 1_000_000 for value in durations_ns]
    if any(value <= 0 or value * 1_000_000 != int(ns) for value, ns in zip(durations_ms, durations_ns)):
        raise RuntimeError("APNG fixture requires integral millisecond source delays")
    frames = [Image.new("RGBA", (16, 16), tuple([int(channel) for channel in rgb] + [255])) for rgb in identity]
    output = FIXTURE_DIR / APNG_VARIABLE_FILE
    frames[0].save(
        output,
        format="PNG",
        save_all=True,
        append_images=frames[1:],
        duration=durations_ms,
        loop=0,
        disposal=[0] * len(frames),
        blend=[0] * len(frames),
        default_image=False,
    )
    return validate_apng_variable_fixture(output, variable)


def validate_apng_variable_fixture(path: Path, variable: dict[str, object]) -> dict[str, object]:
    if not path.is_file():
        raise RuntimeError(f"missing fixture: {path.relative_to(ROOT)}")
    expected_identity = [[int(channel) for channel in rgb] for rgb in variable["frameIdentityRGB"]]
    expected_ns = [int(value) for value in variable["frameDurationsNanoseconds"]]
    image = Image.open(path)
    frame_count = getattr(image, "n_frames", 1)
    if frame_count != len(expected_identity):
        raise RuntimeError(f"APNG fixture frame count mismatch: {frame_count}")
    observed_identity: list[list[int]] = []
    observed_ns: list[int] = []
    for index in range(frame_count):
        image.seek(index)
        observed_ns.append(int(round(float(image.info.get("duration", 0)) * 1_000_000)))
        pixel = image.convert("RGB").getpixel((0, 0))
        observed_identity.append([int(pixel[0]), int(pixel[1]), int(pixel[2])])
    if observed_ns != expected_ns:
        raise RuntimeError(f"APNG fixture duration drift: {observed_ns[:8]}")
    if observed_identity != expected_identity:
        raise RuntimeError("APNG fixture frame identity drifted")
    return {
        "id": APNG_VARIABLE_ID,
        "format": "APNG",
        "fileName": APNG_VARIABLE_FILE,
        "sha256": sha256(path),
        "byteCount": path.stat().st_size,
        "pixelWidth": 16,
        "pixelHeight": 16,
        "frameCount": frame_count,
        "loopCount": 0,
        "frameDurationsNanoseconds": expected_ns,
        "frameIdentityRGB": expected_identity,
    }


def write_uniform_fixture(identity: list[list[int]]) -> dict[str, object]:
    frames = [Image.new("RGB", (16, 16), tuple(rgb)) for rgb in identity]
    output = FIXTURE_DIR / UNIFORM_FILE
    frames[0].save(
        output,
        format="GIF",
        save_all=True,
        append_images=frames[1:],
        duration=[UNIFORM_DURATION_MS] * len(frames),
        loop=0,
        disposal=2,
        optimize=False,
    )
    return validate_uniform_fixture(output, identity)


def validate_uniform_fixture(path: Path, identity: list[list[int]]) -> dict[str, object]:
    if not path.is_file():
        raise RuntimeError(f"missing fixture: {path.relative_to(ROOT)}")
    image = Image.open(path)
    frame_count = getattr(image, "n_frames", 1)
    if frame_count != len(identity):
        raise RuntimeError(f"uniform fixture frame count mismatch: {frame_count}")
    durations: list[int] = []
    observed_identity: list[list[int]] = []
    for index in range(frame_count):
        image.seek(index)
        duration = int(image.info.get("duration", 0))
        durations.append(duration)
        pixel = image.convert("RGB").getpixel((0, 0))
        observed_identity.append([int(pixel[0]), int(pixel[1]), int(pixel[2])])
    if durations != [UNIFORM_DURATION_MS] * frame_count:
        raise RuntimeError(f"uniform fixture durations drifted: {durations[:8]}")
    if observed_identity != identity:
        raise RuntimeError("uniform fixture frame identity drifted")
    return {
        "id": UNIFORM_ID,
        "format": "GIF",
        "fileName": UNIFORM_FILE,
        "sha256": sha256(path),
        "byteCount": path.stat().st_size,
        "pixelWidth": 16,
        "pixelHeight": 16,
        "frameCount": frame_count,
        "loopCount": 0,
        "frameDurationsNanoseconds": [UNIFORM_DURATION_MS * 1_000_000] * frame_count,
        "frameIdentityRGB": identity,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="generate and update the manifest")
    args = parser.parse_args()

    manifest = load_manifest()
    identity = reference_identity(manifest)
    variable = variable_fixture(manifest)
    if args.write:
        fixture = write_uniform_fixture(identity)
        apng_fixture = write_apng_variable_fixture(variable)
        fixtures = manifest["fixtures"]
        assert isinstance(fixtures, list)
        replace_ids = {UNIFORM_ID, APNG_VARIABLE_ID}
        fixtures = [item for item in fixtures if not (isinstance(item, dict) and item.get("id") in replace_ids)]
        fixtures.extend([fixture, apng_fixture])
        manifest["fixtures"] = fixtures
        MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    else:
        fixture = validate_uniform_fixture(FIXTURE_DIR / UNIFORM_FILE, identity)
        apng_fixture = validate_apng_variable_fixture(FIXTURE_DIR / APNG_VARIABLE_FILE, variable)
        fixtures = manifest["fixtures"]
        assert isinstance(fixtures, list)
        stored = next(
            (item for item in fixtures if isinstance(item, dict) and item.get("id") == UNIFORM_ID),
            None,
        )
        if stored != fixture:
            raise RuntimeError("uniform fixture manifest entry does not match generated evidence")
        stored_apng = next(
            (item for item in fixtures if isinstance(item, dict) and item.get("id") == APNG_VARIABLE_ID),
            None,
        )
        if stored_apng != apng_fixture:
            raise RuntimeError("APNG variable fixture manifest entry does not match generated evidence")
    print(
        f"W5 animated fixtures: uniform={fixture['sha256']} apngVariable={apng_fixture['sha256']} "
        f"frames={fixture['frameCount']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
