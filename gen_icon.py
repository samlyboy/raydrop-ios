import zlib, struct, os

W = H = 1024
BG = (37, 99, 235)      # RayDrop brand blue #2563EB
FG = (255, 255, 255)    # white
cx = cy = W / 2

def px(x, y):
    dx, dy = x - cx, y - cy
    d2 = dx * dx + dy * dy
    if d2 <= 300 * 300:
        return FG            # outer white circle (the "drop")
    if d2 <= 150 * 150:
        return BG            # inner blue dot
    return BG

raw = bytearray()
for y in range(H):
    raw.append(0)  # PNG filter type 0 (none)
    row = bytearray()
    for x in range(W):
        r, g, b = px(x, y)
        row += bytes((r, g, b))
    raw += row

comp = zlib.compress(bytes(raw), 9)

def chunk(typ, data):
    return (struct.pack(">I", len(data)) + typ + data +
            struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", comp)
png += chunk(b"IEND", b"")

out = os.path.join(os.path.dirname(__file__),
                   "RayDrop", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")
with open(out, "wb") as f:
    f.write(png)
print("wrote", out, len(png), "bytes")
