"""Makes the badges' cut-out mask and relief from the picture's transparency. Run it after saving
crapousine_badges.color.png:

    python make_badge_maps.py

It writes next to it:
  crapousine_badges_o.data.png    the mask: white where the picture is opaque (metal), black where transparent. The
                                  game reads which parts of the badges exist from this file only (its shaders ignore
                                  a colour picture's own transparency).
  crapousine_badges_n.normal.png  the relief: every shape raised with a rounded bevel along its edges, which is what
                                  makes chrome catch the light (red = slope across, green = slope up, as the game
                                  reads it).
The game picks them up by itself, or Ctrl+R in the car. No extra Python package needed.
"""
import functools
import math
import operator
import os
import struct
import sys
import zlib
from itertools import accumulate

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'crapousine_badges.color.png')
MASK = os.path.join(HERE, 'crapousine_badges_o.data.png')
NORMAL = os.path.join(HERE, 'crapousine_badges_n.normal.png')
BEVEL = 2           # px, radius of each of the two smoothing passes: the bevel is about 4 * BEVEL px wide (0.5 mm)
STEEPNESS = 5.0     # how steep the bevel is (higher: sharper relief)


def read_alpha(path):
    """The alpha channel of a PNG (8 or 16 bits, grey/RGB/palette, with or without alpha), as rows of bytes."""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit('%s is not a PNG picture' % path)
    pos, idat, trns = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            width, height, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif kind == b'tRNS':
            trns = body
        elif kind == b'IDAT':
            idat.append(body)
        pos += 12 + length
    if interlace:
        sys.exit('save the picture without interlacing')
    if depth not in (8, 16) and ctype != 3:
        sys.exit('save the picture with 8 or 16 bits per channel')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    bpp = max(1, channels * depth // 8)
    stride = (width * channels * depth + 7) // 8
    raw = zlib.decompress(b''.join(idat))
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                line[i] = (line[i] + ((line[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        if ctype in (4, 6):                          # alpha is the last channel (its high byte at 16 bits)
            size = channels * depth // 8
            rows.append(bytes(line[size - depth // 8::size]))
        elif ctype == 3:                             # palette: transparency per palette entry
            if depth != 8:
                sys.exit('save the picture as 8-bit or RGBA')
            table = (trns or b'') + b'\xff' * 256
            rows.append(bytes(table[i] for i in line))
        else:
            rows.append(b'\xff' * width)             # no transparency at all: everything shows
    return width, height, rows


def write_png(path, width, height, rows, colour):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2 if colour else 0, 0, 0, 0)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 6)) +
                           chunk(b'IEND', b''))


def box(line, r):
    """Sums over 2r+1 neighbours along a line (zero outside)."""
    padded = [0] * r + list(line) + [0] * r
    sums = [0] + list(accumulate(padded))
    return list(map(operator.sub, sums[2 * r + 1:], sums[:-(2 * r + 1)]))


@functools.lru_cache(maxsize=None)
def encode(gx, gy):
    """A slope (height steps per pixel across and down the picture) as a normal's colour."""
    nx, ny = -STEEPNESS * gx, STEEPNESS * gy     # up the picture is +green: a top edge leans up
    inv = 1 / math.sqrt(nx * nx + ny * ny + 1)
    return (int(round(127.5 + 127.5 * nx * inv)), int(round(127.5 + 127.5 * ny * inv)), int(round(127.5 + 127.5 * inv)))


width, height, alpha = read_alpha(SRC)
if (width, height) != (2048, 1024):
    print('note: the picture is %d x %d, the boxes are laid out for 2048 x 1024' % (width, height))
write_png(MASK, width, height, alpha, colour=False)

# the relief: the mask smoothed twice each way (a rounded bevel), its slopes as normals
h = [box(box(row, BEVEL), BEVEL) for row in alpha]
cols = [box(box(col, BEVEL), BEVEL) for col in zip(*h)]
h = [list(row) for row in zip(*cols)]
scale = 1 / (255 * (2 * BEVEL + 1) ** 4)         # back to 0..1
zero = [0] * width
flat = bytes(encode(0, 0)) * width
normals = []
for y in range(height):
    row = h[y]
    up, down = (h[y - 1] if y else zero), (h[y + 1] if y + 1 < height else zero)
    gx = [0] + list(map(operator.sub, row[2:], row[:-2])) + [0]
    gy = list(map(operator.sub, down, up))
    if not any(gx) and not any(gy):
        normals.append(flat)
        continue
    out = bytearray()
    for a, b in zip(gx, gy):
        out.extend(encode(round(a * scale * 0.5, 3), round(b * scale * 0.5, 3)))
    normals.append(out)
write_png(NORMAL, width, height, normals, colour=True)
opaque = sum(sum(1 for v in r if v >= 128) for r in alpha)
print('mask and relief written (%d pixels of metal); the game picks them up by itself, else Ctrl+R in the car' % opaque)
