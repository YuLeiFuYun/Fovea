#!/usr/bin/env python3
"""Owned APNG parsing and composition reference for Fovea W5 research.

This module is deliberately isolated from production code. It decodes non-interlaced
PNG/APNG image data into raw subrect RGBA and composes frames with explicit source/over
blend and none/background/previous disposal semantics.
"""

from __future__ import annotations

import dataclasses
import struct
import zlib
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class APNGReferenceError(ValueError):
    pass


@dataclasses.dataclass(frozen=True)
class FrameControl:
    sequence_number: int
    width: int
    height: int
    x_offset: int
    y_offset: int
    delay_num: int
    delay_den: int
    dispose_op: int
    blend_op: int

    @property
    def duration_nanoseconds(self) -> int:
        denominator = self.delay_den or 100
        return (self.delay_num * 1_000_000_000 + denominator - 1) // denominator


@dataclasses.dataclass(frozen=True)
class RawFrame:
    control: FrameControl
    rgba: bytes

    @property
    def byte_count(self) -> int:
        return len(self.rgba)


@dataclasses.dataclass(frozen=True)
class APNGImage:
    canvas_width: int
    canvas_height: int
    num_plays: int
    bit_depth: int
    color_type: int
    frames: tuple[RawFrame, ...]


@dataclasses.dataclass(frozen=True)
class ComposedFrame:
    control: FrameControl
    premultiplied_rgba: bytes


@dataclasses.dataclass
class _PendingFrame:
    control: FrameControl
    uses_idat: bool
    compressed_parts: list[bytes]


@dataclasses.dataclass(frozen=True)
class _PNGMetadata:
    canvas_width: int
    canvas_height: int
    bit_depth: int
    color_type: int
    compression: int
    filter_method: int
    interlace: int
    palette: bytes | None
    transparency: bytes | None


def _chunks(data: bytes):
    if not data.startswith(PNG_SIGNATURE):
        raise APNGReferenceError("invalid PNG signature")
    offset = len(PNG_SIGNATURE)
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        crc_end = payload_end + 4
        if crc_end > len(data):
            raise APNGReferenceError("truncated PNG chunk")
        payload = data[payload_start:payload_end]
        expected_crc = struct.unpack(">I", data[payload_end:crc_end])[0]
        actual_crc = zlib.crc32(kind)
        actual_crc = zlib.crc32(payload, actual_crc) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            raise APNGReferenceError(f"CRC mismatch for {kind!r}")
        yield kind, payload
        offset = crc_end
        if kind == b"IEND":
            if offset != len(data):
                raise APNGReferenceError("trailing bytes after IEND")
            return
    raise APNGReferenceError("missing IEND")


def _parse_frame_control(payload: bytes) -> FrameControl:
    if len(payload) != 26:
        raise APNGReferenceError("invalid fcTL length")
    values = struct.unpack(">IIIIIHHBB", payload)
    control = FrameControl(*values)
    if control.width <= 0 or control.height <= 0:
        raise APNGReferenceError("invalid frame dimensions")
    if control.dispose_op not in (0, 1, 2):
        raise APNGReferenceError("invalid disposal operation")
    if control.blend_op not in (0, 1):
        raise APNGReferenceError("invalid blend operation")
    return control


def _channels(color_type: int) -> int:
    mapping = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    try:
        return mapping[color_type]
    except KeyError as error:
        raise APNGReferenceError(f"unsupported PNG color type: {color_type}") from error


def _validate_bit_depth(color_type: int, bit_depth: int) -> None:
    allowed = {
        0: {1, 2, 4, 8},
        2: {8},
        3: {1, 2, 4, 8},
        4: {8},
        6: {8},
    }
    if bit_depth not in allowed.get(color_type, set()):
        raise APNGReferenceError(
            f"unsupported bit depth {bit_depth} for color type {color_type}"
        )


