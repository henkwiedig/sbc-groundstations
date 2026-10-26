#!/usr/bin/env python3
"""
Makes the panel screens of the SD-card update (vr04-sdupdate) from the boot
splash: the logo smaller and higher, a line of text under it, and room for
busybox fbsplash's progress bar (BAR_* in update-bar.ini). The PNGs are
committed in overlay/usr/share/; rerun this after changing the splash or the
text. Needs Pillow and the Noto Sans fonts.

  make-update-screens.py [--preview PERCENT DIR]
"""
import argparse
import os

from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SHARE = os.path.join(HERE, "..", "overlay", "usr", "share")
SPLASH = os.path.join(HERE, "..", "..", "..", "common", "overlay", "usr", "share", "splash.png")
FONTS = "/usr/share/fonts/truetype/noto"
BACKGROUND = (75, 95, 214)
# where fbsplash draws the bar (update-bar.ini)
BAR = (460, 860, 1000, 44)
BAR_COLOUR = (255, 255, 255)

SCREENS = {
    "update": ("Updating firmware", "Do not power off the goggles"),
    "update-done": ("Update installed", "Restarting..."),
    "update-failed": ("Update failed", "Starting as before - sysupgrade.log on the SD card says why"),
}


def logo():
    splash = Image.open(SPLASH).convert("RGB")
    # the logo and wordmark: everything that is not background
    bbox = ImageChops.difference(splash, Image.new("RGB", splash.size, BACKGROUND)).getbbox()
    art = splash.crop(bbox)
    scale = 440 / art.height
    return art.resize((round(art.width * scale), 440), Image.LANCZOS)


def screen(art, title, line):
    im = Image.new("RGB", (1920, 1080), BACKGROUND)
    im.paste(art, ((1920 - art.width) // 2, 110))
    draw = ImageDraw.Draw(im)
    for text, font, y in ((title, ImageFont.truetype(f"{FONTS}/NotoSans-Bold.ttf", 76), 610),
                          (line, ImageFont.truetype(f"{FONTS}/NotoSans-Regular.ttf", 44), 730)):
        width = draw.textlength(text, font=font)
        draw.text(((1920 - width) / 2, y), text, font=font, fill=(255, 255, 255))
    return im


def fbsplash_bar(im, percent):
    """What busybox fbsplash draws: outline in half the bar colour, the empty part
    in the bar colour, the filled part in a grey gradient (200 at the top, 100 at
    the bottom)."""
    left, top, width, height = BAR
    draw = ImageDraw.Draw(im)
    draw.rectangle((left, top, left + width - 1, top + height - 1), outline=tuple(c // 2 for c in BAR_COLOUR))
    inner_w, inner_h = width - 3, height - 3
    pos = left + 1 + inner_w * percent // 100
    for i in range(inner_h + 1):
        grey = 100 + (inner_h - i) * 100 // inner_h
        draw.line((left + 1, top + 1 + i, pos, top + 1 + i), fill=(grey,) * 3)
    draw.rectangle((pos, top + 1, left + 1 + inner_w, top + 1 + inner_h), fill=BAR_COLOUR)
    return im


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--preview", nargs=2, metavar=("PERCENT", "DIR"),
                    help="also write the update screen with a simulated bar")
    a = ap.parse_args()
    art = logo()
    for name, (title, line) in SCREENS.items():
        path = os.path.join(SHARE, f"{name}.png")
        screen(art, title, line).save(path, optimize=True)
        print(f"{path}: {os.path.getsize(path)} bytes")
    # fbsplash wants an image: one pixel of background where the screen has background
    with open(os.path.join(SHARE, "update-bar.ppm"), "wb") as f:
        f.write(b"P6\n1 1\n255\n" + bytes(BACKGROUND))
    if a.preview:
        im = fbsplash_bar(screen(art, *SCREENS["update"]), int(a.preview[0]))
        im.resize((960, 540)).save(os.path.join(a.preview[1], "update-preview.png"))


if __name__ == "__main__":
    main()
