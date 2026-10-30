#!/usr/bin/env python3
"""Membuat ikon aplikasi 1024x1024 (tanpa alpha) + asset catalog. Hanya memakai library bawaan Python."""
import json, math, os, struct, zlib

S = 1024
OUT = "NAMLoader/Assets.xcassets"
ICONSET = os.path.join(OUT, "AppIcon.appiconset")
os.makedirs(ICONSET, exist_ok=True)

def smooth(edge0, edge1, x):
    t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
    return t * t * (3 - 2 * t)

def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

cx = cy = S / 2
rows = []
for y in range(S):
    row = bytearray([0])  # filter type 0
    for x in range(S):
        t = (x + y) / (2 * S)
        col = mix((24, 24, 30), (52, 52, 62), t)
        dx, dy = x - cx, y - cy
        d = math.hypot(dx, dy)
        ring = smooth(372, 376, d) * (1 - smooth(404, 408, d))
        col = mix(col, (255, 149, 0), ring)
        body = 1 - smooth(366, 370, d)
        kn = mix((70, 70, 80), (34, 34, 40), min(max((dy + 366) / 732, 0), 1))
        col = mix(col, kn, body)
        ang = math.radians(35)
        ux, uy = math.sin(ang), -math.cos(ang)
        along = dx * ux + dy * uy
        perp = abs(-dx * uy + dy * ux)
        line = (1 - smooth(22, 26, perp)) * smooth(60, 64, along) * (1 - smooth(300, 304, along))
        col = mix(col, (255, 255, 255), line)
        row += bytes(int(min(max(c, 0), 255)) for c in col)
    rows.append(bytes(row))

raw = b"".join(rows)
def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
open(os.path.join(ICONSET, "icon-1024.png"), "wb").write(png)

json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal",
                       "platform": "ios", "size": "1024x1024"}],
           "info": {"author": "xcode", "version": 1}},
          open(os.path.join(ICONSET, "Contents.json"), "w"), indent=2)
json.dump({"info": {"author": "xcode", "version": 1}},
          open(os.path.join(OUT, "Contents.json"), "w"), indent=2)
print("Ikon dibuat di", ICONSET)
