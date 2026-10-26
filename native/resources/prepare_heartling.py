"""Prepare the approved generated Heartling artwork for native, themeable rendering.

Requires Pillow and NumPy. Run: python3 resources/prepare_heartling.py <source.png>
The source is the transparent 3x2 Painter sheet generated in Amp thread
T-01a173c3-f466-716e-b30a-e6803e542bbe, attachment
36a1c2262e7cbf9254b974ab7a24023c0ed1d385be1d40457628e4d8a3bc838e-file.png.
Like Atlas's Pip pipeline, retain the painted silhouette, discard alpha haze,
and derive a blink from the original eyes so blinking cannot change anatomy.
"""

from collections import deque
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageOps


SIZE = 384
NAMES = ("idle", "curious", "delighted", "sleepy", "attentive", "blink")
DESTINATION = Path(__file__).resolve().parent / "heartling"


def regions(mask):
    visited = np.zeros(mask.shape, dtype=bool)
    height, width = mask.shape
    found = []
    for y, x in np.argwhere(mask):
        if visited[y, x]:
            continue
        pending = deque([(int(x), int(y))])
        visited[y, x] = True
        points = []
        while pending:
            px, py = pending.popleft()
            points.append((px, py))
            for nx, ny in ((px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)):
                if 0 <= nx < width and 0 <= ny < height and mask[ny, nx] and not visited[ny, nx]:
                    visited[ny, nx] = True
                    pending.append((nx, ny))
        found.append(points)
    return sorted(found, key=len, reverse=True)


def clean(cell):
    alpha = np.asarray(cell.getchannel("A"))
    silhouette = regions(alpha > 128)[0]
    mask = Image.new("L", cell.size)
    for point in silhouette:
        mask.putpixel(point, 255)
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.55))
    # Midgray preserves the selected primary color under hard-light blending.
    gray = ImageOps.grayscale(cell).point(lambda value: max(0, value - 56))
    result = Image.merge("LA", (gray, mask))
    return result.crop(mask.getbbox())


def blink(idle):
    pixels = np.asarray(idle.getchannel("L")).astype(float)
    alpha = np.asarray(idle.getchannel("A"))
    eyes = regions((pixels < 30) & (alpha > 250))[:2]
    assert len(eyes) == 2, "The idle artwork must have two isolated dark eyes"
    smooth = np.asarray(idle.getchannel("L").filter(ImageFilter.GaussianBlur(1.2))).astype(float)
    grain = pixels - smooth
    yy, xx = np.mgrid[:SIZE, :SIZE]
    closed = Image.new("L", (SIZE * 4, SIZE * 4))
    draw = ImageDraw.Draw(closed)
    for eye in eyes:
        xs, ys = zip(*eye)
        left, right, top, bottom = min(xs), max(xs), min(ys), max(ys)
        cx, cy = (left + right) / 2, (top + bottom) / 2
        rx, ry = (right - left) / 2 + 9, (bottom - top) / 2 + 9
        x, y = (xx - cx) / rx, (yy - cy) / ry
        radius = x * x + y * y
        ring = (radius > 1.15) & (radius < 2.4) & (alpha > 250)
        basis = np.stack((np.ones_like(x), x, y, x * x, x * y, y * y), axis=-1)
        coefficients = np.linalg.lstsq(basis[ring], pixels[ring], rcond=None)[0]
        # Continue the lighting gradient, retaining nearby painted clay texture.
        healed = np.clip(np.einsum("...i,i->...", basis, coefficients) + np.roll(grain, round(ry * 3), axis=0), 0, 255)
        weight = np.clip((1.2 - radius) / 0.35, 0, 1)
        pixels = pixels * (1 - weight) + healed * weight
        points = []
        for step in range(31):
            t = step / 30
            points.append(((left + (right - left) * t) * 4, (cy + 3 * np.sin(t * np.pi)) * 4))
        draw.line(points, fill=255, width=8, joint="curve")
    eyelids = closed.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    result = Image.fromarray(pixels.round().astype(np.uint8))
    result.paste(8, mask=eyelids)
    return Image.merge("LA", (result, idle.getchannel("A")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    source = Image.open(args.source).convert("RGBA")
    cells = []
    for index in range(5):
        column, row = index % 3, index // 3
        bounds = (round(column * source.width / 3), round(row * source.height / 2),
                  round((column + 1) * source.width / 3), round((row + 1) * source.height / 2))
        cells.append(clean(source.crop(bounds)))
    scale = 318 / max(cell.height for cell in cells)
    frames = []
    for cell in cells:
        cell = cell.resize((round(cell.width * scale), round(cell.height * scale)), Image.Resampling.LANCZOS)
        assert cell.width <= SIZE - 32
        frame = Image.new("LA", (SIZE, SIZE))
        frame.paste(cell, ((SIZE - cell.width) // 2, 352 - cell.height))
        frames.append(frame)
    frames.append(blink(frames[0]))
    assert frames[0].getchannel("A").tobytes() == frames[5].getchannel("A").tobytes()
    atlas = Image.new("LA", (SIZE * 3, SIZE * 2))
    for index, frame in enumerate(frames):
        atlas.paste(frame, ((index % 3) * SIZE, (index // 3) * SIZE))
    DESTINATION.mkdir(exist_ok=True)
    atlas.save(DESTINATION / "heartling.png", optimize=True)
    manifest = {
        "version": 1, "image": "heartling.png", "width": atlas.width, "height": atlas.height,
        "frameWidth": SIZE, "frameHeight": SIZE, "columns": 3,
        "tintToken": "primary", "blendMode": "hard-light",
        "states": {name: {"frames": [index]} for index, name in enumerate(NAMES)},
    }
    (DESTINATION / "heartling.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(frames)} aligned frames: {atlas.width}x{atlas.height}, {DESTINATION}")


if __name__ == "__main__":
    main()
