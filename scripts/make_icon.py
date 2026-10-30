#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""
Generate the macOS app icon and menu-bar template from WeChat.png.

WeChat.png is the user-provided source logo: black artwork on a white square.
The README wordmark (Github_readmeTop_EWC.png) is used as-is and is NOT
processed by this script.

Requires Pillow: python3 -m pip install pillow
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_LOGO = os.path.join(ROOT, "WeChat.png")
APP_RES = os.path.join(ROOT, "app", "Resources")
SWIFT_RES = os.path.join(ROOT, "app", "Sources", "ExtraWeChat", "Resources")


def white_logo() -> Image.Image:
    """Turn black-on-white artwork into white-on-transparent artwork."""
    src = Image.open(SOURCE_LOGO).convert("RGB")
    alpha = Image.eval(src.convert("L"), lambda v: 255 - v)
    out = Image.new("RGBA", src.size, (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def gradient(size: int) -> Image.Image:
    top = (76, 140, 255)
    bottom = (30, 204, 194)
    base = Image.new("RGB", (size, size))
    px = base.load()
    for y in range(size):
        t = y / (size - 1)
        for x in range(size):
            u = x / (size - 1)
            tt = min(1.0, max(0.0, 0.72 * t + 0.28 * (1 - u)))
            px[x, y] = (
                int(top[0] * (1 - tt) + bottom[0] * tt),
                int(top[1] * (1 - tt) + bottom[1] * tt),
                int(top[2] * (1 - tt) + bottom[2] * tt),
            )
    return base


def make_app_icon(logo: Image.Image) -> None:
    size = 1024
    inset = 38
    radius = 210
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size - inset - 1, size - inset - 1),
        radius=radius,
        fill=255,
    )
    canvas.paste(gradient(size).convert("RGBA"), (0, 0), mask)

    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(highlight).ellipse((-140, 610, 900, 1250), fill=(255, 255, 255, 26))
    highlight = highlight.filter(ImageFilter.GaussianBlur(60))
    canvas = Image.alpha_composite(
        canvas,
        Image.composite(highlight, Image.new("RGBA", (size, size), (0, 0, 0, 0)), mask),
    )

    target = int(size * 0.64)
    scaled = logo.resize((target, target), Image.LANCZOS)
    canvas.alpha_composite(scaled, ((size - target) // 2, (size - target) // 2 + 10))

    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (inset, inset, size - inset - 1, size - inset - 1),
        radius=radius,
        outline=(255, 255, 255, 42),
        width=8,
    )
    canvas.alpha_composite(border)

    os.makedirs(APP_RES, exist_ok=True)
    canvas.save(os.path.join(APP_RES, "AppIcon-1024.png"))


def make_menu_bar_icon(logo: Image.Image) -> None:
    os.makedirs(SWIFT_RES, exist_ok=True)
    logo.resize((72, 72), Image.LANCZOS).save(os.path.join(SWIFT_RES, "MenuBarIcon.png"))


def main() -> None:
    logo = white_logo()
    make_app_icon(logo)
    make_menu_bar_icon(logo)
    print("updated AppIcon-1024.png and MenuBarIcon.png")


if __name__ == "__main__":
    main()
