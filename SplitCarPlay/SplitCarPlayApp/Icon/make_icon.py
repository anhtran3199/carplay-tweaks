"""Draws the SplitCarPlay app icon and writes every size the app needs.

Blue-to-indigo background, a wide white car screen split in two (left
pane solid, right pane lighter) and an orange speed bubble on its corner.
iOS rounds the corners itself, so the image is a full square.

    python make_icon.py            # writes into ../Resources
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'Resources')


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def font(size):
    for path in ('C:/Windows/Fonts/arialbd.ttf', '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
                 '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw_icon():
    img = Image.new('RGB', (SIZE, SIZE))
    top, bottom = (10, 132, 255), (94, 92, 230)  # systemBlue -> systemIndigo
    px = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            px[x, y] = lerp(top, bottom, (x + y) / (2 * (SIZE - 1)))

    layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Car screen
    sx0, sy0, sx1, sy1 = 130, 280, 894, 744
    d.rounded_rectangle((sx0, sy0, sx1, sy1), radius=70, fill=(255, 255, 255, 60), outline=(255, 255, 255, 255), width=34)
    inner = (sx0 + 58, sy0 + 58, sx1 - 58, sy1 - 58)
    split = inner[0] + int((inner[2] - inner[0]) * 0.56)
    d.rounded_rectangle((inner[0], inner[1], split - 18, inner[3]), radius=34, fill=(255, 255, 255, 255))
    d.rounded_rectangle((split + 18, inner[1], inner[2], inner[3]), radius=34, fill=(255, 255, 255, 150))

    # Speed bubble
    cx, cy, r = 774, 724, 160
    d.ellipse((cx - r - 16, cy - r - 16, cx + r + 16, cy + r + 16), fill=(255, 255, 255, 255))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 149, 0, 255))
    f = font(150)
    text = '60'
    box = d.textbbox((0, 0), text, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]), text, font=f, fill=(255, 255, 255, 255))

    img = img.convert('RGBA')
    img.alpha_composite(layer)
    return img.convert('RGB')


def main():
    icon = draw_icon()
    os.makedirs(OUT, exist_ok=True)
    sizes = {
        'AppIcon60x60@2x.png': 120, 'AppIcon60x60@3x.png': 180,
        'AppIcon40x40@2x.png': 80, 'AppIcon40x40@3x.png': 120,
        'AppIcon29x29@2x.png': 58, 'AppIcon29x29@3x.png': 87,
    }
    for name, px in sizes.items():
        icon.resize((px, px), Image.Resampling.LANCZOS).save(os.path.join(OUT, name))
    icon.save(os.path.join(HERE, 'AppIcon-1024.png'))
    print('wrote', ', '.join(sizes))


if __name__ == '__main__':
    sys.exit(main())
