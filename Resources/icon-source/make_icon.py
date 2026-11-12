from PIL import Image, ImageDraw, ImageFont, ImageFilter
S = 4; N = 1024 * S
def rr(d, box, r, **kw): d.rounded_rectangle([v * S for v in box], r * S, **kw)

img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

# drop shadow + squircle body (macOS grid: 824 px body, 100 px inset)
sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
rr(ImageDraw.Draw(sh), (100, 112, 924, 936), 185, fill=(0, 0, 0, 110))
img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(14 * S)))
grad = Image.new("RGBA", (N, N))
gd = ImageDraw.Draw(grad)
top, bot = (52, 70, 108), (17, 24, 44)
for y in range(N):
    t = y / N
    gd.line([(0, y), (N, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bot)) + (255,))
mask = Image.new("L", (N, N), 0)
rr(ImageDraw.Draw(mask), (100, 100, 924, 924), 185, fill=255)
img.paste(grad, (0, 0), mask)

# label tape: yellow strip with black text and a thin frame, tilted
W, H = 760, 330
tape = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
td = ImageDraw.Draw(tape)
rr(td, (0, 0, W, H), 26, fill=(255, 205, 40, 255))
rr(td, (0, 0, W, 34), 26, fill=(255, 224, 110, 255))          # top highlight
td.rectangle([0, 26 * S, W * S, 34 * S], fill=(255, 205, 40, 255))
rr(td, (34, 34, W - 34, H - 34), 18, outline=(20, 20, 20, 255), width=12 * S)
font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 190 * S)
text = "Aa"
b = td.textbbox((0, 0), text, font=font)
td.text(((W * S - (b[2] - b[0])) / 2 - b[0], (H * S - (b[3] - b[1])) / 2 - b[1]), text, font=font, fill=(20, 20, 20, 255))
tape = tape.rotate(10, resample=Image.BICUBIC, expand=True)

tsh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
alpha = tape.split()[3].point(lambda a: a * 0.55)
shadow = Image.new("RGBA", tape.size, (0, 0, 0, 255)); shadow.putalpha(alpha)
x, y = (N - tape.width) // 2, (N - tape.height) // 2 + 20 * S
tsh.alpha_composite(shadow, (x + 6 * S, y + 22 * S))
img.alpha_composite(tsh.filter(ImageFilter.GaussianBlur(16 * S)))
img.alpha_composite(tape, (x, y))

img.resize((1024, 1024), Image.LANCZOS).save("icon_1024.png")
