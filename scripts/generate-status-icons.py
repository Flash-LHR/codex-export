#!/usr/bin/env python3

"""Generate 18pt template masters for the original glider status icon."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

from icon_geometry import status_alpha


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "Resources"
        / "Assets.xcassets",
    )
    return parser.parse_args()


def optical_metrics(
    size: int,
) -> tuple[tuple[float, float, float, float], float]:
    if size == 18:
        return (0.8, 2.2, 17.2, 15.9), 0.38
    if size == 36:
        return (1.7, 4.1, 34.3, 31.9), 0.62
    raise ValueError(f"Missing status-icon metrics for {size}px")


def render(size: int) -> Image.Image:
    box, crease_outset = optical_metrics(size)
    alpha = status_alpha(size, box, crease_outset=crease_outset)
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    image.putalpha(alpha)
    return image


def main() -> None:
    args = parse_args()
    output = args.output / "StatusIcon.imageset"
    output.mkdir(parents=True, exist_ok=True)
    render(18).save(output / "StatusIcon.png", optimize=True)
    render(36).save(output / "StatusIcon@2x.png", optimize=True)


if __name__ == "__main__":
    main()
