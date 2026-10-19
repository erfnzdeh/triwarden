#!/usr/bin/env python3
"""README screenshots (docs/images) and store / promotion images (Design/Store) from the demo vault.

`make screenshots` runs `Triwarden --demo-full --shoot` in light and dark (each started just after a one-time
code period begins, so codes show full rings, not the orange last seconds), then:

  • docs/images/*.jpg     the README's pictures, cropped to the window, at the sizes the README lays out
  • Design/Store/*.png    1600×1200 promotion images: a headline over a soft gradient, the window below it
  • Design/Store/appearance.png   light and dark mode in one image: the vault split on a diagonal (also the README's
                                  docs/images/appearance.jpg)

`--only vault,search` keeps every other image as it is (the app still captures them all; only those are written).

Needs Pillow (`pip3 install pillow`) and the app built (`make build`).
"""
import base64
import os
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Build/Products/Debug/Triwarden.app/Contents/MacOS/Triwarden")
WORK = os.path.join(ROOT, "build/screenshots")

# Promotion images: the shot, and its headline.
STORE = {
    "vault": "Every login, card and passkey. Native on your Mac.",
    "search": "One search across every vault.",
    "codes": "Every one-time code, one click away.",
    "palette": "Press ⇧⌘Space. Find it, copy it, done.",
    "menubar": "Always there in the menu bar.",
    "watchtower": "Finds weak, reused and breached passwords.",
    "generator": "Strong passwords, passphrases and usernames.",
    "locked": "Locked tight. Only you hold the key.",
    "signin": "Your Vaultwarden, or Bitwarden. Signed in once.",
}
# README pictures: (shot, file, width). Light unless the shot name says dark.
README = [
    ("vault-light", "vault-light", 1640),
    ("search-light", "search", 1200),
    ("menubar-light", "menubar", 380),
    ("codes-light", "codes", 1200),
    ("watchtower-light", "watchtower", 1200),
    ("generator-light", "generator", 1200),
    ("palette-light", "palette", 1200),
    ("signin-light", "signin", 1200),
]
GRADIENT = {"light": ((214, 237, 253), (128, 197, 240)), "dark": ((18, 41, 61), (8, 18, 29))}
INK = {"light": (11, 42, 64), "dark": (255, 255, 255)}


def shoot(scheme):
    """One pass of the app's screenshot run, started just after a code period begins."""
    subprocess.run(["pkill", "-f", "Triwarden.app/Contents/MacOS/Triwarden --demo"], check=False)
    time.sleep(1)
    time.sleep((30 - time.time() % 30) % 30 + 0.5)
    # The app streams each shot as `SHOT <name> <base64>`: its sandbox container is closed to other apps.
    env = dict(os.environ, TRIWARDEN_SNAPSHOT_STDOUT="1")
    out = subprocess.run([APP, "--demo-full", "--shoot", "-appearance", scheme], capture_output=True, text=True, timeout=240, env=env)
    os.makedirs(WORK, exist_ok=True)
    shots = 0
    for line in out.stdout.splitlines():
        if line.startswith("SHOT "):
            _, name, data = line.split(" ", 2)
            with open(os.path.join(WORK, name), "wb") as f:
                f.write(base64.b64decode(data))
            shots += 1
    print(f"{scheme}: {shots} shots" if shots else out.stderr[-400:])


def window_only(image, dark):
    """The window without its shadow, on an opaque background (JPEG has no transparency)."""
    image = image.convert("RGBA")
    box = image.split()[3].point(lambda v: 255 if v >= 250 else 0).getbbox()
    image = image.crop(box)
    base = Image.new("RGBA", image.size, (30, 30, 32, 255) if dark else (255, 255, 255, 255))
    base.alpha_composite(image)
    return base.convert("RGB")


def wanted(shot):
    """Whether `--only` (comma-separated shot names, e.g. vault,search) includes this shot; everything without it."""
    if "--only" not in sys.argv:
        return True
    only = sys.argv[sys.argv.index("--only") + 1].split(",")
    return shot.rsplit("-", 1)[0] in only


def readme():
    for shot, name, width in README:
        if not wanted(shot):
            continue
        path = os.path.join(WORK, shot + ".png")
        if not os.path.exists(path):
            print("missing", shot); continue
        image = window_only(Image.open(path), "dark" in shot)
        image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
        image.save(os.path.join(ROOT, "docs/images", name + ".jpg"), quality=88)
        print("docs/images/%s.jpg" % name, image.size)


