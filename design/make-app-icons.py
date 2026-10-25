# Erzeugt die App-Icons aus design/AppIcon-Source.png:
#   python3 design/make-app-icons.py design/AppIcon-Source.png NotifyAI/Assets.xcassets/AppIcon.appiconset
# iOS: randloses 1024er-Icon (iOS rundet die Ecken selbst ab) plus getönte Variante.
# macOS: Apples Raster (824er Körper, abgerundet, Schatten) in allen Größen.

import sys
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

src, out = sys.argv[1], sys.argv[2]
im = np.asarray(Image.open(src).convert('RGB')).astype(np.float32)
TOP, BOT, LEFT, RIGHT = 160, 1095, 150, 1105   # dark rounded square in the source
N = 1024

# Background colour per source row, sampled between the waveform bars (no glyph there).
rows = np.arange(TOP, BOT)
bg_rows = np.median(im[TOP:BOT, 618:636], axis=1)
k = 15
pad = np.pad(bg_rows, ((k, k), (0, 0)), mode='edge')
bg_rows = np.stack([np.convolve(pad[:, c], np.ones(2*k+1)/(2*k+1), mode='valid') for c in range(3)], 1)

# Full-bleed background for the new canvas.
ys = np.linspace(0, len(bg_rows)-1, N)
grad = np.stack([np.interp(ys, np.arange(len(bg_rows)), bg_rows[:, c]) for c in range(3)], 1)
canvas = np.repeat(grad[:, None, :], N, axis=1)

# Glyphs: everything that differs clearly from the row background.
GX0, GX1, GY0, GY1 = 235, 1045, 400, 830
crop = im[GY0:GY1, GX0:GX1]
bgc = bg_rows[GY0-TOP:GY1-TOP][:, None, :]
alpha = np.clip((np.abs(crop - bgc).max(axis=2) - 6) / 40, 0, 1)
rgba = np.dstack([crop, alpha*255]).astype(np.uint8)
glyph = Image.fromarray(rgba, 'RGBA')

scale = N / (RIGHT - LEFT) * 0.88
gw, gh = round(glyph.width*scale), round(glyph.height*scale)
glyph = glyph.resize((gw, gh), Image.LANCZOS)
cx = ((GX0+GX1)/2 - (LEFT+RIGHT)/2) * scale + N/2
cy = ((GY0+GY1)/2 - (TOP+BOT)/2) * scale + N/2
pos = (round(cx - gw/2), round(cy - gh/2))

base = Image.fromarray(canvas.astype(np.uint8), 'RGB').convert('RGBA')
base.alpha_composite(glyph, pos)
ios = base.convert('RGB')
ios.save(f'{out}/AppIcon-iOS.png')

# Tinted: grey glyphs on black, the system colours them.
tint = Image.new('RGBA', (N, N), (0, 0, 0, 255))
tint.alpha_composite(glyph, pos)
tint.convert('L').convert('RGB').save(f'{out}/AppIcon-iOS-Tinted.png')

# macOS: Apple's grid, 824 pt body with rounded corners and a soft shadow on a transparent canvas.
S = 4  # supersampling for smooth edges
mask = Image.new('L', (N*S, N*S), 0)
ImageDraw.Draw(mask).rounded_rectangle([100*S, 100*S, 924*S, 924*S], radius=185*S, fill=255)
mask = mask.resize((N, N), Image.LANCZOS)
shadow = Image.new('RGBA', (N, N), (0, 0, 0, 0))
shadow.putalpha(mask.point(lambda v: v*0.35))
shadow = shadow.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -10)).filter(ImageFilter.GaussianBlur(14))
body = ios.resize((824, 824), Image.LANCZOS)
layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
layer.paste(body, (100, 100))
layer.putalpha(mask)
mac = Image.alpha_composite(shadow, layer)
for size in (16, 32, 64, 128, 256, 512, 1024):
    mac.resize((size, size), Image.LANCZOS).save(f'{out}/AppIcon-macOS-{size}.png')
