#!/usr/bin/env python3
"""Generate llm-d benchmark SVG graphs using three different libraries.

Each library produces its own set of SVGs in assets/<library>/:
  - matplotlib/  — publication-quality charts via matplotlib
  - pygal/       — interactive-capable SVG charts via pygal
  - svgwrite/    — hand-crafted minimal SVGs via svgwrite

Run:
    python3 scripts/generate-graphs.py

Requires: matplotlib, pygal, svgwrite (pip install matplotlib pygal svgwrite)

Red Hat design references:
  - Brand color: https://www.redhat.com/en/about/brand/standards/color
  - RHDS usage: https://ux.redhat.com/foundations/color/usage/
  - RHDS palettes: https://ux.redhat.com/theming/color-palettes/
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(SCRIPT_DIR, "..", "assets")

# ---------------------------------------------------------------------------
# Red Hat themed palette
# ---------------------------------------------------------------------------
RH_RED = "#ee0000"
RH_DARK = "#151515"
RH_GRAY = "#6a6e73"
RH_LIGHT_GRAY = "#d2d2d2"
RH_BG = "#ffffff"
FONT_STACK = "Red Hat Text, Inter, Arial, DejaVu Sans, sans-serif"

# Track A = charcoal, Track B = Red Hat red (accent), Baseline = medium gray
COLOR_TRACK_A = "#3c3f42"
COLOR_TRACK_B = RH_RED
COLOR_BASELINE = "#8a8d90"

# ---------------------------------------------------------------------------
# Benchmark data (source of truth: results.md verified from raw artifacts)
# ---------------------------------------------------------------------------
SIM_ECHO = {
    "Track A\npraxis-native": {"rps": 12695, "p99": 3.36},
    "Track B\npraxis-go-epp": {"rps": 5331, "p99": 6.42},
    "Baseline\nenvoy-go-epp": {"rps": 3628, "p99": 9.68},
}

LARGE_PROMPT = {
    "16 KiB": {"Track A": 2821, "Track B": 2566, "Baseline": 2174},
    "64 KiB": {"Track A": 436, "Track B": 530, "Baseline": 498},
    "256 KiB": {"Track A": 113, "Track B": 148, "Baseline": 145},
}

TRACK_B_RATIO = {"16 KiB": 1.18, "64 KiB": 1.06, "256 KiB": 1.02}

GUIDELLM = {
    "Track A\npraxis-native": {"rps": 575, "ttft": 2.74},
    "Track B\npraxis-go-epp": {"rps": 530, "ttft": 3.98},
    "Baseline\nenvoy-go-epp": {"rps": 433, "ttft": 5.30},
}

COLORS = [COLOR_TRACK_A, COLOR_TRACK_B, COLOR_BASELINE]
LABELS = list(SIM_ECHO.keys())


def clean_svg(path):
    """Normalize generated SVG text so git whitespace checks stay useful."""
    with open(path, "r", encoding="utf-8") as src:
        lines = src.readlines()
    with open(path, "w", encoding="utf-8", newline="\n") as dst:
        for line in lines:
            dst.write(line.rstrip() + "\n")


# ═══════════════════════════════════════════════════════════════════════════
# Library 1: matplotlib
# ═══════════════════════════════════════════════════════════════════════════
def generate_matplotlib():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import rcParams

    out = os.path.join(ASSETS_DIR, "matplotlib")
    os.makedirs(out, exist_ok=True)

    rcParams["font.family"] = "sans-serif"
    rcParams["font.sans-serif"] = ["Red Hat Text", "Inter", "Arial", "DejaVu Sans"]
    rcParams["text.color"] = RH_DARK
    rcParams["axes.edgecolor"] = RH_LIGHT_GRAY
    rcParams["axes.labelcolor"] = RH_DARK
    rcParams["xtick.color"] = RH_GRAY
    rcParams["ytick.color"] = RH_GRAY
    rcParams["figure.facecolor"] = RH_BG
    rcParams["axes.facecolor"] = RH_BG
    rcParams["savefig.facecolor"] = RH_BG

    def bar_chart(values, labels, colors, title, subtitle, ylabel, fname,
                  fmt="{:,.0f}", higher_better=True):
        fig, ax = plt.subplots(figsize=(8, 5))
        bars = ax.bar(range(len(values)), values, color=colors, width=0.6,
                      edgecolor="none")
        ax.set_xticks(range(len(labels)))
        ax.set_xticklabels([l.replace("\n", "\n") for l in labels],
                           fontsize=10, ha="center")
        ax.set_ylabel(ylabel, fontsize=11)
        ax.set_title(title, fontsize=14, fontweight="bold", color=RH_DARK,
                     pad=20)
        ax.text(0.5, 1.02, subtitle, transform=ax.transAxes, fontsize=9,
                color=RH_GRAY, ha="center", va="bottom")
        ax.grid(axis="y", color=RH_LIGHT_GRAY, linewidth=0.5, alpha=0.7)
        ax.set_axisbelow(True)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        for bar, val in zip(bars, values):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(),
                    fmt.format(val), ha="center", va="bottom", fontsize=11,
                    fontweight="bold", color=RH_DARK)
        fig.tight_layout()
        path = os.path.join(out, fname)
        fig.savefig(path, format="svg")
        clean_svg(path)
        plt.close(fig)
        print(f"  matplotlib: {fname}")

    # Sim echo RPS
    bar_chart([d["rps"] for d in SIM_ECHO.values()], LABELS, COLORS,
              "Vegeta Simulator Echo: Throughput (RPS)",
              "Higher is better · Track B vs Baseline is same-session validated",
              "Requests / second", "simulator-echo-rps.svg")

    # Sim echo p99
    bar_chart([d["p99"] for d in SIM_ECHO.values()], LABELS, COLORS,
              "Vegeta Simulator Echo: p99 Latency",
              "Lower is better",
              "p99 latency (ms)", "simulator-echo-p99.svg",
              fmt="{:.2f}ms", higher_better=False)

    # Large prompt RPS grouped
    fig, ax = plt.subplots(figsize=(10, 5.5))
    sizes = list(LARGE_PROMPT.keys())
    x = range(len(sizes))
    w = 0.25
    for i, (role, color) in enumerate(
            [("Track A", COLOR_TRACK_A), ("Track B", COLOR_TRACK_B),
             ("Baseline", COLOR_BASELINE)]):
        vals = [LARGE_PROMPT[s][role] for s in sizes]
        bars = ax.bar([xi + i * w for xi in x], vals, w, color=color,
                      label=role, edgecolor="none")
        for bar, val in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(),
                    f"{val:,}", ha="center", va="bottom", fontsize=9,
                    color=RH_DARK)
    ax.set_xticks([xi + w for xi in x])
    ax.set_xticklabels(sizes, fontsize=11)
    ax.set_ylabel("Requests / second", fontsize=11)
    ax.set_title("Large-Prompt Throughput by Body Size",
                 fontsize=14, fontweight="bold", color=RH_DARK, pad=20)
    ax.text(0.5, 1.02,
            "Gap narrows as body transfer dominates fixed proxy overhead",
            transform=ax.transAxes, fontsize=9, color=RH_GRAY, ha="center")
    ax.legend(fontsize=10, frameon=False)
    ax.grid(axis="y", color=RH_LIGHT_GRAY, linewidth=0.5, alpha=0.7)
    ax.set_axisbelow(True)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    fig.tight_layout()
    path = os.path.join(out, "large-prompt-rps.svg")
    fig.savefig(path, format="svg")
    clean_svg(path)
    plt.close(fig)
    print("  matplotlib: large-prompt-rps.svg")

    # Track B ratio line
    fig, ax = plt.subplots(figsize=(7, 4))
    sizes = list(TRACK_B_RATIO.keys())
    vals = list(TRACK_B_RATIO.values())
    ax.plot(range(len(sizes)), vals, color=COLOR_TRACK_B, marker="o",
            linewidth=2.5, markersize=10, zorder=5)
    for i, (s, v) in enumerate(zip(sizes, vals)):
        ax.annotate(f"{v:.2f}x", (i, v), textcoords="offset points",
                    xytext=(0, 14), ha="center", fontsize=12,
                    fontweight="bold", color=RH_DARK)
    ax.axhline(1.0, color=RH_LIGHT_GRAY, linewidth=1, linestyle="--",
               zorder=1)
    ax.set_xticks(range(len(sizes)))
    ax.set_xticklabels(sizes, fontsize=11)
    ax.set_ylabel("Track B / Baseline ratio", fontsize=11)
    ax.set_title("Track B Advantage Narrows With Larger Prompts",
                 fontsize=13, fontweight="bold", color=RH_DARK, pad=15)
    ax.set_ylim(0.9, 1.3)
    ax.grid(axis="y", color=RH_LIGHT_GRAY, linewidth=0.5, alpha=0.7)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    fig.tight_layout()
    path = os.path.join(out, "large-prompt-track-b-ratio.svg")
    fig.savefig(path, format="svg")
    clean_svg(path)
    plt.close(fig)
    print("  matplotlib: large-prompt-track-b-ratio.svg")

    # GuideLLM dual panel
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))
    for ax, metric, ylabel, title, fmt in [
        (ax1, "rps", "Requests / second", "GuideLLM RPS", "{:,.0f}"),
        (ax2, "ttft", "TTFT median (ms)", "GuideLLM TTFT", "{:.2f}ms"),
    ]:
        vals = [d[metric] for d in GUIDELLM.values()]
        bars = ax.bar(range(len(vals)), vals, color=COLORS, width=0.6,
                      edgecolor="none")
        ax.set_xticks(range(len(LABELS)))
        ax.set_xticklabels([l.replace("\n", "\n") for l in LABELS],
                           fontsize=9, ha="center")
        ax.set_ylabel(ylabel, fontsize=10)
        ax.set_title(title, fontsize=12, fontweight="bold", color=RH_DARK)
        ax.grid(axis="y", color=RH_LIGHT_GRAY, linewidth=0.5, alpha=0.7)
        ax.set_axisbelow(True)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        for bar, val in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(),
                    fmt.format(val), ha="center", va="bottom", fontsize=10,
                    fontweight="bold", color=RH_DARK)
    fig.suptitle("GuideLLM Simulator Echo",
                 fontsize=14, fontweight="bold", color=RH_DARK, y=1.02)
    fig.tight_layout()
    path = os.path.join(out, "guidellm-rps-ttft.svg")
    fig.savefig(path, format="svg")
    clean_svg(path)
    plt.close(fig)
    print("  matplotlib: guidellm-rps-ttft.svg")


# ═══════════════════════════════════════════════════════════════════════════
# Library 2: pygal
# ═══════════════════════════════════════════════════════════════════════════
def generate_pygal():
    import pygal
    from pygal.style import Style

    out = os.path.join(ASSETS_DIR, "pygal")
    os.makedirs(out, exist_ok=True)

    def render_chart(chart, fname):
        path = os.path.join(out, fname)
        chart.render_to_file(path)
        clean_svg(path)

    rh_style = Style(
        background=RH_BG,
        plot_background=RH_BG,
        foreground=RH_DARK,
        foreground_strong=RH_DARK,
        foreground_subtle=RH_GRAY,
        colors=(COLOR_TRACK_A, COLOR_TRACK_B, COLOR_BASELINE),
        font_family=FONT_STACK,
        title_font_size=18,
        label_font_size=12,
        value_font_size=11,
    )

    short_labels = ["Track A\npraxis-native", "Track B\npraxis-go-epp",
                    "Baseline\nenvoy-go-epp"]

    # Sim echo RPS
    chart = pygal.Bar(style=rh_style, width=900, height=450,
                      show_legend=False, print_values=True,
                      value_formatter=lambda x: f"{x:,.0f}",
                      title="Vegeta Simulator Echo: Throughput (RPS)")
    chart.x_labels = short_labels
    chart.add("RPS", [d["rps"] for d in SIM_ECHO.values()])
    render_chart(chart, "simulator-echo-rps.svg")
    print("  pygal: simulator-echo-rps.svg")

    # Sim echo p99
    chart = pygal.Bar(style=rh_style, width=900, height=450,
                      show_legend=False, print_values=True,
                      value_formatter=lambda x: f"{x:.2f}ms",
                      title="Vegeta Simulator Echo: p99 Latency (lower is better)")
    chart.x_labels = short_labels
    chart.add("p99", [d["p99"] for d in SIM_ECHO.values()])
    render_chart(chart, "simulator-echo-p99.svg")
    print("  pygal: simulator-echo-p99.svg")

    # Large prompt grouped
    chart = pygal.Bar(style=rh_style, width=1000, height=500,
                      print_values=True,
                      value_formatter=lambda x: f"{x:,.0f}",
                      title="Large-Prompt Throughput by Body Size")
    chart.x_labels = list(LARGE_PROMPT.keys())
    chart.add("Track A", [LARGE_PROMPT[s]["Track A"] for s in LARGE_PROMPT])
    chart.add("Track B", [LARGE_PROMPT[s]["Track B"] for s in LARGE_PROMPT])
    chart.add("Baseline", [LARGE_PROMPT[s]["Baseline"] for s in LARGE_PROMPT])
    render_chart(chart, "large-prompt-rps.svg")
    print("  pygal: large-prompt-rps.svg")

    # Track B ratio
    ratio_style = Style(
        background=RH_BG, plot_background=RH_BG,
        foreground=RH_DARK, foreground_strong=RH_DARK,
        foreground_subtle=RH_GRAY,
        colors=(COLOR_TRACK_B,),
        font_family=FONT_STACK,
        title_font_size=16, label_font_size=12, value_font_size=12,
    )
    chart = pygal.Line(style=ratio_style, width=800, height=400,
                       show_legend=False, print_values=True,
                       value_formatter=lambda x: f"{x:.2f}x",
                       dots_size=6, stroke_style={"width": 3},
                       title="Track B Advantage Narrows With Larger Prompts")
    chart.x_labels = list(TRACK_B_RATIO.keys())
    chart.add("Ratio", list(TRACK_B_RATIO.values()))
    render_chart(chart, "large-prompt-track-b-ratio.svg")
    print("  pygal: large-prompt-track-b-ratio.svg")

    # GuideLLM
    chart = pygal.Bar(style=rh_style, width=1000, height=450,
                      show_legend=True, print_values=True,
                      value_formatter=lambda x: f"{x:,.0f}",
                      title="GuideLLM Simulator Echo: RPS and TTFT")
    chart.x_labels = short_labels
    chart.add("RPS", [d["rps"] for d in GUIDELLM.values()])
    render_chart(chart, "guidellm-rps-ttft.svg")
    print("  pygal: guidellm-rps-ttft.svg")


# ═══════════════════════════════════════════════════════════════════════════
# Library 3: svgwrite (hand-crafted)
# ═══════════════════════════════════════════════════════════════════════════
def generate_svgwrite():
    import svgwrite

    out = os.path.join(ASSETS_DIR, "svgwrite")
    os.makedirs(out, exist_ok=True)

    def make_bar_chart(fname, title, subtitle, labels, values, colors,
                       fmt="{:,.0f}", ylabel="", width=900, height=420):
        W, H = width, height
        margin = {"top": 80, "right": 40, "bottom": 80, "left": 80}
        plot_w = W - margin["left"] - margin["right"]
        plot_h = H - margin["top"] - margin["bottom"]
        max_val = max(values) * 1.15

        path = os.path.join(out, fname)
        dwg = svgwrite.Drawing(path, size=(W, H))
        dwg.add(dwg.rect((0, 0), (W, H), fill=RH_BG))

        # Title
        dwg.add(dwg.text(title, insert=(W / 2, 30), text_anchor="middle",
                         font_size="16px", font_weight="bold",
                         fill=RH_DARK, font_family=FONT_STACK))
        dwg.add(dwg.text(subtitle, insert=(W / 2, 50), text_anchor="middle",
                         font_size="11px", fill=RH_GRAY,
                         font_family=FONT_STACK))

        # Grid lines
        for i in range(5):
            y = margin["top"] + plot_h - (plot_h * i / 4)
            dwg.add(dwg.line((margin["left"], y),
                             (margin["left"] + plot_w, y),
                             stroke=RH_LIGHT_GRAY, stroke_width=0.5))
            val = max_val * i / 4
            dwg.add(dwg.text(fmt.format(val),
                             insert=(margin["left"] - 8, y + 4),
                             text_anchor="end", font_size="10px",
                             fill=RH_GRAY, font_family=FONT_STACK))

        # Bars
        n = len(values)
        bar_w = plot_w / n * 0.55
        gap = plot_w / n
        for i, (label, val, color) in enumerate(
                zip(labels, values, colors)):
            x = margin["left"] + gap * i + (gap - bar_w) / 2
            bar_h = (val / max_val) * plot_h
            y = margin["top"] + plot_h - bar_h
            dwg.add(dwg.rect((x, y), (bar_w, bar_h), fill=color, rx=2))
            # Value label
            dwg.add(dwg.text(fmt.format(val),
                             insert=(x + bar_w / 2, y - 6),
                             text_anchor="middle", font_size="12px",
                             font_weight="bold", fill=RH_DARK,
                             font_family=FONT_STACK))
            # X label (multi-line)
            lines = label.split("\n")
            for li, line in enumerate(lines):
                dwg.add(dwg.text(line,
                                 insert=(x + bar_w / 2,
                                         margin["top"] + plot_h + 18 + li * 14),
                                 text_anchor="middle", font_size="10px",
                                 fill=RH_DARK, font_family=FONT_STACK))

        dwg.save()
        clean_svg(path)
        print(f"  svgwrite: {fname}")

    short = ["Track A\npraxis-native", "Track B\npraxis-go-epp",
             "Baseline\nenvoy-go-epp"]

    make_bar_chart("simulator-echo-rps.svg",
                   "Vegeta Simulator Echo: Throughput (RPS)",
                   "Higher is better · Track B vs Baseline same-session",
                   short, [d["rps"] for d in SIM_ECHO.values()], COLORS)

    make_bar_chart("simulator-echo-p99.svg",
                   "Vegeta Simulator Echo: p99 Latency",
                   "Lower is better",
                   short, [d["p99"] for d in SIM_ECHO.values()], COLORS,
                   fmt="{:.2f}ms")

    # Large prompt grouped
    W, H = 1000, 480
    margin = {"top": 80, "right": 40, "bottom": 80, "left": 80}
    plot_w = W - margin["left"] - margin["right"]
    plot_h = H - margin["top"] - margin["bottom"]
    sizes = list(LARGE_PROMPT.keys())
    roles = ["Track A", "Track B", "Baseline"]
    role_colors = [COLOR_TRACK_A, COLOR_TRACK_B, COLOR_BASELINE]
    max_val = max(v for s in LARGE_PROMPT.values() for v in s.values()) * 1.15

    path = os.path.join(out, "large-prompt-rps.svg")
    dwg = svgwrite.Drawing(path, size=(W, H))
    dwg.add(dwg.rect((0, 0), (W, H), fill=RH_BG))
    dwg.add(dwg.text("Large-Prompt Throughput by Body Size",
                     insert=(W / 2, 30), text_anchor="middle",
                     font_size="16px", font_weight="bold", fill=RH_DARK,
                     font_family=FONT_STACK))
    dwg.add(dwg.text("Gap narrows as body transfer dominates",
                     insert=(W / 2, 50), text_anchor="middle",
                     font_size="11px", fill=RH_GRAY, font_family=FONT_STACK))

    group_w = plot_w / len(sizes)
    bar_w = group_w / (len(roles) + 1)
    for si, size in enumerate(sizes):
        gx = margin["left"] + group_w * si
        dwg.add(dwg.text(size, insert=(gx + group_w / 2,
                                       margin["top"] + plot_h + 20),
                         text_anchor="middle", font_size="12px",
                         fill=RH_DARK, font_family=FONT_STACK))
        for ri, (role, color) in enumerate(zip(roles, role_colors)):
            val = LARGE_PROMPT[size][role]
            x = gx + bar_w * (ri + 0.5)
            bar_h = (val / max_val) * plot_h
            y = margin["top"] + plot_h - bar_h
            dwg.add(dwg.rect((x, y), (bar_w * 0.85, bar_h), fill=color,
                             rx=1))
            dwg.add(dwg.text(f"{val:,}", insert=(x + bar_w * 0.42, y - 4),
                             text_anchor="middle", font_size="9px",
                             font_weight="bold", fill=RH_DARK,
                             font_family=FONT_STACK))

    # Legend
    for ri, (role, color) in enumerate(zip(roles, role_colors)):
        lx = W - 180
        ly = margin["top"] + 10 + ri * 18
        dwg.add(dwg.rect((lx, ly), (12, 12), fill=color, rx=1))
        dwg.add(dwg.text(role, insert=(lx + 18, ly + 11),
                         font_size="11px", fill=RH_DARK,
                         font_family=FONT_STACK))
    dwg.save()
    clean_svg(path)
    print("  svgwrite: large-prompt-rps.svg")

    # Track B ratio
    W, H = 750, 380
    margin = {"top": 70, "right": 40, "bottom": 60, "left": 80}
    plot_w = W - margin["left"] - margin["right"]
    plot_h = H - margin["top"] - margin["bottom"]
    sizes_r = list(TRACK_B_RATIO.keys())
    vals_r = list(TRACK_B_RATIO.values())
    y_min, y_max = 0.9, 1.3

    path = os.path.join(out, "large-prompt-track-b-ratio.svg")
    dwg = svgwrite.Drawing(path, size=(W, H))
    dwg.add(dwg.rect((0, 0), (W, H), fill=RH_BG))
    dwg.add(dwg.text("Track B Advantage Narrows With Larger Prompts",
                     insert=(W / 2, 28), text_anchor="middle",
                     font_size="14px", font_weight="bold", fill=RH_DARK,
                     font_family=FONT_STACK))

    # 1.0 reference line
    y1 = margin["top"] + plot_h - ((1.0 - y_min) / (y_max - y_min)) * plot_h
    dwg.add(dwg.line((margin["left"], y1),
                     (margin["left"] + plot_w, y1),
                     stroke=RH_LIGHT_GRAY, stroke_width=1,
                     stroke_dasharray="5,3"))

    points = []
    for i, (s, v) in enumerate(zip(sizes_r, vals_r)):
        x = margin["left"] + (plot_w / (len(sizes_r) - 1)) * i
        y = margin["top"] + plot_h - ((v - y_min) / (y_max - y_min)) * plot_h
        points.append((x, y))
        dwg.add(dwg.text(s, insert=(x, margin["top"] + plot_h + 20),
                         text_anchor="middle", font_size="12px",
                         fill=RH_DARK, font_family=FONT_STACK))

    dwg.add(dwg.polyline(points, fill="none", stroke=COLOR_TRACK_B,
                         stroke_width=3))
    for (x, y), v in zip(points, vals_r):
        dwg.add(dwg.circle((x, y), 6, fill=COLOR_TRACK_B))
        dwg.add(dwg.text(f"{v:.2f}x", insert=(x, y - 14),
                         text_anchor="middle", font_size="13px",
                         font_weight="bold", fill=RH_DARK,
                         font_family=FONT_STACK))
    dwg.save()
    clean_svg(path)
    print("  svgwrite: large-prompt-track-b-ratio.svg")

    # GuideLLM
    make_bar_chart("guidellm-rps-ttft.svg",
                   "GuideLLM Simulator Echo: RPS",
                   "Streaming client · do not compare to Vegeta RPS",
                   short, [d["rps"] for d in GUIDELLM.values()], COLORS)


# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    print("Generating llm-d benchmark graphs...\n")
    print("Library 1: matplotlib")
    generate_matplotlib()
    print("\nLibrary 2: pygal")
    generate_pygal()
    print("\nLibrary 3: svgwrite")
    generate_svgwrite()
    print(f"\nAll graphs written to {ASSETS_DIR}/")
