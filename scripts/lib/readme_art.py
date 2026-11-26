"""Agello's branded README art, drawn as deterministic SVG.

Every image in the README is a self-contained vector card on Agello's deep-navy
canvas (identical in GitHub's light and dark themes, matching the app's forced
dark palette in Agello/Support/Theme/). Every wide card (880 px) has a dedicated
mobile twin (400 px, *-narrow.svg) switched via <picture> so text stays native-size
on phones instead of shrinking.

Output rules: Python stdlib only, no scripts, no external fonts or external URLs,
fixed float formatting so rebuilds are byte-identical, and accessible <title> +
<desc> metadata on every card.
"""

from __future__ import annotations

import base64
import math
from dataclasses import dataclass
from pathlib import Path
from xml.sax.saxutils import escape

# --- Agello design tokens (Agello/Support/Theme/) --------------------------

CANVAS = "#161823"
CARD = "#1C1E26"
DEEP = "#0C0E14"
RAISED = "#232632"
FIELD = "#2F3342"
TEXT = "#F2F0EB"
SECONDARY = "#C7C2B8"
MUTED = "#948F84"

GLACIER = "#8AB0C8"    # Chat, Metal 4 GPU
LAVENDER = "#BFAADC"   # Think, reasoning & agent runtime
TEAL = "#8CC7BF"       # Search, 16-Core Apple Neural Engine
GOLD = "#EDCC8A"       # Voice, GPU Neural Accelerators
SILVER = "#ADB5C2"     # Neutral chrome

BAR_COLORS = {
    "rewrite": "#C89B42",
    "chat": "#5B8AAD",
    "file": "#529B91",
    "think": "#8F76B8",
}

MODES = ("chat", "think", "search", "voice")
MODE_COLORS = {"chat": GLACIER, "think": LAVENDER, "search": TEAL, "voice": GOLD}
MODE_NAMES = {"chat": "Chat", "think": "Think", "search": "Search", "voice": "Voice"}

DISPLAY = "ui-rounded, 'SF Pro Rounded', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
BODY = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"

WIDE = 880
NARROW = 400

APP_ICON = Path("docs/images/icon.png")

# 24-unit stroke icons, round caps and joins.
ICONS = {
    "chat": (
        '<path d="M5 6.5h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H10l-4.5 3v-3H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2z"/>'
        '<path d="M8 11h8M8 14h5"/>'
    ),
    "think": (
        '<path d="M9.5 18h5M10.2 21h3.6"/>'
        '<path d="M8.8 14.6A5.5 5.5 0 1 1 15.2 14.6c-.7.6-1.2 1.4-1.2 2.4h-4c0-1-.5-1.8-1.2-2.4z"/>'
    ),
    "search": (
        '<circle cx="12" cy="12" r="8.5"/><path d="M3.6 12h16.8"/>'
        '<path d="M12 3.5c2.5 2.4 3.8 5.2 3.8 8.5s-1.3 6.1-3.8 8.5c-2.5-2.4-3.8-5.2-3.8-8.5s1.3-6.1 3.8-8.5z"/>'
    ),
    "voice": (
        '<path d="M4.5 12v0M8 8.5v7M12 5v14M16 8.5v7M19.5 10.5v3"/>'
    ),
    "doc": (
        '<rect x="5" y="3" width="14" height="18" rx="2.5"/>'
        '<path d="M8.5 8h7M8.5 11.5h7M8.5 15h4.5"/>'
    ),
    "camera": (
        '<rect x="3.5" y="6.5" width="17" height="12.5" rx="2.5"/>'
        '<path d="M8.5 6.5l1.4-2h4.2l1.4 2"/><circle cx="12" cy="12.8" r="3.2"/>'
    ),
    "branch": (
        '<circle cx="7" cy="6" r="2.2"/><circle cx="7" cy="18" r="2.2"/><circle cx="17" cy="12" r="2.2"/>'
        '<path d="M7 8.2v7.6M9.2 6.8c3 0 3.5 5.2 5.6 5.2"/>'
    ),
    "calendar": (
        '<rect x="4" y="5.5" width="16" height="14.5" rx="2.5"/>'
        '<path d="M8 3.5v4M16 3.5v4M4 10h16"/><path d="M9.5 14.5l2 2 3.5-3.5"/>'
    ),
    "memory": (
        '<path d="M12 3.8l2.1 4.6 5 .6-3.7 3.4.9 5-4.3-2.4-4.3 2.4.9-5L4.9 9l5-.6z"/>'
    ),
    "spark": (
        '<path d="M12 3.5l1.9 5.6 5.6 1.9-5.6 1.9L12 18.5l-1.9-5.6-5.6-1.9 5.6-1.9z"/>'
        '<path d="M18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/>'
    ),
    "lock": (
        '<rect x="5.5" y="10.5" width="13" height="9.5" rx="2.3"/>'
        '<path d="M8.5 10.5V7.8a3.5 3.5 0 0 1 7 0v2.7"/><path d="M12 14.2v2.4"/>'
    ),
    "phone": (
        '<rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M11 18h2"/>'
    ),
    "chip": (
        '<rect x="6" y="6" width="12" height="12" rx="2.4"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/>'
        '<path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/>'
    ),
    "ane": (
        '<circle cx="5.5" cy="7.5" r="2"/><circle cx="5.5" cy="16.5" r="2"/>'
        '<circle cx="12" cy="12" r="2.4"/>'
        '<circle cx="18.5" cy="7.5" r="2"/><circle cx="18.5" cy="16.5" r="2"/>'
        '<path d="M7.3 8.7l2.8 2M7.3 15.3l2.8-2M13.9 10.7l2.8-2M13.9 13.3l2.8 2"/>'
    ),
}


@dataclass(frozen=True)
class Measured:
    """Verified physical iPhone 17 Pro Release & device-suite measurements."""

    hardware: str                 # "iPhone 17 Pro · Apple A19 Pro, 12 GB"
    os_version: str               # "iOS 27.2.1"
    runtime_tag: str              # "agello-one-20261124"
    runtime_build: str            # "8a7e34594612"
    prefill_peak_tok_s: int       # 1668
    decode_low_tok_s: int         # 52
    decode_high_tok_s: int        # 84
    ane_pdf_seconds: float        # 0.86
    chat_peak_gb: str             # "1.5–1.7 GB"
    full_64k_gb: str              # "3.2–3.5 GB"
    undisturbed_runs: str         # "23/24 undisturbed"
    decode_bars: tuple[tuple[str, str, float, str, str], ...]
    # (key, label, tok_s, note, mode_key)
    stock_32k_tok_s: float        # 27.0


# --- SVG primitives --------------------------------------------------------

def num(value: float) -> str:
    text_val = f"{value:.2f}".rstrip("0").rstrip(".")
    return "0" if text_val in ("-0", "") else text_val


def text_width(value: str, size: float, *, bold: bool = False) -> float:
    narrow = sum(value.count(c) for c in "ilI.,:;'|!·()[]/ ")
    wide = sum(value.count(c) for c in "MWmw@—%")
    regular = len(value) - narrow - wide
    unit = 0.58 if bold else 0.54
    return size * (regular * unit + narrow * 0.30 + wide * 0.84)


def text(x: float, y: float, value: str, *, size: float, fill: str = TEXT, weight: int = 400,
         family: str = BODY, anchor: str = "start", opacity: float | None = None,
         spacing: float | None = None) -> str:
    attrs = [
        f'x="{num(x)}"', f'y="{num(y)}"', f'font-family="{family}"',
        f'font-size="{num(size)}"', f'font-weight="{weight}"', f'fill="{fill}"',
    ]
    if anchor != "start":
        attrs.append(f'text-anchor="{anchor}"')
    if opacity is not None:
        attrs.append(f'fill-opacity="{num(opacity)}"')
    if spacing is not None:
        attrs.append(f'letter-spacing="{num(spacing)}"')
    return f"<text {' '.join(attrs)}>{escape(value)}</text>"


def icon(name: str, x: float, y: float, *, color: str, size: float = 24, width: float = 1.85) -> str:
    scale = size / 24
    return (
        f'<g transform="translate({num(x)} {num(y)}) scale({num(scale)})" fill="none" stroke="{color}" '
        f'stroke-width="{num(width)}" stroke-linecap="round" stroke-linejoin="round">{ICONS[name]}</g>'
    )


