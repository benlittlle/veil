#!/usr/bin/env python3
"""Recompresses PNG files in place at the highest zlib level. Pixels and row filters are
unchanged (lossless); a file is only rewritten if it gets smaller. Standard library only.

  png-repack.py FILE.png ...
  png-repack.py --icns FILE.icns ...    the PNG images inside an .icns made by iconutil (other
                                        entries, such as the small legacy-format icons, are kept)"""
import struct
import sys
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"


def repack_png(data):
    """Returns the PNG with its image data recompressed, or the original if that isn't smaller."""
    chunks, idat, i = [], b"", 8
    while i < len(data):
        (n,) = struct.unpack(">I", data[i:i + 4])
        kind, body = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        i += 12 + n
        if kind == b"IDAT":
            if not idat:
                chunks.append((kind, None))   # all image data goes back as one chunk, here
            idat += body
        else:
            chunks.append((kind, body))
    c = zlib.compressobj(9, zlib.DEFLATED, 15, 9)
    packed = c.compress(zlib.decompress(idat)) + c.flush()
    out = bytearray(SIGNATURE)
    for kind, body in chunks:
        body = packed if body is None else body
        out += struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return bytes(out) if len(out) < len(data) else data


def repack(path):
    data = open(path, "rb").read()
    if data[:8] != SIGNATURE:
        raise SystemExit(f"{path}: not a PNG")
    out = repack_png(data)
    if out is not data:
        open(path, "wb").write(out)


def repack_icns(path):
    data = open(path, "rb").read()
    if data[:4] != b"icns":
        raise SystemExit(f"{path}: not an .icns")
    body, i = b"", 8
    while i < len(data):
        kind, (n,) = data[i:i + 4], struct.unpack(">I", data[i + 4:i + 8])
        entry = data[i + 8:i + n]
        i += n
        if entry[:8] == SIGNATURE:
            entry = repack_png(entry)
        body += kind + struct.pack(">I", 8 + len(entry)) + entry
    open(path, "wb").write(b"icns" + struct.pack(">I", 8 + len(body)) + body)


if sys.argv[1:2] == ["--icns"]:
    for p in sys.argv[2:]:
        repack_icns(p)
else:
    for p in sys.argv[1:]:
        repack(p)


