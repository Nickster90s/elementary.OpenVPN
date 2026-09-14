#!/usr/bin/env python3
"""
Generate the installable icons from the source artwork in icons/.

  icons/openvpn_logo.png       -> data/icons/<size>.png   (app icon)
  icons/openvpn-wingpanel.webp -> reference for the panel icon shape

The app logo ships on a solid white square. The white is un-matted back to
alpha and replaced with a white disc, so the mark keeps its own colours but
stays legible on elementary's dark app menu and dock.

The panel icon has to be an SVG: GTK only recolours symbolic icons to the
panel's foreground colour when they are vector. It is traced from the logo's
solid shapes, which stay readable at the 16px panel size where the supplied
outline version blurs together.

Needs only Pillow. Run from the project root:

    python3 tools/make-icons.py
"""

import os
import sys
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_LOGO = os.path.join(ROOT, 'icons', 'openvpn_logo.png')
OUT_DIR = os.path.join(ROOT, 'data', 'icons')

WHITE = (255, 255, 255)
PALETTE = [(234, 126, 32), (0, 51, 102)]      # OpenVPN orange and blue
APP_SIZES = (16, 24, 32, 48, 64, 128, 256)
SYMBOLIC_NAME = 'openvpn3-symbolic.svg'
SYMBOLIC_SIZE = 16
SYMBOLIC_MARGIN = 0.5                          # px, inside the 16px box
TRACE_EPSILON = 2.0                            # px, on the 300px trace canvas


# --------------------------------------------------------------------------
# App icon
# --------------------------------------------------------------------------

def unmatte(colour):
    """Recover (foreground colour, alpha) for a pixel composited over white.

    Each palette colour is tried by projecting the pixel onto the line from
    white to that colour; the one with the smallest residual wins.
    """
    best = None
    for f in PALETTE:
        d = [WHITE[i] - f[i] for i in range(3)]
        denom = sum(v * v for v in d)
        num = sum((WHITE[i] - colour[i]) * d[i] for i in range(3))
        a = max(0.0, min(1.0, num / denom))
        recon = [a * f[i] + (1 - a) * WHITE[i] for i in range(3)]
        err = sum((recon[i] - colour[i]) ** 2 for i in range(3))
        if best is None or err < best[0]:
            best = (err, f, a)
    _, f, a = best
    return (f[0], f[1], f[2], int(round(a * 255)))