def icon_tile(name: str, x: float, y: float, *, color: str, size: float = 44) -> str:
    inner = size * 0.55
    offset = (size - inner) / 2
    return (
        f'<rect x="{num(x)}" y="{num(y)}" width="{num(size)}" height="{num(size)}" rx="{num(size * 0.27)}" '
        f'fill="{color}" fill-opacity="0.13" stroke="{color}" stroke-opacity="0.38"/>'
        + icon(name, x + offset, y + offset, color=color, size=inner)
    )


def pill(x: float, y: float, label: str, color: str, *, size: float = 14, height: float = 34) -> tuple[str, float]:
    width = text_width(label, size, bold=True) + 42
    markup = (
        f'<rect x="{num(x)}" y="{num(y)}" width="{num(width)}" height="{num(height)}" rx="{num(height / 2)}" '
        f'fill="{color}" fill-opacity="0.13" stroke="{color}" stroke-opacity="0.42"/>'
        f'<circle cx="{num(x + 17)}" cy="{num(y + height / 2)}" r="4.2" fill="{color}"/>'
        + text(x + 29, y + height / 2 + size * 0.35, label, size=size, fill=color, weight=600)
    )
    return markup, width


def card(width: float, height: float, *, glows: tuple[tuple[float, float, float, str, float], ...] = ()) -> tuple[str, str]:
    defs = [
        f'<linearGradient id="canvas" x1="0" y1="0" x2="0.85" y2="1">'
        f'<stop offset="0" stop-color="{CANVAS}"/><stop offset="0.45" stop-color="{CARD}"/>'
        f'<stop offset="1" stop-color="{DEEP}"/></linearGradient>'
    ]
    bg = [f'<rect width="{num(width)}" height="{num(height)}" rx="24" fill="url(#canvas)"/>']
    for idx, (cx, cy, radius, color, opacity) in enumerate(glows):
        defs.append(
            f'<radialGradient id="glow{idx}" cx="{num(cx)}" cy="{num(cy)}" r="{num(radius)}" '
            f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{color}" stop-opacity="{num(opacity)}"/>'
            f'<stop offset="1" stop-color="{color}" stop-opacity="0"/></radialGradient>'
        )
        bg.append(f'<rect width="{num(width)}" height="{num(height)}" rx="24" fill="url(#glow{idx})"/>')
    bg.append(
        f'<rect x="0.5" y="0.5" width="{num(width - 1)}" height="{num(height - 1)}" rx="23.5" '
        f'fill="none" stroke="#F7EBD1" stroke-opacity="0.10"/>'
    )
    return "".join(defs), "".join(bg)


def svg(width: float, height: float, title: str, description: str, body: list[str], defs: str = "") -> str:
    head = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{num(width)}" height="{num(height)}" '
        f'viewBox="0 0 {num(width)} {num(height)}" role="img" aria-labelledby="title desc">'
    )
    parts = [head, f'<title id="title">{escape(title)}</title>', f'<desc id="desc">{escape(description)}</desc>']
    if defs:
        parts.append(f"<defs>{defs}</defs>")
    parts.extend(body)
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def wrap(value: str, size: float, width: float, *, bold: bool = False) -> list[str]:
    lines: list[str] = []
    current = ""
    for word in value.split():
        candidate = f"{current} {word}".strip()
        if current and text_width(candidate, size, bold=bold) > width:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def paragraph(x: float, y: float, value: str, *, size: float, width: float, leading: float,
              fill: str = SECONDARY, anchor: str = "start", weight: int = 400) -> tuple[str, float]:
    lines = wrap(value, size, width, bold=weight >= 600)
    markup = "".join(
        text(x, y + idx * leading, line, size=size, fill=fill, anchor=anchor, weight=weight)
        for idx, line in enumerate(lines)
    )
    return markup, y + (len(lines) - 1) * leading


def _box(x: float, y: float, w: float, h: float, *, stroke: str = "#F7EBD1", opacity: float = 0.10,
         fill: str = RAISED, fill_opacity: float = 0.72, radius: float = 14) -> str:
    return (
        f'<rect x="{num(x)}" y="{num(y)}" width="{num(w)}" height="{num(h)}" rx="{num(radius)}" '
        f'fill="{fill}" fill-opacity="{num(fill_opacity)}" stroke="{stroke}" stroke-opacity="{num(opacity)}"/>'
    )


def _arrow(x1: float, y1: float, x2: float, y2: float, *, color: str = MUTED) -> str:
    return (
        f'<path d="M{num(x1)} {num(y1)} L{num(x2)} {num(y2)}" stroke="{color}" stroke-width="1.6" '
        f'fill="none" marker-end="url(#arrow)"/>'
    )


ARROW_MARKER = (
    f'<marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" '
    f'orient="auto-start-reverse"><path d="M1 1L9 5L1 9" fill="none" stroke="{MUTED}" '
    f'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></marker>'
)


def _app_icon(root: Path, x: float, y: float, size: float, clip_id: str = "iconclip") -> tuple[str, str]:
    data = base64.b64encode((root / APP_ICON).read_bytes()).decode("ascii")
    rx = size * 0.225
    defs = f'<clipPath id="{clip_id}"><rect x="{num(x)}" y="{num(y)}" width="{num(size)}" height="{num(size)}" rx="{num(rx)}"/></clipPath>'
    markup = (
        f'<image x="{num(x)}" y="{num(y)}" width="{num(size)}" height="{num(size)}" '
        f'clip-path="url(#{clip_id})" href="data:image/png;base64,{data}"/>'
        f'<rect x="{num(x)}" y="{num(y)}" width="{num(size)}" height="{num(size)}" rx="{num(rx)}" '
        f'fill="none" stroke="#F7EBD1" stroke-opacity="0.18"/>'
    )
    return defs, markup


def _neural_motif(cx: float, cy: float, *, compact: bool = False) -> tuple[str, str]:
    """Agello's four-mode luminous orb & harmonic wave motif."""
    r_core = 30 if compact else 44
    r_mid = 52 if compact else 76
    r_outer = 74 if compact else 108
    defs = (
        f'<radialGradient id="orbCore" cx="{num(cx - r_core * 0.28)}" cy="{num(cy - r_core * 0.30)}" '
        f'r="{num(r_core * 1.35)}" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="#FFF8E8"/><stop offset="0.45" stop-color="{GOLD}"/>'
        f'<stop offset="0.82" stop-color="#9A7840"/><stop offset="1" stop-color="#3B3122"/></radialGradient>'
        f'<radialGradient id="orbHalo" cx="{num(cx)}" cy="{num(cy)}" r="{num(r_outer * 1.15)}" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{GOLD}" stop-opacity="0.28"/>'
        f'<stop offset="0.55" stop-color="{GLACIER}" stop-opacity="0.14"/>'
        f'<stop offset="1" stop-color="{LAVENDER}" stop-opacity="0"/></radialGradient>'
        f'<linearGradient id="ringGrad" x1="{num(cx - r_outer)}" y1="{num(cy - r_outer)}" '
        f'x2="{num(cx + r_outer)}" y2="{num(cy + r_outer)}" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{GLACIER}"/><stop offset="0.35" stop-color="{LAVENDER}"/>'
        f'<stop offset="0.7" stop-color="{TEAL}"/><stop offset="1" stop-color="{GOLD}"/></linearGradient>'
    )
    parts = [
        f'<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r_outer * 1.12)}" fill="url(#orbHalo)"/>',
        f'<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r_outer)}" fill="none" stroke="url(#ringGrad)" stroke-opacity="0.32" stroke-width="1.4" stroke-dasharray="5 6"/>',
        f'<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r_mid)}" fill="none" stroke="url(#ringGrad)" stroke-opacity="0.52" stroke-width="1.6"/>',
        f'<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r_core)}" fill="url(#orbCore)"/>',
        f'<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r_core)}" fill="none" stroke="#FFF4DA" stroke-opacity="0.35"/>',
    ]
    # Four orbital nodes in the four mode accents.
    angles = ((-0.75 * math.pi, GLACIER), (-0.22 * math.pi, LAVENDER), (0.25 * math.pi, GOLD), (0.78 * math.pi, TEAL))
    for idx, (ang, col) in enumerate(angles):
        r_ring = r_mid if idx % 2 == 0 else r_outer
        nx = cx + r_ring * math.cos(ang)
        ny = cy + r_ring * math.sin(ang)
        parts.append(f'<circle cx="{num(nx)}" cy="{num(ny)}" r="6.5" fill="{col}" fill-opacity="0.24"/>')
        parts.append(f'<circle cx="{num(nx)}" cy="{num(ny)}" r="3.4" fill="{col}"/>')
    return defs, "".join(parts)


