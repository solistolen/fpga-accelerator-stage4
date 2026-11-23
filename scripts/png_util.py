"""Tiny grayscale PNG writer (no extra packages needed; Python 2 or 3)."""
import struct
import zlib


def write_png(path, rows, scale=1):
    """rows: list of lists of 0..255 values. scale: enlarge each pixel scale x scale."""
    h, w = len(rows), len(rows[0])
    raw = bytearray()
    for r in rows:
        line = bytearray()
        for v in r:
            line.extend([int(v) & 0xFF] * scale)
        for _ in range(scale):
            raw.append(0)                   # PNG filter type 0 (none) per scanline
            raw.extend(line)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 0, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))