def headline_font(size):
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    font.set_variation_by_name("Bold")
    return font


def store(scheme):
    top, bottom = GRADIENT[scheme]
    for name, headline in STORE.items():
        if not wanted(f"{name}-{scheme}"):
            continue
        path = os.path.join(WORK, f"{name}-{scheme}.png")
        if not os.path.exists(path):
            print("missing", name, scheme); continue
        canvas = Image.new("RGBA", (1600, 1200))
        draw = ImageDraw.Draw(canvas)
        for y in range(1200):
            t = y / 1199
            draw.line([(0, y), (1600, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
        # The headline: bold, centred, no wider than the canvas allows.
        size = 54  # the original images: about 1200 px wide for the longest headline
        font = headline_font(size)
        while draw.textlength(headline, font=font) > 1300:
            size -= 2
            font = headline_font(size)
        draw.text((800, 95), headline, font=font, fill=INK[scheme], anchor="mm")
        # The window (with its own shadow), as large as fits under the headline.
        shot = Image.open(path).convert("RGBA")
        scale = min(1300 / shot.width, 1000 / shot.height)
        shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
        canvas.alpha_composite(shot, ((1600 - shot.width) // 2, 185))
        canvas.convert("RGB").save(os.path.join(ROOT, "Design/Store", f"{name}-{scheme}.png"))
        print("Design/Store/%s-%s.png" % (name, scheme))


def appearance():
    """Light and dark in one picture: the same vault in both, split on a diagonal that crosses the background too."""
    if not wanted("vault-light"):
        return
    light_path, dark_path = (os.path.join(WORK, f"vault-{s}.png") for s in ("light", "dark"))
    if not (os.path.exists(light_path) and os.path.exists(dark_path)):
        print("missing vault light/dark"); return
    W, H = 1600, 1200
    halves = {}
    for scheme in ("light", "dark"):
        top, bottom = GRADIENT[scheme]
        canvas = Image.new("RGBA", (W, H))
        draw = ImageDraw.Draw(canvas)
        for y in range(H):
            t = y / (H - 1)
            draw.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
        shot = Image.open(os.path.join(WORK, f"vault-{scheme}.png")).convert("RGBA")
        scale = min(1300 / shot.width, 1000 / shot.height)
        shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
        canvas.alpha_composite(shot, ((W - shot.width) // 2, 185))
        halves[scheme] = canvas
    # Dark below a line from just right of top centre to just left of bottom centre; light above it.
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon([(W * 0.62, 0), (W, 0), (W, H), (W * 0.38, H)], fill=255)
    out = Image.composite(halves["dark"], halves["light"], mask)
    draw = ImageDraw.Draw(out)
    # The seam: a thin bright line, so the split reads as deliberate.
    draw.line([(W * 0.62, 0), (W * 0.38, H)], fill=(255, 255, 255, 140), width=3)
    # The headline, each half in its own ink, so it stays legible over both backgrounds.
    headline = "Light and dark, of course."
    font = headline_font(54)
    text = Image.new("L", (W, H), 0)
    ImageDraw.Draw(text).text((W // 2, 95), headline, font=font, fill=255, anchor="mm")
    for scheme, region in (("light", Image.eval(mask, lambda v: 255 - v)), ("dark", mask)):
        ink = Image.new("RGBA", (W, H), INK[scheme] + (255,))
        out.paste(ink, (0, 0), Image.composite(text, Image.new("L", (W, H), 0), region))
    out = out.convert("RGB")
    out.save(os.path.join(ROOT, "Design/Store", "appearance.png"))
    out.resize((1200, 900), Image.LANCZOS).save(os.path.join(ROOT, "docs/images", "appearance.jpg"), quality=88)
    print("Design/Store/appearance.png, docs/images/appearance.jpg")


if __name__ == "__main__":
    if not os.path.exists(APP):
        sys.exit("Build the app first: make build")
    if "--no-shoot" not in sys.argv:
        for scheme in ("light", "dark"):
            shoot(scheme)
    readme()
    for scheme in ("light", "dark"):
        store(scheme)
    appearance()