def _pulse_bars(x: float, y: float, width: float, height: float, *, bars: int, grad_id: str) -> tuple[str, str]:
    defs = (
        f'<linearGradient id="{grad_id}" x1="{num(x)}" y1="0" x2="{num(x + width)}" y2="0" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{GLACIER}"/><stop offset="0.34" stop-color="{LAVENDER}"/>'
        f'<stop offset="0.67" stop-color="{TEAL}"/><stop offset="1" stop-color="{GOLD}"/></linearGradient>'
    )
    step = width / bars
    bw = step * 0.52
    parts = []
    for idx in range(bars):
        t = idx / (bars - 1)
        env = 0.20 + 0.80 * (0.58 * math.sin(math.pi * t) ** 1.4 + 0.42 * abs(math.sin(2.8 * math.pi * t)) ** 1.8)
        h = max(bw, height * min(1.0, env))
        bx = x + idx * step + (step - bw) / 2
        parts.append(
            f'<rect x="{num(bx)}" y="{num(y + (height - h) / 2)}" width="{num(bw)}" height="{num(h)}" '
            f'rx="{num(bw / 2)}" fill="url(#{grad_id})" fill-opacity="0.88"/>'
        )
    return defs, "".join(parts)


# --- 1. Hero ---------------------------------------------------------------

TAGLINE = ("Your own AI assistant,", "entirely on your iPhone.")
HERO_COPY = (
    "Chat, reason, read long PDFs, search the web, take actions, and talk hands-free with Gemma 4 "
    "— right on your Apple Silicon, with no account and no cloud."
)


def hero(root: Path) -> str:
    width, height = WIDE, 384
    defs, bg = card(
        width, height,
        glows=(
            (110, 40, 420, GLACIER, 0.20),
            (720, 90, 340, LAVENDER, 0.15),
            (760, 330, 300, GOLD, 0.15),
            (580, 260, 260, TEAL, 0.12),
        ),
    )
    icon_defs, icon_svg = _app_icon(root, 48, 38, 68)
    orb_defs, orb_svg = _neural_motif(694, 158, compact=False)
    pulse_defs, pulse_svg = _pulse_bars(578, 286, 232, 34, bars=26, grad_id="heropulse")
    defs += icon_defs + orb_defs + pulse_defs

    body = [
        bg,
        icon_svg,
        text(134, 92, "Agello", size=54, weight=700, family=DISPLAY),
        text(48, 162, TAGLINE[0], size=33, weight=600, family=DISPLAY),
        text(48, 201, TAGLINE[1], size=33, weight=600, family=DISPLAY, fill=GLACIER),
    ]
    copy_svg, after = paragraph(48, 236, HERO_COPY, size=15.5, width=448, leading=22.5)
    body.append(copy_svg)

    px = 48.0
    for mode in MODES:
        p_svg, pw = pill(px, after + 24, MODE_NAMES[mode], MODE_COLORS[mode], size=14, height=34)
        body.append(p_svg)
        px += pw + 10

    # Right showcase stage
    body.append(_box(544, 34, 300, 316, stroke=GLACIER, opacity=0.22, fill=DEEP, fill_opacity=0.58, radius=22))
    body.append(orb_svg)
    body.append(pulse_svg)
    body.append(text(694, 336, "Gemma 4 E4B · 64K · Apple Silicon", size=12, fill=MUTED, weight=600, anchor="middle"))

    return svg(
        width, height,
        "Agello: your own AI assistant, entirely on your iPhone",
        "The Agello app icon and wordmark beside a luminous four-mode orb, with the tagline Your own AI assistant, "
        "entirely on your iPhone, and four modes: Chat, Think, Search and Voice.",
        body, defs,
    )


def hero_narrow(root: Path) -> str:
    width = NARROW
    icon_defs, icon_svg = _app_icon(root, 108, 28, 54, clip_id="iconclipn")

    body = [
        icon_svg,
        text(176, 69, "Agello", size=42, weight=700, family=DISPLAY),
        text(width / 2, 126, TAGLINE[0], size=26.5, weight=600, family=DISPLAY, anchor="middle"),
        text(width / 2, 159, TAGLINE[1], size=26.5, weight=600, family=DISPLAY, fill=GLACIER, anchor="middle"),
    ]
    copy_svg, after_copy = paragraph(width / 2, 192, HERO_COPY, size=14.5, width=336, leading=21, anchor="middle")
    body.append(copy_svg)

    stage_y = after_copy + 20
    orb_defs, orb_svg = _neural_motif(width / 2, stage_y + 82, compact=True)
    pulse_defs, pulse_svg = _pulse_bars(64, stage_y + 166, width - 128, 26, bars=22, grad_id="heropulsen")
    body.append(_box(32, stage_y, width - 64, 206, stroke=GLACIER, opacity=0.20, fill=DEEP, fill_opacity=0.55, radius=20))
    body.append(orb_svg)
    body.append(pulse_svg)

    # 2x2 grid of mode pills
    rows = (("chat", "think"), ("search", "voice"))
    py = stage_y + 224
    for left_m, right_m in rows:
        w1 = text_width(MODE_NAMES[left_m], 14, bold=True) + 42
        w2 = text_width(MODE_NAMES[right_m], 14, bold=True) + 42
        total = w1 + 10 + w2
        sx = (width - total) / 2
        p1, _ = pill(sx, py, MODE_NAMES[left_m], MODE_COLORS[left_m], size=14, height=34)
        p2, _ = pill(sx + w1 + 10, py, MODE_NAMES[right_m], MODE_COLORS[right_m], size=14, height=34)
        body.extend((p1, p2))
        py += 44

    height = py + 16
    defs, bg = card(
        width, height,
        glows=(
            (60, 30, 280, GLACIER, 0.22),
            (350, 280, 250, LAVENDER, 0.16),
            (200, height, 260, GOLD, 0.14),
        ),
    )
    defs += icon_defs + orb_defs + pulse_defs
    return svg(
        width, height,
        "Agello: your own AI assistant, entirely on your iPhone",
        "The Agello icon and wordmark, tagline, luminous four-mode orb, and Chat, Think, Search and Voice pills.",
        [bg, *body], defs,
    )


# --- 2. Modes --------------------------------------------------------------

MODE_CARDS = (
    ("chat", "chat", "Write, code, translate, and brainstorm with rich Markdown, tables, and typeset math.", "Offline · 13+ languages"),
    ("think", "think", "Step-by-step reasoning in a collapsible card, calling tools when precision matters.", "Visible reasoning"),
    ("search", "search", "Checks open, key-free sources for live facts and backs every claim with citations.", "Numbered citations"),
    ("voice", "voice", "Hands-free spoken chats with live captions, optional camera, and instant barge-in.", "Interrupt anytime"),
)


def _mode_card(x: float, y: float, w: float, h: float, mode: str, glyph: str, line: str, tag: str,
               *, compact: bool = False) -> str:
    color = MODE_COLORS[mode]
    parts = [
        f'<rect x="{num(x)}" y="{num(y)}" width="{num(w)}" height="{num(h)}" rx="18" fill="{RAISED}" '
        f'fill-opacity="0.74" stroke="{color}" stroke-opacity="0.34"/>',
        f'<rect x="{num(x + 22)}" y="{num(y)}" width="{num(w - 44)}" height="3" rx="1.5" fill="{color}"/>',
    ]
    if compact:
        parts.append(icon_tile(glyph, x + 18, y + 20, color=color, size=42))
        parts.append(text(x + 74, y + 41, MODE_NAMES[mode], size=19, weight=600, family=DISPLAY))
        parts.append(text(x + 74, y + 60, tag, size=12.5, fill=color, weight=600))
        markup, _ = paragraph(x + 18, y + 90, line, size=14, width=w - 36, leading=20)
        parts.append(markup)
    else:
        parts.append(icon_tile(glyph, x + 18, y + 24, color=color, size=44))
        parts.append(text(x + 18, y + 98, MODE_NAMES[mode], size=20, weight=600, family=DISPLAY))
        markup, _ = paragraph(x + 18, y + 126, line, size=13.5, width=w - 36, leading=19.5)
        parts.append(markup)
        parts.append(text(x + 18, y + h - 20, tag, size=12, fill=color, weight=600))
    return "".join(parts)