def _paeth(left: int, above: int, upper_left: int) -> int:
    prediction = left + above - upper_left
    left_distance = abs(prediction - left)
    above_distance = abs(prediction - above)
    upper_left_distance = abs(prediction - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def _unfilter(
    compressed: bytes,
    width: int,
    height: int,
    bit_depth: int,
    color_type: int,
) -> list[bytes]:
    try:
        payload = zlib.decompress(compressed)
    except zlib.error as error:
        raise APNGReferenceError(f"zlib decode failed: {error}") from error
    channels = _channels(color_type)
    bits_per_pixel = channels * bit_depth
    row_bytes = (width * bits_per_pixel + 7) // 8
    filter_bpp = max(1, (bits_per_pixel + 7) // 8)
    expected = height * (row_bytes + 1)
    if len(payload) != expected:
        raise APNGReferenceError(
            f"inflated byte count mismatch: expected {expected}, got {len(payload)}"
        )
    rows: list[bytes] = []
    offset = 0
    previous = bytearray(row_bytes)
    for _ in range(height):
        filter_type = payload[offset]
        offset += 1
        encoded = payload[offset : offset + row_bytes]
        offset += row_bytes
        decoded = bytearray(row_bytes)
        for index, value in enumerate(encoded):
            left = decoded[index - filter_bpp] if index >= filter_bpp else 0
            above = previous[index]
            upper_left = previous[index - filter_bpp] if index >= filter_bpp else 0
            if filter_type == 0:
                prediction = 0
            elif filter_type == 1:
                prediction = left
            elif filter_type == 2:
                prediction = above
            elif filter_type == 3:
                prediction = (left + above) // 2
            elif filter_type == 4:
                prediction = _paeth(left, above, upper_left)
            else:
                raise APNGReferenceError(f"unsupported PNG filter: {filter_type}")
            decoded[index] = (value + prediction) & 0xFF
        rows.append(bytes(decoded))
        previous = decoded
    return rows


def _unpack_samples(row: bytes, bit_depth: int, sample_count: int) -> list[int]:
    if bit_depth == 8:
        if len(row) < sample_count:
            raise APNGReferenceError("scanline sample underflow")
        return list(row[:sample_count])
    mask = (1 << bit_depth) - 1
    samples: list[int] = []
    for byte in row:
        shift = 8 - bit_depth
        while shift >= 0 and len(samples) < sample_count:
            samples.append((byte >> shift) & mask)
            shift -= bit_depth
    if len(samples) != sample_count:
        raise APNGReferenceError("packed scanline sample underflow")
    return samples


def _scale_sample(value: int, bit_depth: int) -> int:
    if bit_depth == 8:
        return value
    maximum = (1 << bit_depth) - 1
    return (value * 255 + maximum // 2) // maximum


def _rows_to_rgba(
    rows: list[bytes],
    width: int,
    bit_depth: int,
    color_type: int,
    palette: bytes | None,
    transparency: bytes | None,
) -> bytes:
    channels = _channels(color_type)
    output = bytearray()
    grayscale_transparent: int | None = None
    rgb_transparent: tuple[int, int, int] | None = None
    if transparency is not None and color_type == 0:
        if len(transparency) != 2:
            raise APNGReferenceError("invalid grayscale tRNS")
        grayscale_transparent = struct.unpack(">H", transparency)[0]
    elif transparency is not None and color_type == 2:
        if len(transparency) != 6:
            raise APNGReferenceError("invalid RGB tRNS")
        rgb_transparent = struct.unpack(">HHH", transparency)

    if color_type == 3:
        if palette is None or len(palette) % 3 != 0:
            raise APNGReferenceError("indexed PNG is missing PLTE")
        palette_entries = [
            (palette[index], palette[index + 1], palette[index + 2])
            for index in range(0, len(palette), 3)
        ]
        alpha_entries = list(transparency or b"")
    else:
        palette_entries = []
        alpha_entries = []

    for row in rows:
        samples = _unpack_samples(row, bit_depth, width * channels)
        for pixel in range(width):
            base = pixel * channels
            if color_type == 0:
                raw_gray = samples[base]
                gray = _scale_sample(raw_gray, bit_depth)
                alpha = 0 if grayscale_transparent == raw_gray else 255
                output.extend((gray, gray, gray, alpha))
            elif color_type == 2:
                red, green, blue = samples[base : base + 3]
                alpha = 0 if rgb_transparent == (red, green, blue) else 255
                output.extend((red, green, blue, alpha))
            elif color_type == 3:
                palette_index = samples[base]
                if palette_index >= len(palette_entries):
                    raise APNGReferenceError("palette index out of range")
                red, green, blue = palette_entries[palette_index]
                alpha = alpha_entries[palette_index] if palette_index < len(alpha_entries) else 255
                output.extend((red, green, blue, alpha))
            elif color_type == 4:
                gray, alpha = samples[base : base + 2]
                output.extend((gray, gray, gray, alpha))
            elif color_type == 6:
                output.extend(samples[base : base + 4])
            else:
                raise APNGReferenceError(f"unsupported color type: {color_type}")
    return bytes(output)


def parse_apng(data: bytes) -> APNGImage:
    metadata: _PNGMetadata | None = None
    num_frames: int | None = None
    num_plays = 0
    palette: bytes | None = None
    transparency: bytes | None = None
    pending: _PendingFrame | None = None
    pending_frames: list[_PendingFrame] = []
    seen_idat = False
    last_sequence = -1

    def finalize_pending() -> None:
        nonlocal pending
        if pending is None:
            return
        if not pending.compressed_parts:
            raise APNGReferenceError("animation frame has no image data")
        pending_frames.append(pending)
        pending = None

    for kind, payload in _chunks(data):
        if kind == b"IHDR":
            if metadata is not None or len(payload) != 13:
                raise APNGReferenceError("invalid IHDR")
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if width <= 0 or height <= 0:
                raise APNGReferenceError("invalid canvas dimensions")
            if compression != 0 or filter_method != 0 or interlace != 0:
                raise APNGReferenceError("only non-interlaced standard PNG is supported")
            _validate_bit_depth(color_type, bit_depth)
            metadata = _PNGMetadata(
                width,
                height,
                bit_depth,
                color_type,
                compression,
                filter_method,
                interlace,
                None,
                None,
            )
        elif kind == b"PLTE":
            palette = payload
        elif kind == b"tRNS":
            transparency = payload
        elif kind == b"acTL":
            if len(payload) != 8:
                raise APNGReferenceError("invalid acTL")
            num_frames, num_plays = struct.unpack(">II", payload)
            if num_frames <= 0:
                raise APNGReferenceError("invalid APNG frame count")
        elif kind == b"fcTL":
            control = _parse_frame_control(payload)
            if control.sequence_number <= last_sequence:
                raise APNGReferenceError("non-monotonic APNG sequence number")
            last_sequence = control.sequence_number
            finalize_pending()
            pending = _PendingFrame(
                control=control,
                uses_idat=not seen_idat,
                compressed_parts=[],
            )
        elif kind == b"IDAT":
            seen_idat = True
            if pending is not None and pending.uses_idat:
                pending.compressed_parts.append(payload)
        elif kind == b"fdAT":
            if len(payload) < 4 or pending is None:
                raise APNGReferenceError("orphan fdAT")
            sequence = struct.unpack(">I", payload[:4])[0]
            if sequence <= last_sequence:
                raise APNGReferenceError("non-monotonic APNG sequence number")
            last_sequence = sequence
            pending.compressed_parts.append(payload[4:])
        elif kind == b"IEND":
            finalize_pending()

    if metadata is None or num_frames is None:
        raise APNGReferenceError("not an APNG")
    if len(pending_frames) != num_frames:
        raise APNGReferenceError(
            f"APNG frame count mismatch: expected {num_frames}, got {len(pending_frames)}"
        )
    raw_frames: list[RawFrame] = []
    for frame in pending_frames:
        control = frame.control
        if (
            control.x_offset + control.width > metadata.canvas_width
            or control.y_offset + control.height > metadata.canvas_height
        ):
            raise APNGReferenceError("frame rect escapes canvas")
        rows = _unfilter(
            b"".join(frame.compressed_parts),
            control.width,
            control.height,
            metadata.bit_depth,
            metadata.color_type,
        )
        rgba = _rows_to_rgba(
            rows,
            control.width,
            metadata.bit_depth,
            metadata.color_type,
            palette,
            transparency,
        )
        expected_bytes = control.width * control.height * 4
        if len(rgba) != expected_bytes:
            raise APNGReferenceError("decoded subrect byte count mismatch")
        raw_frames.append(RawFrame(control=control, rgba=rgba))
    return APNGImage(
        canvas_width=metadata.canvas_width,
        canvas_height=metadata.canvas_height,
        num_plays=num_plays,
        bit_depth=metadata.bit_depth,
        color_type=metadata.color_type,
        frames=tuple(raw_frames),
    )


def parse_apng_file(path: Path) -> APNGImage:
    return parse_apng(path.read_bytes())


def _divide_by_255(value: int, rounding: str) -> int:
    if rounding == "floor":
        return value // 255
    if rounding == "nearest":
        return (value + 127) // 255
    if rounding == "ceil":
        return (value + 254) // 255
    raise APNGReferenceError(f"unsupported rounding mode: {rounding}")


def _premultiply(
    red: int,
    green: int,
    blue: int,
    alpha: int,
    rounding: str,
) -> tuple[int, int, int, int]:
    return (
        _divide_by_255(red * alpha, rounding),
        _divide_by_255(green * alpha, rounding),
        _divide_by_255(blue * alpha, rounding),
        alpha,
    )


STRAIGHT_ALPHA_COMPOSITION_MODEL = "apng-straight-alpha-exact-numerator-floor-v1"


def _straight_over(
    source: tuple[int, int, int, int],
    destination: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    source_red, source_green, source_blue, source_alpha = source
    destination_red, destination_green, destination_blue, destination_alpha = destination
    inverse_alpha = 255 - source_alpha
    alpha_numerator = source_alpha * 255 + destination_alpha * inverse_alpha
    if alpha_numerator == 0:
        return (0, 0, 0, 0)

    def channel(source_channel: int, destination_channel: int) -> int:
        numerator = (
            source_channel * source_alpha * 255
            + destination_channel * destination_alpha * inverse_alpha
        )
        return min(255, numerator // alpha_numerator)

    return (
        channel(source_red, destination_red),
        channel(source_green, destination_green),
        channel(source_blue, destination_blue),
        min(255, alpha_numerator // 255),
    )


def _premultiplied_output(canvas: bytes | bytearray, rounding: str) -> bytes:
    output = bytearray(len(canvas))
    for offset in range(0, len(canvas), 4):
        red, green, blue, alpha = canvas[offset : offset + 4]
        output[offset : offset + 4] = bytes(
            (
                _divide_by_255(red * alpha, rounding),
                _divide_by_255(green * alpha, rounding),
                _divide_by_255(blue * alpha, rounding),
                alpha,
            )
        )
    return bytes(output)


def compose_frames(
    image: APNGImage,
    *,
    premultiply_rounding: str = "nearest",
) -> tuple[ComposedFrame, ...]:
    # APNG blend operations are defined over straight-alpha samples. Keeping this
    # canvas unpremultiplied avoids the per-frame quantization drift produced by a
    # premultiplied byte canvas. The emitted CoreGraphics-style bytes are
    # premultiplied only after each frame is fully composed.
    canvas = bytearray(image.canvas_width * image.canvas_height * 4)
    output: list[ComposedFrame] = []
    for raw_frame in image.frames:
        control = raw_frame.control
        previous = bytes(canvas) if control.dispose_op == 2 else None
        source_offset = 0
        for row in range(control.height):
            canvas_row = control.y_offset + row
            for column in range(control.width):
                canvas_column = control.x_offset + column
                destination_offset = (
                    canvas_row * image.canvas_width + canvas_column
                ) * 4
                source = tuple(raw_frame.rgba[source_offset : source_offset + 4])
                source_offset += 4
                if control.blend_op == 0:
                    result = source
                else:
                    destination = tuple(
                        canvas[destination_offset : destination_offset + 4]
                    )
                    result = _straight_over(source, destination)
                canvas[destination_offset : destination_offset + 4] = bytes(result)
        output.append(
            ComposedFrame(
                control=control,
                premultiplied_rgba=_premultiplied_output(
                    canvas, premultiply_rounding
                ),
            )
        )
        if control.dispose_op == 1:
            for row in range(control.height):
                start = (
                    (control.y_offset + row) * image.canvas_width + control.x_offset
                ) * 4
                end = start + control.width * 4
                canvas[start:end] = b"\x00" * (control.width * 4)
        elif control.dispose_op == 2:
            if previous is None:
                raise APNGReferenceError("missing previous canvas snapshot")
            canvas[:] = previous
    return tuple(output)


def vertically_flip_rgba(data: bytes, width: int, height: int) -> bytes:
    row_bytes = width * 4
    if len(data) != row_bytes * height:
        raise APNGReferenceError("RGBA byte count mismatch for vertical flip")
    return b"".join(
        data[row * row_bytes : (row + 1) * row_bytes]
        for row in range(height - 1, -1, -1)
    )
