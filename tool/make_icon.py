"""Generate the original geometric XingJi icon at Windows ICO sizes."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
size = 512
image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
mask = Image.new('L', (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle((18, 18, 494, 494), radius=116, fill=255)
gradient = Image.new('RGBA', (size, size))
pixels = gradient.load()
for y in range(size):
    for x in range(size):
        t = (x + y) / (2 * size)
        pixels[x, y] = (int(21 + 23 * t), int(72 - 27 * t), int(81 + 6 * t), 255)
image.paste(gradient, (0, 0), mask)
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((19, 19, 493, 493), radius=116, outline=(78, 165, 162, 255), width=7)
draw.ellipse((100, 99, 412, 411), outline=(96, 163, 177, 100), width=3)
draw.polygon([(255, 93), (298, 214), (419, 256), (298, 298), (255, 419), (214, 298), (93, 256), (214, 214)], fill=(107, 233, 208, 255))
draw.polygon([(371, 85), (384, 122), (422, 136), (384, 149), (371, 186), (358, 149), (321, 136), (358, 122)], fill=(187, 172, 255, 255))
target = root / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
image.save(target, sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
(root / 'assets').mkdir(exist_ok=True)
image.resize((256, 256), Image.Resampling.LANCZOS).save(root / 'assets' / 'xingji.png')
print(target)
