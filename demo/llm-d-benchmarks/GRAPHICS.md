# Benchmark Graphics

Static SVG graphs for the llm-d performance benchmarks, generated from three
libraries for style comparison.

## Graph Sets

Each library produces the same five charts in `assets/<library>/`:

| File | Chart type | Data |
|---|---|---|
| `simulator-echo-rps.svg` | Bar — RPS | Vegeta simulator echo throughput |
| `simulator-echo-p99.svg` | Bar — p99 | Vegeta simulator echo latency |
| `large-prompt-rps.svg` | Grouped bar | Large-prompt RPS by body size |
| `large-prompt-track-b-ratio.svg` | Line/marker | Track B vs Baseline ratio |
| `guidellm-rps-ttft.svg` | Bar | GuideLLM RPS (and TTFT for matplotlib) |

## Libraries

| Library | Directory | Style |
|---|---|---|
| **matplotlib** | `assets/matplotlib/` | Publication-quality, two-panel GuideLLM chart |
| **pygal** | `assets/pygal/` | Clean interactive-capable SVG |
| **svgwrite** | `assets/svgwrite/` | Hand-crafted minimal SVG, no dependencies at render time |

## How to Regenerate

```bash
# Requires: pip install matplotlib pygal svgwrite
python3 scripts/generate-graphs.py
```

The script is deterministic. Data is embedded as Python dictionaries sourced
from `results.md` (verified from raw benchmark artifacts).

## Red Hat Design Rationale

Colors follow official Red Hat brand and design system guidance:

- **Red Hat red `#ee0000`**: Used as accent for Track B bars. Red is the
  primary brand color but should not be overused or imply "bad."
- **Dark gray `#3c3f42`**: Track A bars. Near the RHDS `--rh-color-gray-90`.
- **Medium gray `#8a8d90`**: Baseline bars. Neutral comparison anchor.
- **Text `#151515`**: RHDS recommends `#151515` over pure black for UI text.
- **Background `#ffffff`**: Clean white.

Sources:
- [Red Hat Brand Standards: Color](https://www.redhat.com/en/about/brand/standards/color)
- [RHDS Color Usage](https://ux.redhat.com/foundations/color/usage/)
- [RHDS Color Palettes](https://ux.redhat.com/theming/color-palettes/)

## What Not To Do

- Do not add `praxis-simple` to these graphs — it is a proxy control, not
  an llm-d scheduler.
- Do not mix Python mock and Go mock results in the same chart.
- Do not use red to imply "bad" or "error" — red is the Track B accent color.
- Do not claim production benchmark performance from these charts.
