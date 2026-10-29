import os
import struct
import zlib

def write_png(filepath, width, height, rgba_bytes):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # Filter type 0 (None)
        raw.extend(rgba_bytes[y * stride:(y + 1) * stride])

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", ihdr) +
           chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
           chunk(b"IEND", b""))
    with open(filepath, "wb") as f:
        f.write(png)

def render_battery_icon(size):
    buf = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            idx = (y * size + x) * 4
            # Dark slate gradient background
            r = 16
            g = int(22 + (y / size) * 16)
            b = int(28 + (y / size) * 14)

            # Battery body coordinates (normalized)
            nx = x / size
            ny = y / size

            # Outer battery frame
            in_outer = (0.20 <= nx <= 0.76) and (0.32 <= ny <= 0.68)
            in_inner_cut = (0.24 <= nx <= 0.72) and (0.36 <= ny <= 0.64)
            in_cap = (0.76 < nx <= 0.82) and (0.43 <= ny <= 0.57)
            in_fill = (0.27 <= nx <= 0.66) and (0.39 <= ny <= 0.61)

            if (in_outer and not in_inner_cut) or in_cap:
                r, g, b = 235, 245, 240
            elif in_fill:
                r, g, b = 36, 214, 118

            buf[idx:idx + 4] = bytes((r, g, b, 255))
    return buf

if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources")
    os.makedirs(out_dir, exist_ok=True)
    write_png(os.path.join(out_dir, "AppIcon60x60@2x.png"), 120, 120, render_battery_icon(120))
    write_png(os.path.join(out_dir, "AppIcon60x60@3x.png"), 180, 180, render_battery_icon(180))
    print("Generated AppIcon60x60@2x.png and AppIcon60x60@3x.png")