def modes() -> str:
    width, height = WIDE, 292
    defs, bg = card(width, height, glows=((160, 0, 380, GLACIER, 0.09), (720, 292, 380, GOLD, 0.08)))
    body = [bg]
    margin, gap = 24.0, 12.0
    w = (width - margin * 2 - gap * 3) / 4
    for idx, (mode, glyph, line, tag) in enumerate(MODE_CARDS):
        body.append(_mode_card(margin + idx * (w + gap), 24, w, 244, mode, glyph, line, tag))
    return svg(
        width, height,
        "Four modes, one assistant",
        "Chat in glacier, Think in lavender, Search in teal, and Voice in gold.",
        body, defs,
    )


def modes_narrow() -> str:
    width, card_h, gap, margin = NARROW, 140.0, 14.0, 22.0
    height = margin * 2 + card_h * 4 + gap * 3
    defs, bg = card(width, height)
    body = [bg]
    for idx, (mode, glyph, line, tag) in enumerate(MODE_CARDS):
        body.append(
            _mode_card(margin, margin + idx * (card_h + gap), width - margin * 2, card_h, mode, glyph, line, tag, compact=True)
        )
    return svg(width, height, "Four modes, one assistant", "Chat, Think, Search and Voice.", body, defs)


# --- 3. Features -----------------------------------------------------------

FEATURES = (
    ("doc", "PDFs & scans", "Cites exact pages", TEAL),
    ("camera", "Vision & camera", "Photos & paper scans", GLACIER),
    ("branch", "Projects & branches", "Shared files & ‹ 2/3 ›", LAVENDER),
    ("search", "13+ languages", "Natural prompts & tools", GOLD),
    ("calendar", "Personal tools", "Action cards & gate", LAVENDER),
    ("memory", "Editable memory", "See & edit every fact", TEAL),
    ("spark", "Siri & Shortcuts", "Widgets & Live Activity", GLACIER),
    ("lock", "100% private", "No account, no cloud", GOLD),
)


def _feature_tile(x: float, y: float, w: float, h: float, glyph: str, title: str, line: str, color: str) -> str:
    return (
        f'<rect x="{num(x)}" y="{num(y)}" width="{num(w)}" height="{num(h)}" rx="16" fill="{RAISED}" '
        f'fill-opacity="0.65" stroke="#F7EBD1" stroke-opacity="0.08"/>'
        + icon_tile(glyph, x + 16, y + 16, color=color, size=40)
        + text(x + 16, y + 82, title, size=15.5, weight=600, family=DISPLAY)
        + text(x + 16, y + 103, line, size=12.5, fill=MUTED)
    )


