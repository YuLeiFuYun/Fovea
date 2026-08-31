#!/usr/bin/env python3
from __future__ import annotations

import struct
import sys
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/Performance"))

import w5_apng_reference as reference


def chunk(kind: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(kind)
    crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", crc)


def filtered_rgba(width: int, height: int, pixels: bytes) -> bytes:
    row_bytes = width * 4
    if len(pixels) != row_bytes * height:
        raise ValueError("pixel byte count mismatch")
    scanlines = bytearray()
    for row in range(height):
        scanlines.append(0)
        scanlines.extend(pixels[row * row_bytes : (row + 1) * row_bytes])
    return zlib.compress(bytes(scanlines))


def frame_control(
    sequence: int,
    width: int,
    height: int,
    x: int,
    y: int,
    disposal: int,
    blend: int,
    delay_num: int = 1,
    delay_den: int = 10,
) -> bytes:
    return struct.pack(
        ">IIIIIHHBB",
        sequence,
        width,
        height,
        x,
        y,
        delay_num,
        delay_den,
        disposal,
        blend,
    )


def make_apng(*, default_image_not_animated: bool = False) -> bytes:
    canvas_width = 2
    canvas_height = 2
    red_canvas = bytes((255, 0, 0, 255)) * 4
    default_canvas = bytes((0, 0, 0, 0)) * 4
    blue_half = bytes((0, 0, 255, 128))
    green = bytes((0, 255, 0, 255))
    result = bytearray(reference.PNG_SIGNATURE)
    result.extend(
        chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", canvas_width, canvas_height, 8, 6, 0, 0, 0),
        )
    )
    result.extend(chunk(b"acTL", struct.pack(">II", 3, 0)))
    if default_image_not_animated:
        result.extend(chunk(b"IDAT", filtered_rgba(2, 2, default_canvas)))
        result.extend(chunk(b"fcTL", frame_control(0, 2, 2, 0, 0, 0, 0)))
        result.extend(
            chunk(
                b"fdAT",
                struct.pack(">I", 1) + filtered_rgba(2, 2, red_canvas),
            )
        )
        next_sequence = 2
    else:
        result.extend(chunk(b"fcTL", frame_control(0, 2, 2, 0, 0, 0, 0)))
        result.extend(chunk(b"IDAT", filtered_rgba(2, 2, red_canvas)))
        next_sequence = 1
    result.extend(
        chunk(
            b"fcTL",
            frame_control(next_sequence, 1, 1, 1, 0, 2, 1),
        )
    )
    result.extend(
        chunk(
            b"fdAT",
            struct.pack(">I", next_sequence + 1) + filtered_rgba(1, 1, blue_half),
        )
    )
    result.extend(
        chunk(
            b"fcTL",
            frame_control(next_sequence + 2, 1, 1, 0, 1, 1, 0),
        )
    )
    result.extend(
        chunk(
            b"fdAT",
            struct.pack(">I", next_sequence + 3) + filtered_rgba(1, 1, green),
        )
    )
    result.extend(chunk(b"IEND", b""))
    return bytes(result)


def make_translucent_over_apng() -> bytes:
    first = bytes((245, 34, 0, 128))
    second = bytes((90, 245, 0, 128))
    result = bytearray(reference.PNG_SIGNATURE)
    result.extend(
        chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0),
        )
    )
    result.extend(chunk(b"acTL", struct.pack(">II", 2, 0)))
    result.extend(chunk(b"fcTL", frame_control(0, 1, 1, 0, 0, 0, 0)))
    result.extend(chunk(b"IDAT", filtered_rgba(1, 1, first)))
    result.extend(chunk(b"fcTL", frame_control(1, 1, 1, 0, 0, 0, 1)))
    result.extend(
        chunk(
            b"fdAT",
            struct.pack(">I", 2) + filtered_rgba(1, 1, second),
        )
    )
    result.extend(chunk(b"IEND", b""))
    return bytes(result)


