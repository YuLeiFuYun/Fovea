"""Bounded PNG decoding and low-information image analysis."""
from __future__ import annotations

import math
import struct
import tempfile
import zlib
from pathlib import Path
from typing import Callable, Sequence

from workbench_visual_types import PNGDecodeError, PixelAudit

Pixel = tuple[int, int, int]
CommandRunner = Callable[..., str]


def paeth(a: int, b: int, c: int) -> int:
    value = a + b - c
    distances = (abs(value - a), abs(value - b), abs(value - c))
    if distances[0] <= distances[1] and distances[0] <= distances[2]:
        return a
    return b if distances[1] <= distances[2] else c


def parse_png_chunks(payload: bytes) -> tuple[tuple[int, int, int, int, int], bytes]:
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise PNGDecodeError("not a PNG")
    offset = 8
    header: tuple[int, int, int, int, int] | None = None
    compressed = bytearray()
    while offset + 12 <= len(payload):
        length = struct.unpack(">I", payload[offset : offset + 4])[0]
        kind = payload[offset + 4 : offset + 8]
        data = payload[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", data)
            header = (width, height, depth, color, interlace)
        elif kind == b"IDAT":
            compressed.extend(data)
        elif kind == b"IEND":
            break
    if header is None:
        raise PNGDecodeError("missing IHDR")
    return header, bytes(compressed)


def validated_layout(header: tuple[int, int, int, int, int]) -> tuple[int, int, int, int]:
    width, height, depth, color_type, interlace = header
    if depth != 8 or interlace != 0 or color_type not in {0, 2, 4, 6}:
        raise PNGDecodeError(
            f"unsupported PNG layout: depth={depth}, color={color_type}, interlace={interlace}"
        )
    return width, height, color_type, {0: 1, 2: 3, 4: 2, 6: 4}[color_type]


def decoded_filter_byte(
    filter_type: int,
    value: int,
    left: int,
    up: int,
    upper_left: int,
) -> int:
    if filter_type == 0:
        return value
    if filter_type == 1:
        return (value + left) & 0xFF
    if filter_type == 2:
        return (value + up) & 0xFF
    if filter_type == 3:
        return (value + ((left + up) // 2)) & 0xFF
    if filter_type == 4:
        return (value + paeth(left, up, upper_left)) & 0xFF
    raise PNGDecodeError(f"unsupported filter {filter_type}")


def decode_row(encoded: bytes, previous: bytearray, channels: int, filter_type: int) -> bytearray:
    row = bytearray(len(encoded))
    for index, value in enumerate(encoded):
        left = row[index - channels] if index >= channels else 0
        up = previous[index]
        upper_left = previous[index - channels] if index >= channels else 0
        row[index] = decoded_filter_byte(filter_type, value, left, up, upper_left)
    return row


def decode_rows(raw: bytes, height: int, stride: int, channels: int) -> list[bytearray]:
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise PNGDecodeError(f"unexpected scanline length: {len(raw)} != {expected}")
    rows: list[bytearray] = []
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        encoded = raw[cursor + 1 : cursor + stride + 1]
        previous = rows[-1] if rows else bytearray(stride)
        rows.append(decode_row(encoded, previous, channels, filter_type))
        cursor += stride + 1
    return rows


def pixels_from_rows(rows: Sequence[bytearray], channels: int, color_type: int) -> list[Pixel]:
    pixels: list[Pixel] = []
    grayscale = color_type in {0, 4}
    for row in rows:
        for index in range(0, len(row), channels):
            if grayscale:
                gray = row[index]
                pixels.append((gray, gray, gray))
            else:
                pixels.append((row[index], row[index + 1], row[index + 2]))
    return pixels


def decode_png(path: Path) -> tuple[int, int, list[Pixel]]:
    header, compressed = parse_png_chunks(path.read_bytes())
    width, height, color_type, channels = validated_layout(header)
    rows = decode_rows(zlib.decompress(compressed), height, width * channels, channels)
    return width, height, pixels_from_rows(rows, channels, color_type)


def convert_to_png(path: Path, temporary: Path, run: CommandRunner) -> Path:
    if path.suffix.lower() == ".png":
        return path
    destination = temporary / f"{path.stem}.png"
    run(["/usr/bin/sips", "-s", "format", "png", str(path), "--out", str(destination)], timeout=60)
    return destination


def sampled_pixels(pixels: Sequence[Pixel]) -> list[Pixel]:
    step = max(1, int(math.sqrt(max(1, len(pixels) // 16_384))))
    return list(pixels[::step])


def channel_standard_deviation(pixels: Sequence[Pixel]) -> tuple[float, float, float]:
    means = [sum(pixel[channel] for pixel in pixels) / len(pixels) for channel in range(3)]
    values = []
    for channel in range(3):
        variance = sum((pixel[channel] - means[channel]) ** 2 for pixel in pixels) / len(pixels)
        values.append(math.sqrt(variance))
    return tuple(values)  # type: ignore[return-value]


def tile_pixels(
    pixels: Sequence[Pixel], width: int, x0: int, x1: int, y0: int, y1: int
) -> list[Pixel]:
    y_step = max(1, (y1 - y0) // 8)
    x_step = max(1, (x1 - x0) // 8)
    return [pixels[y * width + x] for y in range(y0, y1, y_step) for x in range(x0, x1, x_step)]


def tile_is_uniform(tile: Sequence[Pixel]) -> bool:
    ranges = [max(pixel[c] for pixel in tile) - min(pixel[c] for pixel in tile) for c in range(3)]
    return max(ranges) <= 5


def uniform_tile_ratio(pixels: Sequence[Pixel], width: int, height: int) -> float:
    tiles_x, tiles_y = min(12, width), min(12, height)
    total = uniform = 0
    for tile_y in range(tiles_y):
        y0, y1 = tile_y * height // tiles_y, max(1, (tile_y + 1) * height // tiles_y)
        for tile_x in range(tiles_x):
            x0, x1 = tile_x * width // tiles_x, max(1, (tile_x + 1) * width // tiles_x)
            total += 1
            uniform += int(tile_is_uniform(tile_pixels(pixels, width, x0, x1, y0, y1)))
    return uniform / total if total else 1.0


def pixel_audit(path: Path, run: CommandRunner) -> PixelAudit:
    with tempfile.TemporaryDirectory(prefix="fovea-visual-image-") as directory:
        width, height, pixels = decode_png(convert_to_png(path, Path(directory), run))
    sampled = sampled_pixels(pixels)
    unique = len(set(sampled))
    stddev = channel_standard_deviation(sampled)
    uniform_ratio = uniform_tile_ratio(pixels, width, height)
    likely_block = unique <= 24 or max(stddev) <= 5.0 or (uniform_ratio >= 0.92 and unique <= 256)
    return PixelAudit(
        width, height, len(sampled), unique,
        tuple(round(value, 3) for value in stddev),
        round(uniform_ratio, 4), likely_block,
    )