def features(columns: int = 4) -> str:
    width = WIDE if columns == 4 else NARROW
    margin, gap, h = (24.0, 14.0, 124.0) if columns == 4 else (20.0, 12.0, 124.0)
    rows = -(-len(FEATURES) // columns)
    w = (width - margin * 2 - gap * (columns - 1)) / columns
    height = margin * 2 + rows * h + (rows - 1) * gap
    defs, bg = card(width, height, glows=((width * 0.2, 0, width * 0.65, GLACIER, 0.08),))
    body = [bg]
    for idx, (glyph, title, line, color) in enumerate(FEATURES):
        row, col = divmod(idx, columns)
        body.append(_feature_tile(margin + col * (w + gap), margin + row * (h + gap), w, h, glyph, title, line, color))
    return svg(
        width, height,
        "Built for everyday work on iPhone",
        "PDFs and scans with page citations, vision and camera, projects and branches, 13+ languages, gated personal "
        "tools, editable memory, Siri and widgets, and 100% on-device privacy.",
        body, defs,
    )


# --- 4. Headline Performance -----------------------------------------------

def _stat(x: float, y: float, value: str, label: str, note: str, color: str, *, room: float,
          largest: float = 46) -> str:
    size = min(largest, room / max(text_width(value, 1, bold=True), 0.01))
    return (
        text(x, y, value, size=size, weight=700, family=DISPLAY, fill=color, spacing=-0.5)
        + text(x, y + 32, label, size=15.5, weight=600)
        + text(x, y + 54, note, size=12.5, fill=MUTED)
    )


def performance(measured: Measured, *, narrow: bool = False) -> str:
    stats = (
        (f"{measured.prefill_peak_tok_s:,} tok/s", "peak long-file prefill", "6.2K PDF · Metal 4 FlashAttention", GLACIER),
        (f"{measured.decode_low_tok_s}–{measured.decode_high_tok_s} tok/s", "sustained decode speed",
         "Think (52) · Chat (58) · Rewrite (84)", GOLD),
        (f"{measured.ane_pdf_seconds:.2f} s", "to index a 40-page PDF", "16-Core Neural Engine · 0% GPU", TEAL),
    )
    header = f"{measured.hardware} · {measured.os_version} · 64K WINDOW"
    source = (
        f"Release build on {measured.runtime_tag} ({measured.runtime_build}) · "
        f"{measured.undisturbed_runs} · {measured.chat_peak_gb} chat peak ({measured.full_64k_gb} @ 64K)"
    )
    if narrow:
        width, height = NARROW, 514
        defs, bg = card(width, height, glows=((0, 0, 320, GLACIER, 0.12), (400, 514, 280, GOLD, 0.10)))
        body = [bg]
        hdr_svg, _ = paragraph(24, 38, header.upper(), size=11, width=width - 48, leading=15, fill=MUTED, weight=600)
        body.append(hdr_svg)
        for idx, (val, label, note, color) in enumerate(stats):
            y = 114 + idx * 126
            if idx:
                body.append(f'<rect x="24" y="{num(y - 50)}" width="{num(width - 48)}" height="1" fill="{FIELD}"/>')
            body.append(_stat(24, y, val, label, note, color, room=width - 48, largest=42))
        foot_svg, _ = paragraph(24, height - 42, source, size=11, width=width - 48, leading=15, fill=MUTED)
        body.append(foot_svg)
    else:
        width, height = WIDE, 272
        defs, bg = card(width, height, glows=((80, 0, 420, GLACIER, 0.12), (820, 272, 360, GOLD, 0.10)))
        body = [bg, text(34, 48, header.upper(), size=12, fill=MUTED, weight=600, spacing=1.2)]
        col_w = (width - 68) / 3
        for idx, (val, label, note, color) in enumerate(stats):
            x = 34 + idx * col_w
            if idx:
                body.append(f'<rect x="{num(x - 16)}" y="92" width="1" height="106" fill="{FIELD}"/>')
            body.append(_stat(x, 128, val, label, note, color, room=col_w - 28, largest=44))
        body.append(text(34, height - 26, source, size=11.5, fill=MUTED))
    return svg(
        width, height,
        "How Agello performs on iPhone 17 Pro",
        f"On {measured.hardware}: {measured.prefill_peak_tok_s:,} tok/s peak prefill, "
        f"{measured.decode_low_tok_s} to {measured.decode_high_tok_s} tok/s sustained decode, "
        f"and {measured.ane_pdf_seconds:.2f} s to index a 40-page PDF on the Neural Engine.",
        body, defs,
    )


# --- 5. Decode Speed Chart -------------------------------------------------

def decode_chart(measured: Measured, *, narrow: bool = False) -> str:
    width = NARROW if narrow else WIDE
    height = 418 if narrow else 348
    margin = 24.0 if narrow else 34.0
    defs, bg = card(width, height, glows=((width * 0.85, 0, 360, LAVENDER, 0.09),))
    body = [bg]

    title_str = "Sustained decode speed at 64K context"
    sub_str = (
        "iPhone 17 Pro (Release, tok/s, higher is faster)"
        if narrow
        else "Tokens per second on iPhone 17 Pro (Release, Gemma 4 E4B v2, higher is faster)"
    )
    body.append(text(margin, 44, title_str, size=18 if narrow else 20, weight=600, family=DISPLAY))
    body.append(text(margin, 66, sub_str, size=12.5 if narrow else 13.5, fill=MUTED))

    x0 = margin + (90.0 if narrow else 132.0)
    x1 = width - margin - (86.0 if narrow else 244.0)
    max_tok = 100.0

    def x_for(val: float) -> float:
        return x0 + (val / max_tok) * (x1 - x0)

    top = 114.0 if narrow else 110.0
    row_step = 58.0 if narrow else 46.0
    bar_h = 26.0
    bottom = top + (len(measured.decode_bars) - 1) * row_step + bar_h + (22.0 if narrow else 10.0)

    # Grid ticks
    for tick in (0, 25, 50, 75, 100):
        tx = x_for(tick)
        body.append(
            f'<line x1="{num(tx)}" y1="{num(top - 10)}" x2="{num(tx)}" y2="{num(bottom)}" '
            f'stroke="{FIELD}" stroke-width="1"/>'
        )
        body.append(text(tx, bottom + 18, str(tick), size=11.5, fill=MUTED, anchor="middle"))

    # Upstream v0.18.0 32K reference line
    ref_x = x_for(measured.stock_32k_tok_s)
    body.append(
        f'<line x1="{num(ref_x)}" y1="{num(top - 18)}" x2="{num(ref_x)}" y2="{num(bottom)}" '
        f'stroke="{SILVER}" stroke-width="1.5" stroke-dasharray="4 4"/>'
    )
    ref_label = "v0.18 @ 32K (27)" if narrow else "Upstream v0.18.0 @ 32K (27 tok/s)"
    body.append(text(ref_x + 5, top - 12, ref_label, size=11, fill=SILVER, weight=600))

    for idx, (key, label, tok_s, note, mode_key) in enumerate(measured.decode_bars):
        y = top + idx * row_step
        bw = max(8.0, x_for(tok_s) - x0)
        fill = BAR_COLORS[key]
        accent = MODE_COLORS[mode_key]
        speedup = f"{tok_s / measured.stock_32k_tok_s:.1f}×"

        body.append(f'<circle cx="{num(margin + 6)}" cy="{num(y + bar_h / 2)}" r="4.5" fill="{accent}"/>')
        body.append(text(margin + 18, y + bar_h / 2 + 4.5, label, size=13.5 if narrow else 14.5, weight=600))
        if narrow:
            short_note = note.split("·")[0].strip()
            body.append(text(margin + 18, y + bar_h + 13, short_note, size=10.8, fill=MUTED))

        body.append(
            f'<path d="M{num(x0)} {num(y)} h{num(bw - 6)} a6 6 0 0 1 6 6 v{num(bar_h - 12)} '
            f'a6 6 0 0 1 -6 6 h-{num(bw - 6)} z" fill="{fill}"/>'
        )
        val_label = f"{tok_s:.1f}" if narrow else f"{tok_s:.1f} tok/s"
        val_x = x0 + bw + 8
        body.append(text(val_x, y + bar_h / 2 + 4.5, val_label, size=12.5 if narrow else 13, weight=700, fill=TEXT))
        badge_x = val_x + text_width(val_label, 12.5 if narrow else 13, bold=True) + (6 if narrow else 8)
        badge_w = 38.0 if narrow else 42.0
        body.append(
            f'<rect x="{num(badge_x)}" y="{num(y + 3)}" width="{num(badge_w)}" height="{num(bar_h - 6)}" rx="10" '
            f'fill="{accent}" fill-opacity="0.16" stroke="{accent}" stroke-opacity="0.42"/>'
        )
        body.append(
            text(
                badge_x + badge_w / 2, y + bar_h / 2 + 4, speedup,
                size=10.8 if narrow else 11.2, weight=700, fill=accent, anchor="middle",
            )
        )
        if not narrow:
            body.append(
                text(
                    badge_x + badge_w + 8,
                    y + bar_h / 2 + 4.5,
                    f"· {note}",
                    size=11.8,
                    fill=MUTED,
                )
            )

    footer = (
        "phone-bench.sh · 0.5% median noise · 0 host copies"
        if narrow
        else "phone-bench.sh · iPhone 17 Pro (A19 Pro, 12 GB, iOS 27.2.1) · 0.5% decode noise band · 0 host read copies"
    )
    body.append(text(width - margin, height - 20, footer, size=11, fill=MUTED, anchor="end"))
    return svg(
        width, height,
        "Sustained decode speed at 64K context",
        "Bar chart of sustained decode speed on iPhone 17 Pro at 64K context: Rewrite 84.3 tok/s, Chat 57.8 tok/s, "
        "Document Q&A 56.9 tok/s, and Think 51.9 tok/s — each well above upstream v0.18.0's 27 tok/s at 32K.",
        body, defs,
    )


# --- 5b. Context Scaling & Subsystem Speedups ------------------------------

SUBSYSTEM_SPEEDUPS = (
    ("Warm 64K model load", "8.4 s cold", "1.1 s archive", 1.1 / 8.4, "7.6×", GLACIER),
    ("Vision ViT encode (144 ops)", "972 ms", "214 ms MPP", 214.0 / 972.0, "4.5×", GOLD),
    ("40-page PDF RAG index", "1.90 s GPU", "0.86 s ANE", 0.86 / 1.90, "2.2×", TEAL),
    ("1K-token prefill time", "841 ms card", "600 ms M4", 600.0 / 841.0, "1.4×", LAVENDER),
)

STOCK_CONTEXT_CURVE = (
    ("4K", 43.0),
    ("8K", 38.0),
    ("16K", 34.0),
    ("32K", 27.0),
)


def _draw_context_panel(px: float, py: float, pw: float, ph: float, *, compact: bool) -> list[str]:
    coral = "#D98080"
    parts = [
        _box(px, py, pw, ph, stroke=GLACIER, opacity=0.22, fill=DEEP, fill_opacity=0.60, radius=18),
        text(px + 18, py + 30, "Context scaling (4K → 64K)", size=15.5 if compact else 16.5, weight=600, family=DISPLAY),
        text(
            px + 18, py + 49,
            "Decode tok/s · stock 32K wall vs Agello 64K" if compact else "Sustained decode (tok/s) · stock 32K wall vs Agello 64K",
            size=11 if compact else 11.5, fill=MUTED,
        ),
    ]

    gx0 = px + 44
    gx1 = px + pw - 24
    gy0 = py + 72
    gy1 = py + ph - 74
    max_y = 95.0

    def y_for(val: float) -> float:
        return gy1 - (val / max_y) * (gy1 - gy0)

    # Horizontal grid + Y ticks
    for tick in (0, 25, 50, 75):
        ty = y_for(tick)
        parts.append(f'<line x1="{num(gx0)}" y1="{num(ty)}" x2="{num(gx1)}" y2="{num(ty)}" stroke="{FIELD}" stroke-width="1"/>')
        parts.append(text(gx0 - 8, ty + 4, str(tick), size=10.5, fill=MUTED, anchor="end"))

    # X axis ticks (log2 steps: 4K, 8K, 16K, 32K, 64K) with left breathing room from Y ticks
    labels = ("4K", "8K", "16K", "32K", "64K")
    plot_x0 = gx0 + 18.0
    xs = [plot_x0 + idx * (gx1 - plot_x0) / 4.0 for idx in range(5)]
    for idx, lab in enumerate(labels):
        parts.append(
            text(
                xs[idx], gy1 + 17, lab,
                size=11, fill=GLACIER if idx == 4 else MUTED, weight=700 if idx == 4 else 500, anchor="middle",
            )
        )

    # Glowing 64K lane
    x64 = xs[4]
    parts.append(
        f'<rect x="{num(x64 - 14)}" y="{num(gy0 - 4)}" width="28" height="{num(gy1 - gy0 + 4)}" rx="8" '
        f'fill="{GLACIER}" fill-opacity="0.09"/>'
    )

    # Stock v0.18.0 dashed curve (4K -> 32K)
    pts = [(xs[idx], y_for(val)) for idx, (_, val) in enumerate(STOCK_CONTEXT_CURVE)]
    poly = " ".join(f"{'M' if i == 0 else 'L'}{num(x)} {num(y)}" for i, (x, y) in enumerate(pts))
    parts.append(f'<path d="{poly}" fill="none" stroke="{SILVER}" stroke-width="2" stroke-dasharray="5 4"/>')
    for idx, (x, y) in enumerate(pts):
        val = int(STOCK_CONTEXT_CURVE[idx][1])
        parts.append(f'<circle cx="{num(x)}" cy="{num(y)}" r="3.8" fill="{DEEP}" stroke="{SILVER}" stroke-width="2"/>')
        ly = y - 9 if idx < 3 else y - 10
        lx = x if idx < 3 else x - 12
        parts.append(text(lx, ly, str(val), size=10.5, fill=SILVER, weight=600, anchor="middle"))

    parts.append(
        text(
            xs[0] + 2, y_for(43.0) + 20, "Stock v0.18.0",
            size=10.5, fill=MUTED, weight=600,
        )
    )

    # 32K wall marker
    x32 = xs[3]
    parts.append(
        f'<line x1="{num(x32)}" y1="{num(y_for(27.0) + 6)}" x2="{num(x32)}" y2="{num(gy1)}" '
        f'stroke="{coral}" stroke-width="1.5" stroke-dasharray="3 3"/>'
    )
    parts.append(text(x32 - 6, gy1 - 10, "32K max", size=10.2, fill=coral, weight=600, anchor="end"))

    # Agello 64K spine & markers
    y_rw = y_for(84.3)
    y_ch = y_for(57.8)
    y_th = y_for(51.9)
    parts.append(f'<line x1="{num(x64)}" y1="{num(y_rw)}" x2="{num(x64)}" y2="{num(y_th)}" stroke="{GLACIER}" stroke-opacity="0.45" stroke-width="2"/>')

    agello_pts = (
        (y_rw, "84.3 Rewrite", GOLD, y_rw + 4),
        (y_ch, "57.8 Chat", GLACIER, y_ch - 3),
        (y_th, "51.9 Think", LAVENDER, y_th + 11),
    )
    for py_pt, plabel, col, text_y in agello_pts:
        parts.append(f'<circle cx="{num(x64)}" cy="{num(py_pt)}" r="8.5" fill="{col}" fill-opacity="0.22"/>')
        parts.append(f'<circle cx="{num(x64)}" cy="{num(py_pt)}" r="4.5" fill="{col}"/>')
        parts.append(text(x64 - 14, text_y, plabel, size=11.2, fill=col, weight=700, anchor="end"))

    # Fidelity pill footer inside panel
    pill_y = py + ph - 38
    parts.append(_box(px + 14, pill_y, pw - 28, 26, stroke=TEAL, opacity=0.28, fill=RAISED, fill_opacity=0.82, radius=9))
    pill_txt = (
        "64K: 12/12 bit-exact · 90/90 needles · 3.2–3.5 GB"
        if compact
        else "64K: 12/12 bit-exact to 65,534 · 90/90 needles · 3.2–3.5 GB"
    )
    parts.append(text(px + pw / 2, pill_y + 16.5, pill_txt, size=10.5, fill=TEAL, weight=600, anchor="middle"))
    return parts


def _draw_subsystems_panel(px: float, py: float, pw: float, ph: float, *, compact: bool) -> list[str]:
    parts = [
        _box(px, py, pw, ph, stroke=GOLD, opacity=0.22, fill=DEEP, fill_opacity=0.60, radius=18),
        text(px + 18, py + 30, "Subsystem speedups", size=15.5 if compact else 16.5, weight=600, family=DISPLAY),
        text(px + 18, py + 49, "Baseline vs Agello (shorter bar = faster)", size=11 if compact else 11.5, fill=MUTED),
    ]

    bar_x = px + 18
    label_pad = 96.0 if compact else 108.0
    max_bw = pw - 36 - label_pad
    row_y0 = py + 66
    row_step = 49.0 if compact else 52.0

    for idx, (title, base_lbl, new_lbl, ratio, mult, col) in enumerate(SUBSYSTEM_SPEEDUPS):
        ry = row_y0 + idx * row_step
        parts.append(text(bar_x, ry + 11, title, size=12 if compact else 12.5, weight=600, fill=TEXT))

        # Speedup pill right-aligned
        bw_pill = 40.0
        bx_pill = px + pw - 18 - bw_pill
        parts.append(
            f'<rect x="{num(bx_pill)}" y="{num(ry - 1)}" width="{num(bw_pill)}" height="18" rx="9" '
            f'fill="{col}" fill-opacity="0.16" stroke="{col}" stroke-opacity="0.42"/>'
        )
        parts.append(text(bx_pill + bw_pill / 2, ry + 11.5, mult, size=10.5, weight=700, fill=col, anchor="middle"))

        # Baseline bar (100% width)
        by1 = ry + 20
        parts.append(f'<rect x="{num(bar_x)}" y="{num(by1)}" width="{num(max_bw)}" height="7" rx="3.5" fill="{FIELD}"/>')
        parts.append(text(bar_x + max_bw + 8, by1 + 7, base_lbl, size=10.3, fill=MUTED))

        # Agello bar (proportional)
        by2 = by1 + 10
        ag_w = max(14.0, max_bw * ratio)
        parts.append(f'<rect x="{num(bar_x)}" y="{num(by2)}" width="{num(ag_w)}" height="8" rx="4" fill="{col}"/>')
        parts.append(text(bar_x + max_bw + 8, by2 + 8, new_lbl, size=10.5, fill=col, weight=600))

    # Zero-copy NEON callout pill at bottom
    pill_y = py + ph - 38
    parts.append(_box(px + 14, pill_y, pw - 28, 26, stroke=GOLD, opacity=0.28, fill=RAISED, fill_opacity=0.82, radius=9))
    pill_txt = (
        "Host logit reads / reply: >2,000 MB → 0 B"
        if compact
        else "Host logit readbacks / reply: >2,000 MB → 0 B (NEON)"
    )
    parts.append(text(px + pw / 2, pill_y + 16.5, pill_txt, size=10.5, fill=GOLD, weight=600, anchor="middle"))
    return parts


def silicon_benchmarks(measured: Measured, *, narrow: bool = False) -> str:
    if narrow:
        width, height = NARROW, 710
        defs, bg = card(width, height, glows=((60, 0, 280, GLACIER, 0.10), (340, 680, 280, GOLD, 0.10)))
        body = [
            bg,
            text(20, 36, "SILICON BENCHMARKS · IPHONE 17 PRO", size=11, fill=MUTED, weight=600, spacing=1.1),
        ]
        body.extend(_draw_context_panel(20, 50, width - 40, 302, compact=True))
        body.extend(_draw_subsystems_panel(20, 366, width - 40, 300, compact=True))
        body.append(
            text(
                width / 2, height - 18,
                "A19 Pro Release · ViT via SIM_GPU=Apple_A19_Pro · 0% ANE GPU",
                size=10.2, fill=MUTED, anchor="middle",
            )
        )
    else:
        width, height = WIDE, 412
        defs, bg = card(width, height, glows=((160, 0, 380, GLACIER, 0.10), (740, 412, 360, GOLD, 0.09)))
        body = [
            bg,
            text(
                30, 38,
                f"SILICON BENCHMARKS · {measured.hardware.upper()} · {measured.os_version.upper()}",
                size=11.5, fill=MUTED, weight=600, spacing=1.1,
            ),
        ]
        body.extend(_draw_context_panel(30, 54, 402, 316, compact=False))
        body.extend(_draw_subsystems_panel(448, 54, 402, 316, compact=False))
        body.append(
            text(
                width / 2, height - 18,
                "iPhone 17 Pro (A19 Pro, 12 GB) · Vision ViT encode measured via SIM_GPU=Apple_A19_Pro (0.90 s warm init on phone) · 0% GPU load on ANE",
                size=10.8, fill=MUTED, anchor="middle",
            )
        )
    return svg(
        width, height,
        "Context scaling from 4K to 64K and subsystem speedups on Apple Silicon",
        "Stock LiteRT-LM v0.18.0 drops from 43 tok/s at 4K to 27 tok/s at 32K and caps at 32K; Agello sustains "
        "51.9 to 84.3 tok/s at 64K with 12/12 bit-exact copies to position 65,534. Subsystem speedups: 7.6x faster "
        "warm 64K load, 4.5x faster Vision ViT encode, 2.2x faster 40-page PDF ANE index, 1.4x faster prefill, and "
        "zero host logit readbacks.",
        body, defs,
    )


# --- 6. Architecture & Heterogeneous Silicon -------------------------------

def architecture() -> str:
    width, height = WIDE, 616
    defs, bg = card(
        width, height,
        glows=((180, 320, 380, GLACIER, 0.09), (440, 320, 340, TEAL, 0.08), (720, 320, 360, LAVENDER, 0.09)),
    )
    defs += ARROW_MARKER
    body = [bg, text(36, 46, "DEDICATED SILICON FOR EVERY WORKLOAD · A19 PRO+ & IOS 27", size=12, fill=MUTED, weight=600, spacing=1.3)]

    surfaces = (
        ("chat", "SwiftUI & Composer", "Isolated keystrokes · 4 modes", GLACIER),
        ("doc", "Files, Camera & Web", "PDFs · Vision · Open sources", TEAL),
        ("voice", "Voice, Siri & Intents", "Barge-in · Widgets · Share", GOLD),
    )
    sw, sgap = 254.0, 23.0
    for idx, (glyph, title, line, col) in enumerate(surfaces):
        x = 36 + idx * (sw + sgap)
        body.append(_box(x, 64, sw, 68))
        body.append(icon_tile(glyph, x + 14, 77, color=col, size=42))
        body.append(text(x + 68, 94, title, size=15.5, weight=600, family=DISPLAY))
        body.append(text(x + 68, 114, line, size=12.5, fill=MUTED))
        body.append(_arrow(x + sw / 2, 132, x + sw / 2, 158))

    # AppState & Security plane
    body.append(_box(36, 162, width - 72, 64, stroke=GLACIER, opacity=0.38))
    body.append(text(54, 189, "AppState · ContextBudget · Security Gate", size=16.5, weight=600, family=DISPLAY, fill=GLACIER))
    body.append(text(width - 54, 189, "SwiftData V3 branching tree", size=12.5, fill=MUTED, anchor="end"))
    body.append(
        text(
            54, 210,
            "Tokenizer-exact KV fit · <untrusted_data> spotlighting · fail-closed confirmation cards (0% breach)",
            size=12.5, fill=SECONDARY,
        )
    )

    lanes = (
        (
            "chip", "6-Core Apple10+ GPU", "Neural Accelerators · Metal 4", GOLD, GLACIER,
            (
                ("FlashAttention & MPP", "matmul2d (D=256/512) · 1,668 tok/s"),
                ("verify_8 & NEON Greedy", "7-draft rounds · 0 host copies"),
                ("GPU Vision Encoder", "112 ViT linears · 4.5× faster"),
            ),
        ),
        (
            "ane", "16-Core Neural Engine", "Core AI · 0% GPU contention", TEAL, TEAL,
            (
                ("EmbeddingGemma 2", "4-bucket INT4 · 0.86 s / 40p PDF"),
                ("Concurrent RAG Index", "46 ms while Gemma 4 streams"),
                ("iOS 27 SpeechAnalyzer", "32 ms captions & turn detect"),
            ),
        ),
        (
            "spark", "P-Cores & Agent Engine", "Swift 6 Actor · C++ / Rust", LAVENDER, LAVENDER,
            (
                ("Lazy Conformer Audio", "3 ms load · 1 ms unload"),
                ("LL(1) Tool Grammar", "Native & JSON · parallel tools"),
                ("TokTrie JSON MTP", "Multi-word enums + live Think"),
            ),
        ),
    )
    lw, lgap = 258.0, 17.0
    for idx, (glyph, title, sub, icon_col, border_col, items) in enumerate(lanes):
        lx = 36 + idx * (lw + lgap)
        body.append(_arrow(lx + lw / 2, 226, lx + lw / 2, 252))
        body.append(_box(lx, 256, lw, 238, stroke=border_col, opacity=0.38, fill=DEEP, fill_opacity=0.62, radius=16))
        body.append(icon_tile(glyph, lx + 14, 270, color=icon_col, size=38))
        body.append(text(lx + 62, 286, title, size=15, weight=700, family=DISPLAY))
        body.append(text(lx + 62, 304, sub, size=12, fill=MUTED))
        for j, (it_title, it_sub) in enumerate(items):
            iy = 320 + j * 54
            body.append(_box(lx + 14, iy, lw - 28, 46, fill=RAISED, fill_opacity=0.82, radius=11))
            body.append(text(lx + 26, iy + 20, it_title, size=13.5, weight=600))
            body.append(text(lx + 26, iy + 37, it_sub, size=11.8, fill=MUTED))
        body.append(_arrow(lx + lw / 2, 494, lx + lw / 2, 520))

    # Unified memory foundation bar
    body.append(_box(36, 524, width - 72, 66, stroke=GOLD, opacity=0.36))
    body.append(
        text(
            54, 551,
            "12 GB Unified Memory · Sparse 64K KV & Zero-Blit Metal 4 Snapshots",
            size=15.5, weight=600, family=DISPLAY, fill=GOLD,
        )
    )
    body.append(
        text(
            54, 573,
            "Dual-GATHER 128K RoPE (<0.001 rad) · 1,536-slot local KV rings · 100% shared verify/decode pool · +4.95 MB 200-turn soak",
            size=12.3, fill=SECONDARY,
        )
    )
    return svg(
        width, height,
        "How Agello maps every workload across Apple A19 Pro+ silicon",
        "Inputs flow through AppState, ContextBudget and the security gate into three parallel hardware units: the "
        "6-Core Apple10+ GPU with per-core Neural Accelerators (Metal 4 FlashAttention, verify_8 and GPU Vision), "
        "the 16-Core Neural Engine (Core AI EmbeddingGemma 2 and SpeechAnalyzer with 0% GPU contention), and P-Cores "
        "(lazy Conformer audio, LL(1) tool grammar and JSON MTP), all sharing 12 GB unified memory with sparse 64K KV.",
        body, defs,
    )


def architecture_narrow() -> str:
    width = NARROW
    body = [text(22, 40, "DEDICATED SILICON · A19 PRO+ & IOS 27", size=11.5, fill=MUTED, weight=600, spacing=1.1)]

    chips = (("chat", "SwiftUI", GLACIER), ("doc", "Files & Web", TEAL), ("voice", "Voice & Siri", GOLD))
    cw, cgap = 110.0, 13.0
    for idx, (glyph, label, col) in enumerate(chips):
        cx = 22 + idx * (cw + cgap)
        body.append(_box(cx, 56, cw, 76))
        body.append(icon_tile(glyph, cx + (cw - 34) / 2, 66, color=col, size=34))
        body.append(text(cx + cw / 2, 118, label, size=12.5, weight=600, anchor="middle"))

    body.append(_arrow(width / 2, 132, width / 2, 154))
    body.append(_box(22, 158, width - 44, 78, stroke=GLACIER, opacity=0.38))
    body.append(text(38, 184, "AppState & Security Gate", size=15.5, weight=600, family=DISPLAY, fill=GLACIER))
    p_svg, _ = paragraph(
        38, 204, "Tokenizer-exact KV fit, spotlighting & confirmation cards", size=12.5, width=width - 76, leading=17
    )
    body.append(p_svg)
    body.append(_arrow(width / 2, 236, width / 2, 258))

    sections = (
        (
            "chip", "6-Core Apple10+ GPU", "Neural Accelerators · Metal 4", GOLD, GLACIER,
            "FlashAttention (1,668 tok/s), verify_8, NEON greedy (0 copies) & 4.5× GPU Vision.",
        ),
        (
            "ane", "16-Core Neural Engine", "Core AI · 0% GPU contention", TEAL, TEAL,
            "INT4 EmbeddingGemma 2 (0.86 s / 40p PDF, concurrent index) & 32 ms SpeechAnalyzer.",
        ),
        (
            "spark", "P-Cores & Agent Engine", "Swift 6 Actor · C++ / Rust", LAVENDER, LAVENDER,
            "3 ms lazy Conformer audio, LL(1) tool parser, TokTrie JSON MTP & parallel tools.",
        ),
    )
    y = 262.0
    for glyph, title, sub, ic_col, bd_col, desc in sections:
        body.append(_box(22, y, width - 44, 122, stroke=bd_col, opacity=0.38, fill=DEEP, fill_opacity=0.62, radius=16))
        body.append(icon_tile(glyph, 38, y + 16, color=ic_col, size=38))
        body.append(text(88, y + 33, title, size=15.5, weight=700, family=DISPLAY))
        body.append(text(88, y + 51, sub, size=12, fill=MUTED))
        d_svg, _ = paragraph(38, y + 78, desc, size=12.8, width=width - 76, leading=18)
        body.append(d_svg)
        y += 136

    body.append(_arrow(width / 2, y - 14, width / 2, y + 8))
    my = y + 12
    body.append(_box(22, my, width - 44, 92, stroke=GOLD, opacity=0.36))
    body.append(text(38, my + 27, "12 GB Unified Memory · 64K KV", size=15, weight=600, family=DISPLAY, fill=GOLD))
    m_svg, _ = paragraph(
        38, my + 48,
        "Dual-GATHER 128K RoPE (<0.001 rad), zero-blit Metal 4 snapshots & +4.95 MB 200-turn soak.",
        size=12.5, width=width - 76, leading=17.5,
    )
    body.append(m_svg)

    height = my + 116
    defs, bg = card(width, height, glows=((200, 420, 320, GLACIER, 0.09),))
    defs += ARROW_MARKER
    return svg(
        width, height,
        "How Agello maps every workload across Apple A19 Pro+ silicon",
        "Inputs flow through AppState and the security gate to the 6-Core Apple10+ GPU, 16-Core Neural Engine and "
        "P-Cores over 12 GB unified memory.",
        [bg, *body], defs,
    )


# --- 7. Numbers Grid -------------------------------------------------------

NUMBERS = (
    ("64K", "exact token context", "bit-exact to position 65,534", LAVENDER),
    ("0", "host read copies", "zero-copy NEON greedy on Metal", GLACIER),
    ("0%", "GPU load during RAG", "EmbeddingGemma 2 on 16-Core ANE", TEAL),
    ("4.5×", "faster Vision encode", "112 ViT linears on matrix units", GOLD),
    ("+4.95 MB", "200-turn soak delta", "100% shared verify/decode pool", GLACIER),
    ("622", "automated tests", "iPhone 17 Pro gates + AgelloSim UI", TEAL),
)


def numbers(columns: int = 3) -> str:
    wide = columns == 3
    width = WIDE if wide else NARROW
    margin = 28.0 if wide else 20.0
    rows = -(-len(NUMBERS) // columns)
    cell_h = 122.0 if wide else 128.0
    height = margin * 2 + rows * cell_h
    defs, bg = card(width, height, glows=((width, 0, width * 0.7, LAVENDER, 0.08),))
    body = [bg]
    cell_w = (width - margin * 2) / columns
    pad = 22.0 if wide else 14.0
    for idx, (val, line1, line2, color) in enumerate(NUMBERS):
        row, col = divmod(idx, columns)
        x = margin + col * cell_w + pad
        y = margin + row * cell_h
        if col:
            body.append(f'<rect x="{num(x - pad)}" y="{num(y + 18)}" width="1" height="{num(cell_h - 36)}" fill="{FIELD}"/>')
        if row:
            body.append(f'<rect x="{num(x)}" y="{num(y)}" width="{num(cell_w - pad * 2)}" height="1" fill="{FIELD}"/>')
        body.append(text(x, y + 50, val, size=36 if wide else 29, weight=700, family=DISPLAY, fill=color, spacing=-0.5))
        body.append(text(x, y + 75, line1, size=14 if wide else 13, fill=TEXT, weight=600))
        if wide:
            body.append(text(x, y + 95, line2, size=12.5, fill=MUTED))
        else:
            sub_svg, _ = paragraph(x, y + 94, line2, size=11.5, width=cell_w - pad * 2 - 4, leading=15, fill=MUTED)
            body.append(sub_svg)
    return svg(
        width, height,
        "Agello engineering by the numbers",
        "64K exact token context; 0 host read copies; 0% GPU load during RAG on the 16-Core ANE; 4.5x faster Vision "
        "encode; +5 MB across a 200-turn soak; 622 automated tests (493 unit, 90 device, 39 UI) across real iPhone 17 "
        "Pro hardware gates and AgelloSim.",
        body, defs,
    )


# --- 8. 40x40 Engineering Highlight Icons ----------------------------------

HIGHLIGHT_ICONS = {
    "accelerators": (
        GOLD,
        '<rect x="12" y="12" width="16" height="16" rx="3"/><rect x="16.5" y="16.5" width="7" height="7" rx="1.2"/>'
        '<path d="M16 8.5v3.5M24 8.5v3.5M16 28v3.5M24 28v3.5M8.5 16H12M8.5 24H12M28 16h3.5M28 24h3.5"/>',
    ),
    "ane": (
        TEAL,
        '<circle cx="12" cy="14" r="2.3"/><circle cx="12" cy="26" r="2.3"/>'
        '<circle cx="20" cy="20" r="2.8"/>'
        '<circle cx="28" cy="14" r="2.3"/><circle cx="28" cy="26" r="2.3"/>'
        '<path d="M14 15.4l3.7 2.8M14 24.6l3.7-2.8M22.3 18.2L26 15.4M22.3 21.8L26 24.6"/>',
    ),
    "rotary": (
        LAVENDER,
        '<circle cx="20" cy="20" r="9.5" stroke-opacity="0.4"/>'
        '<path d="M20 10.5A9.5 9.5 0 0 1 29.5 20"/><path d="M20 20l6.4-6.4"/>'
        '<circle cx="20" cy="20" r="2.2"/>',
    ),
    "security": (
        GLACIER,
        '<path d="M20 10.5l7.5 3v6c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5v-6z"/>'
        '<path d="M16.5 20l2.5 2.5 4.5-5"/>',
    ),
    "tree": (
        LAVENDER,
        '<circle cx="14" cy="13" r="2.3"/><circle cx="14" cy="27" r="2.3"/><circle cx="26" cy="20" r="2.3"/>'
        '<path d="M14 15.3v9.4M16.3 13.8c4.2 0 4.8 6.2 7.4 6.2"/>',
    ),
    "proof": (
        TEAL,
        '<rect x="13" y="9.5" width="14" height="21" rx="3"/>'
        '<path d="M17.2 19.5l2.1 2.1 3.8-4.2"/><path d="M18.5 27h3"/>',
    ),
}


def highlight_icon(name: str) -> str:
    color, strokes = HIGHLIGHT_ICONS[name]
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 40 40" aria-hidden="true">\n'
        f'<rect width="40" height="40" rx="11" fill="{CARD}"/>\n'
        f'<rect x="0.5" y="0.5" width="39" height="39" rx="10.5" fill="none" stroke="{color}" stroke-opacity="0.38"/>\n'
        f'<g fill="none" stroke="{color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">'
        f'{strokes}</g>\n</svg>\n'
    )


def render(root: Path, measured: Measured) -> dict[str, str]:
    """Every branded README SVG, keyed by relative path under docs/readme/."""
    images = {
        "hero.svg": hero(root),
        "hero-narrow.svg": hero_narrow(root),
        "modes.svg": modes(),
        "modes-narrow.svg": modes_narrow(),
        "features.svg": features(4),
        "features-narrow.svg": features(2),
        "performance.svg": performance(measured, narrow=False),
        "performance-narrow.svg": performance(measured, narrow=True),
        "decode-by-mode.svg": decode_chart(measured, narrow=False),
        "decode-by-mode-narrow.svg": decode_chart(measured, narrow=True),
        "silicon-benchmarks.svg": silicon_benchmarks(measured, narrow=False),
        "silicon-benchmarks-narrow.svg": silicon_benchmarks(measured, narrow=True),
        "architecture.svg": architecture(),
        "architecture-narrow.svg": architecture_narrow(),
        "numbers.svg": numbers(3),
        "numbers-narrow.svg": numbers(2),
    }
    images.update({f"icons/{name}.svg": highlight_icon(name) for name in HIGHLIGHT_ICONS})
    return dict(sorted(images.items()))
