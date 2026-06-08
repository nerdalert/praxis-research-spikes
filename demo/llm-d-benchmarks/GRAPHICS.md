# Benchmark Graphics

Static SVG graphs for the llm-d performance benchmarks, generated with
[svgwrite](https://pypi.org/project/svgwrite/).

## Graphs

All SVGs are in `assets/svgwrite/`:

| File | Chart type | Data |
|---|---|---|
| `simulator-echo-rps.svg` | Bar | Vegeta simulator echo throughput (RPS) |
| `simulator-echo-p99.svg` | Bar | Vegeta simulator echo p99 latency |
| `large-prompt-rps.svg` | Grouped bar | Large-prompt RPS by body size |
| `guidellm-rps-ttft.svg` | Dual-panel bar | GuideLLM RPS + TTFT |

## How to Regenerate

```bash
pip install svgwrite
python3 scripts/generate-graphs.py
```

The script is deterministic. Data is embedded as Python dictionaries
sourced from the 2026-06-08 benchmark data set.

## Red Hat Design Rationale

Colors follow official Red Hat brand and design system guidance:

- **Track A** — charcoal `#3c3f42`
- **Track B** — Red Hat red `#ee0000` (accent, not implying "bad")
- **Baseline** — medium gray `#8a8d90`
- **Text** — `#151515` (RHDS recommendation over pure black)
- **Background** — white `#ffffff`

Sources:
- [Red Hat Brand Standards: Color](https://www.redhat.com/en/about/brand/standards/color)
- [RHDS Color Usage](https://ux.redhat.com/foundations/color/usage/)
- [RHDS Color Palettes](https://ux.redhat.com/theming/color-palettes/)
