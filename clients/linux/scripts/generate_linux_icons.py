#!/usr/bin/env python3
"""Create Linux launcher icons with real transparent rounded corners.

Apple and Windows apply their own platform masks to the canonical artwork.
Linux desktop shells do not, so packaging those opaque PNGs directly produces
an unrelated black square around the intended rounded-square icon.
"""

from __future__ import annotations

import argparse
import binascii
import math
import struct
import zlib
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def read_rgba(path: Path) -> tuple[int, int, list[bytearray]]:
    payload = path.read_bytes()
    if not payload.startswith(PNG_SIGNATURE):
        raise ValueError(f"not a PNG: {path}")

    position = len(PNG_SIGNATURE)
    compressed = bytearray()
    width = height = bit_depth = colour_type = 0
    while position < len(payload):
        length = struct.unpack(">I", payload[position : position + 4])[0]
        chunk_type = payload[position + 4 : position + 8]
        chunk = payload[position + 8 : position + 8 + length]
        position += length + 12
        if chunk_type == b"IHDR":
            width, height, bit_depth, colour_type, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", chunk)
            )
            if (bit_depth, colour_type, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError(f"expected non-interlaced 8-bit RGBA PNG: {path}")
        elif chunk_type == b"IDAT":
            compressed.extend(chunk)
        elif chunk_type == b"IEND":
            break

    raw = zlib.decompress(bytes(compressed))
    stride = width * 4
    rows: list[bytearray] = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        row = bytearray(raw[offset : offset + stride])
        offset += stride
        for index in range(stride):
            left = row[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 1:
                row[index] = (row[index] + left) & 0xFF
            elif filter_type == 2:
                row[index] = (row[index] + above) & 0xFF
            elif filter_type == 3:
                row[index] = (row[index] + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (
                    abs(estimate - left),
                    abs(estimate - above),
                    abs(estimate - upper_left),
                )
                predictor = (left, above, upper_left)[distances.index(min(distances))]
                row[index] = (row[index] + predictor) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"unsupported PNG filter {filter_type}: {path}")
        rows.append(row)
        previous = row
    return width, height, rows


def rounded_coverage(x: int, y: int, width: int, height: int) -> float:
    """Return antialiased coverage for the artwork's rounded-square silhouette."""

    inset = min(width, height) * 0.035
    left = inset
    top = inset
    right = width - inset
    bottom = height - inset
    radius = min(width, height) * 0.17
    samples = 4
    covered = 0
    for sample_y in range(samples):
        py = y + (sample_y + 0.5) / samples
        for sample_x in range(samples):
            px = x + (sample_x + 0.5) / samples
            nearest_x = min(max(px, left + radius), right - radius)
            nearest_y = min(max(py, top + radius), bottom - radius)
            if math.hypot(px - nearest_x, py - nearest_y) <= radius:
                covered += 1
    return covered / (samples * samples)


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def write_rgba(path: Path, width: int, height: int, rows: list[bytearray]) -> None:
    raw = b"".join(b"\0" + bytes(row) for row in rows)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(
        PNG_SIGNATURE
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(raw, level=9))
        + png_chunk(b"IEND", b"")
    )


def generate(source: Path, destination: Path) -> None:
    width, height, rows = read_rgba(source)
    if width != height:
        raise ValueError(f"launcher icon must be square: {source}")
    for y, row in enumerate(rows):
        for x in range(width):
            alpha_index = x * 4 + 3
            coverage = rounded_coverage(x, y, width, height)
            row[alpha_index] = round(row[alpha_index] * coverage)
    write_rgba(destination, width, height, rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    generate(args.source, args.destination)


if __name__ == "__main__":
    main()
