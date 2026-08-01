#!/usr/bin/env python3
"""跨平台检测并移除常见图片中的可识别元数据容器。"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

JPEG_METADATA_MARKERS = {0xE1, 0xED, 0xFE}  # APP1 EXIF/XMP, APP13 IPTC, COM
PNG_METADATA_CHUNKS = {b"eXIf", b"tEXt", b"zTXt", b"iTXt"}
WEBP_METADATA_CHUNKS = {b"EXIF", b"XMP "}


class ImageMetadataError(ValueError):
    pass


def contains_sensitive_image_metadata(data: bytes) -> bool:
    if data.startswith(b"\xff\xd8\xff"):
        return _jpeg_contains_metadata(data)
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return _png_contains_metadata(data)
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return _webp_contains_metadata(data)
    return False


def sanitize_image_metadata(data: bytes) -> bytes:
    if data.startswith(b"\xff\xd8\xff"):
        return _sanitize_jpeg(data)
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return _sanitize_png(data)
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return _sanitize_webp(data)
    return data


def sanitize_file(path: Path) -> bool:
    original = path.read_bytes()
    sanitized = sanitize_image_metadata(original)
    if sanitized == original:
        return False
    path.write_bytes(sanitized)
    return True


def _jpeg_segments(data: bytes):
    if not data.startswith(b"\xff\xd8"):
        raise ImageMetadataError("invalid JPEG SOI")
    position = 2
    while position < len(data):
        marker_start = position
        if data[position] != 0xFF:
            raise ImageMetadataError("invalid JPEG marker prefix")
        while position < len(data) and data[position] == 0xFF:
            position += 1
        if position >= len(data):
            raise ImageMetadataError("truncated JPEG marker")
        marker = data[position]
        position += 1
        if marker == 0xD9:
            yield marker, marker_start, position
            return
        if marker == 0xDA:
            if position + 2 > len(data):
                raise ImageMetadataError("truncated JPEG SOS")
            length = int.from_bytes(data[position : position + 2], "big")
            if length < 2 or position + length > len(data):
                raise ImageMetadataError("invalid JPEG SOS length")
            yield marker, marker_start, len(data)
            return
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            yield marker, marker_start, position
            continue
        if position + 2 > len(data):
            raise ImageMetadataError("truncated JPEG segment")
        length = int.from_bytes(data[position : position + 2], "big")
        end = position + length
        if length < 2 or end > len(data):
            raise ImageMetadataError("invalid JPEG segment length")
        yield marker, marker_start, end
        position = end
    raise ImageMetadataError("JPEG has no terminal marker")


def _jpeg_contains_metadata(data: bytes) -> bool:
    return any(marker in JPEG_METADATA_MARKERS for marker, _, _ in _jpeg_segments(data))


def _sanitize_jpeg(data: bytes) -> bytes:
    output = bytearray(data[:2])
    for marker, start, end in _jpeg_segments(data):
        if marker not in JPEG_METADATA_MARKERS:
            output.extend(data[start:end])
        if marker in {0xDA, 0xD9}:
            break
    return bytes(output)


def _png_chunks(data: bytes):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ImageMetadataError("invalid PNG signature")
    position = 8
    while position < len(data):
        if position + 12 > len(data):
            raise ImageMetadataError("truncated PNG chunk")
        length = int.from_bytes(data[position : position + 4], "big")
        chunk_type = data[position + 4 : position + 8]
        end = position + 12 + length
        if end > len(data):
            raise ImageMetadataError("invalid PNG chunk length")
        payload = data[position + 8 : position + 8 + length]
        yield chunk_type, payload, position, end
        position = end
        if chunk_type == b"IEND":
            if position != len(data):
                raise ImageMetadataError("trailing bytes after PNG IEND")
            return
    raise ImageMetadataError("PNG has no IEND")


def _png_contains_metadata(data: bytes) -> bool:
    return any(chunk_type in PNG_METADATA_CHUNKS for chunk_type, _, _, _ in _png_chunks(data))


def _sanitize_png(data: bytes) -> bytes:
    output = bytearray(data[:8])
    for chunk_type, payload, start, end in _png_chunks(data):
        if chunk_type in PNG_METADATA_CHUNKS:
            continue
        # Preserve the original chunk verbatim; CRC remains valid.
        output.extend(data[start:end])
    return bytes(output)


def _webp_chunks(data: bytes):
    if len(data) < 12 or not data.startswith(b"RIFF") or data[8:12] != b"WEBP":
        raise ImageMetadataError("invalid WebP header")
    declared = int.from_bytes(data[4:8], "little") + 8
    if declared != len(data):
        raise ImageMetadataError("invalid WebP RIFF length")
    position = 12
    while position < len(data):
        if position + 8 > len(data):
            raise ImageMetadataError("truncated WebP chunk")
        chunk_type = data[position : position + 4]
        length = int.from_bytes(data[position + 4 : position + 8], "little")
        padded = length + (length & 1)
        end = position + 8 + padded
        if end > len(data):
            raise ImageMetadataError("invalid WebP chunk length")
        payload = data[position + 8 : position + 8 + length]
        yield chunk_type, payload
        position = end


def _webp_contains_metadata(data: bytes) -> bool:
    return any(chunk_type in WEBP_METADATA_CHUNKS for chunk_type, _ in _webp_chunks(data))


def _sanitize_webp(data: bytes) -> bytes:
    chunks: list[tuple[bytes, bytes]] = []
    for chunk_type, payload in _webp_chunks(data):
        if chunk_type in WEBP_METADATA_CHUNKS:
            continue
        if chunk_type == b"VP8X" and len(payload) >= 1:
            mutable = bytearray(payload)
            mutable[0] &= ~0x0C  # Clear EXIF and XMP feature bits.
            payload = bytes(mutable)
        chunks.append((chunk_type, payload))

    body = bytearray(b"WEBP")
    for chunk_type, payload in chunks:
        body.extend(chunk_type)
        body.extend(struct.pack("<I", len(payload)))
        body.extend(payload)
        if len(payload) & 1:
            body.append(0)
    return b"RIFF" + struct.pack("<I", len(body)) + bytes(body)