class W5APNGReferenceTests(unittest.TestCase):
    def test_parse_and_compose_subrect_disposal(self) -> None:
        image = reference.parse_apng(make_apng())
        self.assertEqual((image.canvas_width, image.canvas_height), (2, 2))
        self.assertEqual(len(image.frames), 3)
        self.assertEqual(image.num_plays, 0)
        self.assertEqual(image.frames[1].control.x_offset, 1)
        self.assertEqual(image.frames[1].control.dispose_op, 2)
        self.assertEqual(image.frames[1].control.blend_op, 1)
        self.assertEqual(image.frames[1].byte_count, 4)
        self.assertEqual(image.frames[1].control.duration_nanoseconds, 100_000_000)

        frames = reference.compose_frames(image)
        red = bytes((255, 0, 0, 255))
        self.assertEqual(frames[0].premultiplied_rgba, red * 4)
        expected_second = red + bytes((127, 0, 128, 255)) + red + red
        self.assertEqual(frames[1].premultiplied_rgba, expected_second)
        expected_third = red + red + bytes((0, 255, 0, 255)) + red
        self.assertEqual(frames[2].premultiplied_rgba, expected_third)

    def test_straight_alpha_canvas_avoids_premultiplied_quantization_drift(self) -> None:
        image = reference.parse_apng(make_translucent_over_apng())
        frames = reference.compose_frames(image)
        self.assertEqual(frames[0].premultiplied_rgba, bytes((123, 17, 0, 128)))
        self.assertEqual(frames[1].premultiplied_rgba, bytes((106, 130, 0, 191)))
        self.assertEqual(
            reference.STRAIGHT_ALPHA_COMPOSITION_MODEL,
            "apng-straight-alpha-exact-numerator-floor-v1",
        )

    def test_default_image_can_be_excluded_from_animation(self) -> None:
        image = reference.parse_apng(make_apng(default_image_not_animated=True))
        self.assertEqual(len(image.frames), 3)
        self.assertEqual(reference.compose_frames(image)[0].premultiplied_rgba, bytes((255, 0, 0, 255)) * 4)

    def test_png_filters_round_trip(self) -> None:
        decoded_rows = [bytes((10, 20, 30, 40, 50, 60, 70, 80)), bytes((90, 100, 110, 120, 130, 140, 150, 160))]
        bpp = 4
        for filter_type in range(5):
            encoded_payload = bytearray()
            previous = bytes(len(decoded_rows[0]))
            for row in decoded_rows:
                encoded_payload.append(filter_type)
                encoded = bytearray()
                for index, value in enumerate(row):
                    left = row[index - bpp] if index >= bpp else 0
                    above = previous[index]
                    upper_left = previous[index - bpp] if index >= bpp else 0
                    if filter_type == 0:
                        prediction = 0
                    elif filter_type == 1:
                        prediction = left
                    elif filter_type == 2:
                        prediction = above
                    elif filter_type == 3:
                        prediction = (left + above) // 2
                    else:
                        prediction = reference._paeth(left, above, upper_left)
                    encoded.append((value - prediction) & 0xFF)
                encoded_payload.extend(encoded)
                previous = row
            actual = reference._unfilter(zlib.compress(bytes(encoded_payload)), 2, 2, 8, 6)
            self.assertEqual(actual, decoded_rows)

    def test_vertical_flip_is_involutive(self) -> None:
        data = bytes(range(24))
        flipped = reference.vertically_flip_rgba(data, 2, 3)
        self.assertEqual(reference.vertically_flip_rgba(flipped, 2, 3), data)

    def test_crc_tampering_fails_closed(self) -> None:
        data = bytearray(make_apng())
        data[-5] ^= 1
        with self.assertRaises(reference.APNGReferenceError):
            reference.parse_apng(bytes(data))

    def test_interlaced_input_is_rejected(self) -> None:
        data = bytearray(make_apng())
        ihdr_payload_offset = len(reference.PNG_SIGNATURE) + 8
        data[ihdr_payload_offset + 12] = 1
        kind_offset = len(reference.PNG_SIGNATURE) + 4
        payload = bytes(data[ihdr_payload_offset : ihdr_payload_offset + 13])
        crc = zlib.crc32(bytes(data[kind_offset : kind_offset + 4]))
        crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
        crc_offset = ihdr_payload_offset + 13
        data[crc_offset : crc_offset + 4] = struct.pack(">I", crc)
        with self.assertRaisesRegex(reference.APNGReferenceError, "non-interlaced"):
            reference.parse_apng(bytes(data))


if __name__ == "__main__":
    unittest.main()
