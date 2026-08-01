#!/usr/bin/env python3
"""对图片元数据解析/剥离器执行独立构造级回归。"""

from __future__ import annotations

import struct
import zlib

from image_metadata import (
    ImageMetadataError,
    contains_sensitive_image_metadata,
    sanitize_image_metadata,
)


def jpeg_segment(marker: int, payload: bytes) -> bytes:
    return b"\xff" + bytes([marker]) + struct.pack(">H", len(payload) + 2) + payload


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(kind)
    crc = zlib.crc32(payload, crc)
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", crc)


def webp_chunk(kind: bytes, payload: bytes) -> bytes:
    padded = payload + (b"\x00" if len(payload) & 1 else b"")
    return kind + struct.pack("<I", len(payload)) + padded


def test_jpeg() -> None:
    scan = b"\x01\x02\xff\x00\x03\xff\xd9"
    source = (
        b"\xff\xd8"
        + jpeg_segment(0xE0, b"JFIF\x00")
        + jpeg_segment(0xE1, b"Exif\x00\x00secret")
        + jpeg_segment(0xED, b"Photoshop 3.0\x00iptc")
        + jpeg_segment(0xFE, b"private comment")
        + jpeg_segment(0xDA, b"\x01\x01\x00\x00\x3f\x00")
        + scan
    )
    assert contains_sensitive_image_metadata(source)
    sanitized = sanitize_image_metadata(source)
    assert not contains_sensitive_image_metadata(sanitized)
    assert b"JFIF\x00" in sanitized
    assert scan in sanitized
    assert b"secret" not in sanitized


def test_png() -> None:
    source = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        + png_chunk(b"tEXt", b"Author\x00private")
        + png_chunk(b"eXIf", b"Exif\x00\x00secret")
        + png_chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00\x00"))
        + png_chunk(b"IEND", b"")
    )
    assert contains_sensitive_image_metadata(source)
    sanitized = sanitize_image_metadata(source)
    assert not contains_sensitive_image_metadata(sanitized)
    assert b"IHDR" in sanitized and b"IDAT" in sanitized and b"IEND" in sanitized
    assert b"private" not in sanitized


def test_webp() -> None:
    vp8x = bytes([0x0C]) + b"\x00" * 9
    body = (
        b"WEBP"
        + webp_chunk(b"VP8X", vp8x)
        + webp_chunk(b"EXIF", b"Exif\x00\x00secret")
        + webp_chunk(b"XMP ", b"<x:xmpmeta>secret</x:xmpmeta>")
        + webp_chunk(b"VP8 ", b"frame")
    )
    source = b"RIFF" + struct.pack("<I", len(body)) + body
    assert contains_sensitive_image_metadata(source)
    sanitized = sanitize_image_metadata(source)
    assert not contains_sensitive_image_metadata(sanitized)
    assert b"EXIF" not in sanitized and b"XMP " not in sanitized
    vp8x_offset = sanitized.index(b"VP8X") + 8
    assert sanitized[vp8x_offset] & 0x0C == 0
    assert b"frame" in sanitized


def test_malformed_containers_fail_closed() -> None:
    malformed = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 100) + b"tEXt"
    try:
        contains_sensitive_image_metadata(malformed)
    except ImageMetadataError:
        return
    raise AssertionError("malformed PNG was accepted")


def main() -> int:
    test_jpeg()
    test_png()
    test_webp()
    test_malformed_containers_fail_closed()
    print("Image metadata sanitizer tests passed: JPEG, PNG, WebP, malformed container")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
