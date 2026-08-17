#!/usr/bin/env python3

"""Shared, original geometry for the Codex Export glider mark."""

from __future__ import annotations

from collections.abc import Iterable

from PIL import Image, ImageChops, ImageDraw, ImageFilter


DESIGN_BOX = (190.0, 292.0, 780.0, 748.0)
Point = tuple[float, float]
Cubic = tuple[Point, Point, Point]


# A compact, softly rounded folded-paper glider. The geometry is original and
# intentionally independent of the ChatGPT/OpenAI/Codex marks.
OUTER_START: Point = (770.0, 310.0)
OUTER_CURVES: tuple[Cubic, ...] = (
    ((700.0, 304.0), (500.0, 350.0), (300.0, 420.0)),
    ((235.0, 443.0), (198.0, 477.0), (203.0, 516.0)),
    ((208.0, 548.0), (244.0, 570.0), (291.0, 580.0)),
    ((320.0, 588.0), (345.0, 575.0), (360.0, 558.0)),
    ((380.0, 586.0), (383.0, 618.0), (395.0, 652.0)),
    ((402.0, 697.0), (429.0, 728.0), (462.0, 733.0)),
    ((501.0, 740.0), (534.0, 703.0), (568.0, 660.0)),
    ((642.0, 563.0), (709.0, 451.0), (756.0, 352.0)),
    ((767.0, 330.0), (773.0, 315.0), (770.0, 310.0)),
)

LOWER_START: Point = (360.0, 558.0)
LOWER_CURVES: tuple[Cubic, ...] = (
    ((380.0, 586.0), (383.0, 618.0), (395.0, 652.0)),
    ((402.0, 697.0), (429.0, 728.0), (462.0, 733.0)),
    ((501.0, 740.0), (534.0, 703.0), (568.0, 660.0)),
    ((642.0, 563.0), (709.0, 451.0), (756.0, 352.0)),
    ((767.0, 330.0), (773.0, 315.0), (770.0, 310.0)),
    ((650.0, 390.0), (500.0, 510.0), (360.0, 558.0)),
)

CREASE_START: Point = (360.0, 558.0)
CREASE_CURVES: tuple[Cubic, ...] = (
    ((490.0, 505.0), (630.0, 405.0), (748.0, 324.0)),
    ((640.0, 420.0), (500.0, 525.0), (382.0, 594.0)),
    ((374.0, 582.0), (366.0, 568.0), (360.0, 558.0)),
)


def _cubic_points(
    start: Point,
    control_1: Point,
    control_2: Point,
    end: Point,
    steps: int,
) -> Iterable[Point]:
    for index in range(1, steps + 1):
        t = index / steps
        inverse = 1.0 - t
        yield (
            inverse**3 * start[0]
            + 3.0 * inverse**2 * t * control_1[0]
            + 3.0 * inverse * t**2 * control_2[0]
            + t**3 * end[0],
            inverse**3 * start[1]
            + 3.0 * inverse**2 * t * control_1[1]
            + 3.0 * inverse * t**2 * control_2[1]
            + t**3 * end[1],
        )


def _sample_path(start: Point, curves: tuple[Cubic, ...]) -> list[Point]:
    points = [start]
    current = start
    for control_1, control_2, end in curves:
        points.extend(_cubic_points(current, control_1, control_2, end, 32))
        current = end
    return points


def _transform(
    point: Point,
    target_box: tuple[float, float, float, float],
    supersample: int,
) -> tuple[int, int]:
    source_left, source_top, source_right, source_bottom = DESIGN_BOX
    target_left, target_top, target_right, target_bottom = target_box
    x = target_left + (
        (point[0] - source_left)
        / (source_right - source_left)
        * (target_right - target_left)
    )
    y = target_top + (
        (point[1] - source_top)
        / (source_bottom - source_top)
        * (target_bottom - target_top)
    )
    return round(x * supersample), round(y * supersample)


def _draw_path(
    image: Image.Image,
    start: Point,
    curves: tuple[Cubic, ...],
    target_box: tuple[float, float, float, float],
    supersample: int,
) -> None:
    ImageDraw.Draw(image).polygon(
        [
            _transform(point, target_box, supersample)
            for point in _sample_path(start, curves)
        ],
        fill=255,
    )


def high_resolution_masks(
    size: int,
    target_box: tuple[float, float, float, float],
    *,
    supersample: int = 8,
    crease_outset: float = 0.0,
) -> tuple[Image.Image, Image.Image, Image.Image]:
    dimensions = (size * supersample, size * supersample)
    outer = Image.new("L", dimensions, 0)
    lower = Image.new("L", dimensions, 0)
    crease = Image.new("L", dimensions, 0)
    _draw_path(outer, OUTER_START, OUTER_CURVES, target_box, supersample)
    _draw_path(lower, LOWER_START, LOWER_CURVES, target_box, supersample)
    _draw_path(crease, CREASE_START, CREASE_CURVES, target_box, supersample)
    lower = ImageChops.multiply(lower, outer)
    crease = ImageChops.multiply(crease, outer)

    outset_pixels = round(crease_outset * supersample)
    if outset_pixels > 0:
        kernel = outset_pixels * 2 + 1
        if kernel % 2 == 0:
            kernel += 1
        crease = crease.filter(ImageFilter.MaxFilter(kernel))
        crease = ImageChops.multiply(crease, outer)
    return outer, lower, crease


def glider_masks(
    size: int,
    target_box: tuple[float, float, float, float],
    *,
    supersample: int = 8,
    crease_outset: float = 0.0,
) -> tuple[Image.Image, Image.Image, Image.Image]:
    outer, lower, crease = high_resolution_masks(
        size,
        target_box,
        supersample=supersample,
        crease_outset=crease_outset,
    )
    return tuple(
        mask.resize((size, size), Image.Resampling.LANCZOS)
        for mask in (outer, lower, crease)
    )


def status_alpha(
    size: int,
    target_box: tuple[float, float, float, float],
    *,
    crease_outset: float,
) -> Image.Image:
    supersample = 16
    outer, _, crease = high_resolution_masks(
        size,
        target_box,
        supersample=supersample,
        crease_outset=crease_outset,
    )
    alpha = ImageChops.subtract(outer, crease).resize(
        (size, size),
        Image.Resampling.LANCZOS,
    )
    return alpha.point(lambda value: 0 if value < 10 else value)
