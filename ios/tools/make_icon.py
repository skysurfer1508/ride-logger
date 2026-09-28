"""Draws the app icon (1024x1024, opaque RGB PNG, no alpha as the App Store requires): a night-mode dash gauge, amber on near-black.
Pure standard library. Run from the repo root:  python ios/tools/make_icon.py"""
import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
BG = (11, 12, 14)
DIM = (58, 61, 68)
AMBER = (255, 157, 46)
CENTER = SIZE / 2
R_OUT, R_IN = 372.0, 316.0                      # the ring
START_DEG, SWEEP_DEG = 135.0, 270.0             # gauge sweep, measured clockwise from 3 o'clock (screen coordinates)
VALUE = 0.68                                    # how much of the ring is lit
NEEDLE_LEN, NEEDLE_W = 290.0, 22.0
OUT = Path(__file__).resolve().parent.parent / "Sources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"


def clamp01(v: float) -> float:
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def mix(under, over, a):
    return tuple(round(u + (o - u) * a) for u, o in zip(under, over))


def angle_of(x: float, y: float) -> float:
    return (math.degrees(math.atan2(y - CENTER, x - CENTER)) + 360.0) % 360.0


def seg_dist(px, py, ax, ay, bx, by) -> float:
    dx, dy = bx - ax, by - ay
    t = clamp01(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def main() -> None:
    needle_deg = START_DEG + SWEEP_DEG * VALUE
    nx = CENTER + NEEDLE_LEN * math.cos(math.radians(needle_deg))
    ny = CENTER + NEEDLE_LEN * math.sin(math.radians(needle_deg))
    rows = []
    for y in range(SIZE):
        row = bytearray([0])                    # PNG filter type 0 for this scanline
        for x in range(SIZE):
            px, py = x + 0.5, y + 0.5
            color = BG
            r = math.hypot(px - CENTER, py - CENTER)
            rel = (angle_of(px, py) - START_DEG) % 360.0
            if rel <= SWEEP_DEG:
                ring = clamp01(min(r - R_IN, R_OUT - r) + 0.5)          # 1 px anti-aliased edges
                if ring > 0:
                    lit = rel <= SWEEP_DEG * VALUE
                    color = mix(color, AMBER if lit else DIM, ring)
            # tick marks every 10% around the outside of the ring
            for k in range(11):
                tick_deg = math.radians(START_DEG + SWEEP_DEG * k / 10)
                a = (CENTER + (R_OUT + 18) * math.cos(tick_deg), CENTER + (R_OUT + 18) * math.sin(tick_deg))
                b = (CENTER + (R_OUT + 52) * math.cos(tick_deg), CENTER + (R_OUT + 52) * math.sin(tick_deg))
                d = seg_dist(px, py, a[0], a[1], b[0], b[1])
                if d < 9:
                    color = mix(color, AMBER if k / 10 <= VALUE else DIM, clamp01(9 - d))
            d = seg_dist(px, py, CENTER, CENTER, nx, ny)
            if d < NEEDLE_W / 2 + 1:
                color = mix(color, AMBER, clamp01(NEEDLE_W / 2 + 0.5 - d))
            if r < 46:
                color = mix(color, AMBER, clamp01(46.5 - r))
            if r < 20:
                color = mix(color, BG, clamp01(20.5 - r))
            row.extend(color)
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))     # 8-bit RGB, no alpha
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(png)
    print(f"wrote {OUT} ({len(png) // 1024} KB)")


if __name__ == "__main__":
    main()
