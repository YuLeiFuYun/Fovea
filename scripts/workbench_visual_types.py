"""Shared value types for the Workbench visual oracle."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Finding:
    code: str
    severity: str
    path: str
    detail: str

    def as_json(self) -> dict[str, str]:
        return {
            "code": self.code,
            "severity": self.severity,
            "path": self.path,
            "detail": self.detail,
        }


@dataclass(frozen=True)
class PixelAudit:
    width: int
    height: int
    sampled_pixels: int
    unique_colors: int
    channel_stddev: tuple[float, float, float]
    uniform_tile_ratio: float
    likely_color_block: bool

    def as_json(self) -> dict[str, Any]:
        return {
            "width": self.width,
            "height": self.height,
            "sampledPixels": self.sampled_pixels,
            "uniqueColors": self.unique_colors,
            "channelStddev": list(self.channel_stddev),
            "uniformTileRatio": self.uniform_tile_ratio,
            "likelyColorBlock": self.likely_color_block,
        }


class PNGDecodeError(RuntimeError):
    """Raised when the bounded PNG reader encounters an unsupported layout."""