def build_master():
    """The logo cut out of its white square, centred on a square canvas."""
    im = Image.open(SRC_LOGO).convert('RGB')
    w, h = im.size
    px = im.load()

    cut = Image.new('RGBA', (w, h))
    cp = cut.load()
    cache = {}
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            v = cache.get(c)
            if v is None:
                v = unmatte(c)
                cache[c] = v
            cp[x, y] = v

    cropped = cut.crop(cut.getbbox())
    cw, ch = cropped.size
    side = max(cw, ch)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.paste(cropped, ((side - cw) // 2, (side - ch) // 2))
    return square


def add_disc(master):
    """Put the mark back on white, as a disc rather than a square."""
    side = master.size[0]
    ss = 4                                      # supersample the disc edge
    disc = Image.new('L', (side * ss, side * ss), 0)
    ImageDraw.Draw(disc).ellipse([0, 0, side * ss - 1, side * ss - 1], fill=255)
    disc = disc.resize((side, side), Image.LANCZOS)

    plate = Image.composite(
        Image.new('RGBA', (side, side), (255, 255, 255, 255)),
        Image.new('RGBA', (side, side), (0, 0, 0, 0)),
        disc
    )
    return Image.alpha_composite(plate, master)


# --------------------------------------------------------------------------
# Panel icon: raster -> SVG path
# --------------------------------------------------------------------------

def to_mask(image, size=300, threshold=128):
    alpha = image.split()[3].resize((size, size), Image.LANCZOS)
    ap = alpha.load()
    return [[ap[x, y] > threshold for x in range(size)] for y in range(size)], size, size


def boundary_loops(mask, w, h):
    """Unit edges along the outside of every set pixel, stitched into loops.

    Each edge is emitted in a consistent direction, so following them from any
    start point walks one closed contour.
    """
    edges = {}

    def add(a, b):
        edges.setdefault(a, []).append(b)

    for y in range(h):
        for x in range(w):
            if not mask[y][x]:
                continue
            if y == 0 or not mask[y - 1][x]:
                add((x, y), (x + 1, y))
            if x + 1 >= w or not mask[y][x + 1]:
                add((x + 1, y), (x + 1, y + 1))
            if y + 1 >= h or not mask[y + 1][x]:
                add((x + 1, y + 1), (x, y + 1))
            if x == 0 or not mask[y][x - 1]:
                add((x, y + 1), (x, y))

    loops = []
    while edges:
        start = next(iter(edges))
        loop = [start]
        cur = start
        while True:
            nxts = edges.get(cur)
            if not nxts:
                break
            nxt = nxts.pop()
            if not nxts:
                del edges[cur]
            if nxt == start:
                break
            loop.append(nxt)
            cur = nxt
        if len(loop) > 7:
            loops.append(loop)
    return loops


def _dp(pts, eps):
    """Douglas-Peucker on an open polyline."""
    if len(pts) < 3:
        return pts
    ax, ay = pts[0]
    bx, by = pts[-1]
    dx, dy = bx - ax, by - ay
    den = (dx * dx + dy * dy) ** 0.5
    worst, wi = -1.0, 0
    for i in range(1, len(pts) - 1):
        px, py = pts[i]
        if den == 0:
            d = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
        else:
            d = abs(dy * px - dx * py + bx * ay - by * ax) / den
        if d > worst:
            worst, wi = d, i
    if worst > eps:
        return _dp(pts[:wi + 1], eps)[:-1] + _dp(pts[wi:], eps)
    return [pts[0], pts[-1]]


def simplify_closed(loop, eps):
    """Simplify a closed ring, split at the two most distant points."""
    ax, ay = loop[0]
    far, fi = -1.0, 0
    for i, (x, y) in enumerate(loop):
        d = (x - ax) ** 2 + (y - ay) ** 2
        if d > far:
            far, fi = d, i
    a = _dp(loop[:fi + 1], eps)
    b = _dp(loop[fi:] + [loop[0]], eps)
    return a[:-1] + b[:-1]


def to_svg(loops, w, h, size, margin):
    scale = (size - 2 * margin) / max(w, h)
    ox = margin + (size - 2 * margin - w * scale) / 2
    oy = margin + (size - 2 * margin - h * scale) / 2

    def fmt(v):
        return ('%.3f' % v).rstrip('0').rstrip('.')

    parts = []
    for loop in loops:
        pts = ['%s %s' % (fmt(ox + x * scale), fmt(oy + y * scale)) for x, y in loop]
        parts.append('M' + ' L'.join(pts) + ' Z')

    # The fill is a presentation attribute so the file renders on its own;
    # GTK's symbolic stylesheet overrides it with the panel's colour.
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">\n'
        '  <title>OpenVPN</title>\n'
        '  <path fill="#000000" fill-rule="evenodd" d="%s"/>\n'
        '</svg>\n'
    ) % (size, size, size, size, ' '.join(parts))


# --------------------------------------------------------------------------

def main():
    if not os.path.exists(SRC_LOGO):
        sys.exit('missing source artwork: %s' % SRC_LOGO)

    os.makedirs(OUT_DIR, exist_ok=True)

    master = build_master()
    app_icon = add_disc(master)
    for size in APP_SIZES:
        path = os.path.join(OUT_DIR, '%d.png' % size)
        app_icon.resize((size, size), Image.LANCZOS).save(path)
        print('wrote', os.path.relpath(path, ROOT))

    mask, w, h = to_mask(master)
    loops = [simplify_closed(l, TRACE_EPSILON) for l in boundary_loops(mask, w, h)]
    loops = [l for l in loops if len(l) >= 3]
    svg = to_svg(loops, w, h, SYMBOLIC_SIZE, SYMBOLIC_MARGIN)

    path = os.path.join(OUT_DIR, SYMBOLIC_NAME)
    open(path, 'w').write(svg)
    print('wrote %s (%d contours, %d points)'
          % (os.path.relpath(path, ROOT), len(loops), sum(len(l) for l in loops)))


if __name__ == '__main__':
    main()
