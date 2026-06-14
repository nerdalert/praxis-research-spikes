#!/usr/bin/env python3
"""Generate llm-d benchmark SVG graphs using svgwrite.

Produces static SVGs in assets/svgwrite/ that render natively on GitHub.
No JavaScript, no external fonts, no remote assets.

Run:
    python3 scripts/generate-graphs.py

Requires: pip install svgwrite

Red Hat design references:
  - Brand color: https://www.redhat.com/en/about/brand/standards/color
  - RHDS usage: https://ux.redhat.com/foundations/color/usage/
  - RHDS palettes: https://ux.redhat.com/theming/color-palettes/
"""

import os
import svgwrite

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(SCRIPT_DIR, "..", "assets", "svgwrite")
os.makedirs(ASSETS_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Red Hat themed palette
# ---------------------------------------------------------------------------
RH_RED = "#ee0000"
RH_DARK = "#151515"
RH_GRAY = "#6a6e73"
RH_LIGHT_GRAY = "#d2d2d2"
RH_BG = "#ffffff"
FONT = "Red Hat Text, Inter, Arial, DejaVu Sans, sans-serif"

COLOR_TRACK_A = "#3c3f42"
COLOR_TRACK_B = RH_RED
COLOR_BASELINE = "#8a8d90"
COLORS = [COLOR_TRACK_A, COLOR_TRACK_B, COLOR_BASELINE]

# ---------------------------------------------------------------------------
# Benchmark data
#
# Track A: unchanged accepted values from 2026-06-08.
# Track B + Baseline: fresh same-window run from 2026-06-14.
# GuideLLM Track B + Baseline: pending (tool unavailable in this pass).
# ---------------------------------------------------------------------------
SIM_ECHO = {
    "Track A\npraxis-native": {"rps": 12726, "p99": 3.42},
    "Track B\nfull-duplex-go-epp": {"rps": 7260, "p99": 4.03},
    "Baseline\nenvoy-go-epp": {"rps": 5908, "p99": 5.41},
}

LARGE_PROMPT = {
    "16 KiB": {"Track A": 2814, "Track B": 3710, "Baseline": 3543},
    "64 KiB": {"Track A": 430, "Track B": 733, "Baseline": 713},
    "256 KiB": {"Track A": 113, "Track B": 198, "Baseline": 196},
}

LABELS = list(SIM_ECHO.keys())


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def clean_svg(path):
    """Strip trailing whitespace so git diff --check stays clean."""
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for line in lines:
            f.write(line.rstrip() + "\n")


def bar_chart(fname, title, subtitle, labels, values, colors,
              fmt="{:,.0f}", width=900, height=420):
    """Simple vertical bar chart."""
    W, H = width, height
    m = {"top": 80, "right": 40, "bottom": 80, "left": 90}
    pw = W - m["left"] - m["right"]
    ph = H - m["top"] - m["bottom"]
    mx = max(values) * 1.18

    dwg = svgwrite.Drawing(os.path.join(ASSETS_DIR, fname), size=(W, H))
    dwg.add(dwg.rect((0, 0), (W, H), fill=RH_BG))

    # Title + subtitle
    dwg.add(dwg.text(title, insert=(W / 2, 30), text_anchor="middle",
                     font_size="16px", font_weight="bold", fill=RH_DARK,
                     font_family=FONT))
    dwg.add(dwg.text(subtitle, insert=(W / 2, 52), text_anchor="middle",
                     font_size="11px", fill=RH_GRAY, font_family=FONT))

    # Grid
    for i in range(5):
        y = m["top"] + ph - (ph * i / 4)
        dwg.add(dwg.line((m["left"], y), (m["left"] + pw, y),
                         stroke=RH_LIGHT_GRAY, stroke_width=0.5))
        gv = mx * i / 4
        dwg.add(dwg.text(fmt.format(gv), insert=(m["left"] - 8, y + 4),
                         text_anchor="end", font_size="10px", fill=RH_GRAY,
                         font_family=FONT))

    # Bars
    n = len(values)
    bw = pw / n * 0.55
    gap = pw / n
    for i, (label, val, color) in enumerate(zip(labels, values, colors)):
        x = m["left"] + gap * i + (gap - bw) / 2
        bh = (val / mx) * ph
        y = m["top"] + ph - bh
        dwg.add(dwg.rect((x, y), (bw, bh), fill=color, rx=3))
        dwg.add(dwg.text(fmt.format(val), insert=(x + bw / 2, y - 8),
                         text_anchor="middle", font_size="13px",
                         font_weight="bold", fill=RH_DARK, font_family=FONT))
        for li, line in enumerate(label.split("\n")):
            dwg.add(dwg.text(line,
                             insert=(x + bw / 2, m["top"] + ph + 18 + li * 15),
                             text_anchor="middle", font_size="11px",
                             fill=RH_DARK, font_family=FONT))

    dwg.save()
    clean_svg(os.path.join(ASSETS_DIR, fname))
    print(f"  {fname}")


def grouped_bar_chart(fname, title, subtitle, sizes, roles, role_colors,
                      data, width=1000, height=480):
    """Grouped bar chart for multiple categories."""
    W, H = width, height
    m = {"top": 80, "right": 40, "bottom": 80, "left": 90}
    pw = W - m["left"] - m["right"]
    ph = H - m["top"] - m["bottom"]
    mx = max(v for s in data.values() for v in s.values()) * 1.18

    dwg = svgwrite.Drawing(os.path.join(ASSETS_DIR, fname), size=(W, H))
    dwg.add(dwg.rect((0, 0), (W, H), fill=RH_BG))
    dwg.add(dwg.text(title, insert=(W / 2, 30), text_anchor="middle",
                     font_size="16px", font_weight="bold", fill=RH_DARK,
                     font_family=FONT))
    dwg.add(dwg.text(subtitle, insert=(W / 2, 52), text_anchor="middle",
                     font_size="11px", fill=RH_GRAY, font_family=FONT))

    gw = pw / len(sizes)
    bw = gw / (len(roles) + 1)

    for si, size in enumerate(sizes):
        gx = m["left"] + gw * si
        dwg.add(dwg.text(size, insert=(gx + gw / 2, m["top"] + ph + 22),
                         text_anchor="middle", font_size="12px", fill=RH_DARK,
                         font_family=FONT))
        for ri, (role, color) in enumerate(zip(roles, role_colors)):
            val = data[size][role]
            x = gx + bw * (ri + 0.5)
            bh = (val / mx) * ph
            y = m["top"] + ph - bh
            dwg.add(dwg.rect((x, y), (bw * 0.85, bh), fill=color, rx=2))
            dwg.add(dwg.text(f"{val:,}", insert=(x + bw * 0.42, y - 5),
                             text_anchor="middle", font_size="9px",
                             font_weight="bold", fill=RH_DARK,
                             font_family=FONT))

    # Legend
    for ri, (role, color) in enumerate(zip(roles, role_colors)):
        lx = W - 180
        ly = m["top"] + 10 + ri * 20
        dwg.add(dwg.rect((lx, ly), (14, 14), fill=color, rx=2))
        dwg.add(dwg.text(role, insert=(lx + 20, ly + 12), font_size="11px",
                         fill=RH_DARK, font_family=FONT))

    dwg.save()
    clean_svg(os.path.join(ASSETS_DIR, fname))
    print(f"  {fname}")


def dual_bar_chart(fname, title, subtitle, labels, left_vals, right_vals,
                   left_label, right_label, left_fmt, right_fmt,
                   colors, width=1100, height=440):
    """Side-by-side bar panels."""
    W, H = width, height
    m = {"top": 80, "right": 30, "bottom": 80, "left": 70}
    half = (W - m["left"] - m["right"]) / 2 - 20
    ph = H - m["top"] - m["bottom"]

    dwg = svgwrite.Drawing(os.path.join(ASSETS_DIR, fname), size=(W, H))
    dwg.add(dwg.rect((0, 0), (W, H), fill=RH_BG))
    dwg.add(dwg.text(title, insert=(W / 2, 28), text_anchor="middle",
                     font_size="16px", font_weight="bold", fill=RH_DARK,
                     font_family=FONT))
    dwg.add(dwg.text(subtitle, insert=(W / 2, 48), text_anchor="middle",
                     font_size="11px", fill=RH_GRAY, font_family=FONT))

    for panel, (vals, ylabel, fmt) in enumerate([
        (left_vals, left_label, left_fmt),
        (right_vals, right_label, right_fmt),
    ]):
        ox = m["left"] + panel * (half + 40)
        mx = max(vals) * 1.2
        n = len(vals)
        bw = half / n * 0.6
        gap = half / n

        dwg.add(dwg.text(ylabel, insert=(ox + half / 2, m["top"] - 8),
                         text_anchor="middle", font_size="12px",
                         font_weight="bold", fill=RH_DARK, font_family=FONT))

        for i in range(4):
            y = m["top"] + ph - (ph * i / 3)
            dwg.add(dwg.line((ox, y), (ox + half, y),
                             stroke=RH_LIGHT_GRAY, stroke_width=0.5))

        for i, (label, val, color) in enumerate(zip(labels, vals, colors)):
            x = ox + gap * i + (gap - bw) / 2
            bh = (val / mx) * ph if mx > 0 else 0
            y = m["top"] + ph - bh
            dwg.add(dwg.rect((x, y), (bw, bh), fill=color, rx=2))
            dwg.add(dwg.text(fmt.format(val),
                             insert=(x + bw / 2, y - 6),
                             text_anchor="middle", font_size="11px",
                             font_weight="bold", fill=RH_DARK,
                             font_family=FONT))
            for li, line in enumerate(label.split("\n")):
                dwg.add(dwg.text(line,
                                 insert=(x + bw / 2,
                                         m["top"] + ph + 16 + li * 13),
                                 text_anchor="middle", font_size="9px",
                                 fill=RH_DARK, font_family=FONT))

    dwg.save()
    clean_svg(os.path.join(ASSETS_DIR, fname))
    print(f"  {fname}")


# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("Generating llm-d benchmark graphs (svgwrite)...\n")

    bar_chart("simulator-echo-rps.svg",
              "Vegeta Simulator Echo: Throughput (RPS)",
              "Higher is better",
              LABELS, [d["rps"] for d in SIM_ECHO.values()], COLORS)

    bar_chart("simulator-echo-p99.svg",
              "Vegeta Simulator Echo: p99 Latency",
              "Lower is better",
              LABELS, [d["p99"] for d in SIM_ECHO.values()], COLORS,
              fmt="{:.2f}ms")

    grouped_bar_chart("large-prompt-rps.svg",
                      "Large-Prompt Throughput by Body Size",
                      "Gap narrows as body transfer dominates fixed proxy overhead",
                      list(LARGE_PROMPT.keys()),
                      ["Track A", "Track B", "Baseline"],
                      [COLOR_TRACK_A, COLOR_TRACK_B, COLOR_BASELINE],
                      LARGE_PROMPT)

    print(f"\nAll graphs written to {ASSETS_DIR}/")
