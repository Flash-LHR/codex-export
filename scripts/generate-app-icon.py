#!/usr/bin/env python3

"""Generate the original Codex Export glider application icon."""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

from icon_geometry import glider_masks


CANVAS_SIZE = 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "Resources",
    )
    return parser.parse_args()


def rounded_rectangle_mask(
    size: int,
    box: tuple[float, float, float, float],
    radius: float,
    *,
    supersample: int = 8,
) -> Image.Image:
    high = Image.new("L", (size * supersample, size * supersample), 0)
    ImageDraw.Draw(high).rounded_rectangle(
        tuple(round(value * supersample) for value in box),
        radius=round(radius * supersample),
        fill=255,
    )
    return high.resize((size, size), Image.Resampling.LANCZOS)


def vertical_gradient(
    size: int,
    top: tuple[int, int, int, int],
    bottom: tuple[int, int, int, int],
    *,
    start_y: float = 0.0,
    end_y: float | None = None,
) -> Image.Image:
    image = Image.new("RGBA", (1, size))
    pixels = image.load()
    gradient_end = float(size - 1) if end_y is None else end_y
    denominator = max(1.0, gradient_end - start_y)
    for y in range(size):
        amount = min(1.0, max(0.0, (y - start_y) / denominator))
        color = tuple(
            round(top[index] * (1.0 - amount) + bottom[index] * amount)
            for index in range(4)
        )
        pixels[0, y] = color
    return image.resize((size, size), Image.Resampling.NEAREST)


def paste_layer(canvas: Image.Image, layer: Image.Image, mask: Image.Image) -> None:
    copy = layer.copy()
    copy.putalpha(mask)
    canvas.alpha_composite(copy)


def icon_metrics(
    size: int,
    logical_size: int,
) -> tuple[
    tuple[float, float, float, float],
    float,
    tuple[float, float, float, float],
    float,
]:
    representation_scale = size / logical_size
    if logical_size == 16:
        return (
            tuple(value * representation_scale for value in (1.5, 1.5, 14.5, 14.5)),
            3.6 * representation_scale,
            tuple(value * representation_scale for value in (2.5, 4.5, 14.0, 14.0)),
            0.30 * representation_scale,
        )
    if logical_size == 32:
        return (
            tuple(value * representation_scale for value in (2.5, 2.5, 29.5, 29.5)),
            6.9 * representation_scale,
            tuple(value * representation_scale for value in (6.0, 9.0, 27.0, 26.0)),
            0.42 * representation_scale,
        )
    scale = size / CANVAS_SIZE
    return (
        tuple(value * scale for value in (96.0, 96.0, 928.0, 928.0)),
        198.0 * scale,
        tuple(value * scale for value in (226.0, 330.0, 824.0, 812.0)),
        0.0,
    )


def render_icon(size: int, logical_size: int) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile_box, tile_radius, mark_box, crease_outset = icon_metrics(
        size,
        logical_size,
    )
    tile = rounded_rectangle_mask(size, tile_box, tile_radius)

    if size >= 64:
        shadow_offset = max(1, round(size * 12 / CANVAS_SIZE))
        shadow = tile.filter(
            ImageFilter.GaussianBlur(max(1.0, size * 20 / CANVAS_SIZE))
        )
        shifted = Image.new("L", (size, size), 0)
        shifted.paste(shadow, (0, shadow_offset))
        shadow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 28))
        paste_layer(canvas, shadow_layer, shifted)

    tile_gradient = vertical_gradient(
        size,
        (248, 247, 245, 255),
        (243, 241, 239, 255),
    )
    paste_layer(canvas, tile_gradient, tile)

    outer, lower, crease = glider_masks(
        size,
        mark_box,
        supersample=4 if size >= 128 else 8,
        crease_outset=crease_outset,
    )

    if size >= 64:
        plane_shadow = outer.filter(
            ImageFilter.GaussianBlur(max(0.8, size * 11 / CANVAS_SIZE))
        )
        shifted = Image.new("L", (size, size), 0)
        shifted.paste(plane_shadow, (0, max(1, round(size * 7 / CANVAS_SIZE))))
        shadow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 22))
        paste_layer(canvas, shadow_layer, shifted)

    graphite = vertical_gradient(
        size,
        (75, 78, 82, 255),
        (40, 42, 46, 255),
        start_y=mark_box[1],
        end_y=mark_box[3],
    )
    accent = vertical_gradient(
        size,
        (59, 44, 225, 255),
        (79, 160, 254, 255),
        start_y=mark_box[1],
        end_y=mark_box[3],
    )
    paste_layer(canvas, graphite, outer)
    paste_layer(canvas, accent, lower)

    seam = Image.new("RGBA", (size, size), (247, 246, 243, 255))
    paste_layer(canvas, seam, crease)
    return canvas


def save_iconset(iconset: Path) -> None:
    iconset.mkdir(parents=True, exist_ok=True)
    cache: dict[tuple[int, int], Image.Image] = {}

    def icon(size: int, logical_size: int) -> Image.Image:
        key = (size, logical_size)
        if key not in cache:
            cache[key] = render_icon(size, logical_size)
        return cache[key]

    representations = {
        "icon_16x16.png": icon(16, 16),
        "icon_16x16@2x.png": icon(32, 16),
        "icon_32x32.png": icon(32, 32),
        "icon_32x32@2x.png": icon(64, 32),
        "icon_128x128.png": icon(128, 128),
        "icon_128x128@2x.png": icon(256, 128),
        "icon_256x256.png": icon(256, 256),
        "icon_256x256@2x.png": icon(512, 256),
        "icon_512x512.png": icon(512, 512),
        "icon_512x512@2x.png": icon(1024, 512),
    }
    for name, image in representations.items():
        image.save(iconset / name, optimize=True)


def main() -> None:
    args = parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    render_icon(CANVAS_SIZE, 512).save(output / "AppIcon.png", optimize=True)
    with tempfile.TemporaryDirectory(prefix="codex-export-app-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        save_iconset(iconset)
        subprocess.run(
            [
                "iconutil",
                "-c",
                "icns",
                str(iconset),
                "-o",
                str(output / "AppIcon.icns"),
            ],
            check=True,
        )


if __name__ == "__main__":
    main()
