# llm-d Performance Benchmark Results

> **Disclaimer:** All results below are from a single-node development
> environment using `llm-d-inference-sim` in echo mode without GPU inference.
> These are not validated production performance claims.

---

## Profiles Compared

| Role | Profile | Request path |
|---|---|---|
| Track A | `praxis-native` | Client -> Praxis `llmd_endpoint_picker` -> selected backend |
| Track B | `praxis-go-epp` | Client -> Praxis `llmd_external_epp` -> Go EPP -> selected backend |
| Baseline | `envoy-go-epp` | Client -> Envoy `ext_proc` -> Go EPP -> selected backend |

---

## How To Read These Results

Each table has exactly three rows: Track A, Track B, and the Baseline.

- **Track B and Baseline** rows come from the same benchmark session.
  They used the same Go EPP, the same backend, and the same host.
  **These comparisons are validated.**
- **Track A** rows come from a separate session with a different Praxis
  binary. **Track A vs Track B comparisons are directional only.**

## Run Metadata

| Item | Track A | Track B / Baseline |
|---|---|---|
| Praxis commit | `a142106` | `e881dc9` |
| Go EPP commit | `bbb20ce` | `bbaff6ff` |
| Vegeta | v12.12.0 | v12.12.0 |
| GuideLLM | 0.6.0 | 0.6.0 |
| CPU | Intel Xeon E5-2686 v4 @ 2.30GHz | same host |
| OS | Linux 6.14.0-1018-aws | same host |

Raw artifact locations:

- Track A: `praxis-e2e-benchmark-work/target/criterion/llmd-sim/`,
  `llmd-sim-large-prompt/`, and `llmd-guidellm/`
- Track B: `praxis-track-b-benchmarking/target/criterion/llmd-track-b-sim/`,
  `llmd-track-b-large-prompt/`, and `llmd-track-b-guidellm/`

---

## Vegeta: Simulator Echo

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** `llm-d-inference-sim` echo mode, model `test-model`.

| Role | Profile | RPS | p50 | p95 | p99 | Success | Source |
|---|---|---:|---:|---:|---:|---:|---|
| Track A | `praxis-native` | 12,695 | 1.02ms | 2.35ms | 3.36ms | 100% | Track A session |
| Track B | `praxis-go-epp` | 5,331 | 2.74ms | 4.99ms | 6.42ms | 100% | Track B session |
| Baseline | `envoy-go-epp` | 3,628 | 4.08ms | 7.55ms | 9.68ms | 100% | Track B session |

**Summary:** On the simulator echo workload, Track B is faster than the
Envoy+Go EPP baseline while still keeping Go EPP in the path. Track A has the
highest RPS in the table, but it is from a separate Track A run and should be
read as directional against Track B.

> **Track B vs Baseline (validated, same session):**
> `praxis-go-epp` is **1.47x higher throughput** and has **1.51x lower p99**
> than `envoy-go-epp`. Both use the same Go EPP and simulator.

**Analysis:** The validated same-session comparison is Track B vs Baseline:
5,331 RPS vs 3,628 RPS and 6.42ms p99 vs 9.68ms p99. Because both rows use the
same Go EPP and simulator, the measured difference is the proxy/runtime path:
Praxis+`llmd_external_epp` vs Envoy+`ext_proc`. Track A's `praxis-native` row
does not include the Go EPP hop at all, which explains the higher 12,695 RPS
and 3.36ms p99, but that row was collected in a separate Track A session.

---

## Vegeta: Large-Prompt Body Handling

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** `llm-d-inference-sim` echo mode.

| Role | Profile | 16 KiB RPS / p99 | 64 KiB RPS / p99 | 256 KiB RPS / p99 | Source |
|---|---|---:|---:|---:|---|
| Track A | `praxis-native` | 2,821 / 12.07ms | 436 / 84.02ms | 113 / 234.92ms | Track A session |
| Track B | `praxis-go-epp` | 2,566 / 12.76ms | 530 / 46.57ms | 148 / 147.32ms | Track B session |
| Baseline | `envoy-go-epp` | 2,174 / 15.84ms | 498 / 48.66ms | 145 / 146.58ms | Track B session |

**Summary:** Larger request bodies reduce the Track B advantage over the
Envoy baseline. Track B is clearly ahead at 16 KiB, narrowly ahead at 64 KiB,
and effectively tied with the baseline at 256 KiB.

> **Track B vs Baseline ratio by prompt size:**
>
> | Prompt | Track B RPS | Baseline RPS | Ratio |
> |---|---:|---:|---:|
> | 16 KiB | 2,566 | 2,174 | **1.18x** |
> | 64 KiB | 530 | 498 | **1.06x** |
> | 256 KiB | 148 | 145 | **1.02x** |

**Analysis:** Track B vs Baseline is the grounded same-session comparison here:
2,566 vs 2,174 RPS at 16 KiB, 530 vs 498 RPS at 64 KiB, and 148 vs 145 RPS at
256 KiB. The ratio falls from 1.18x to 1.02x as body size grows, which is
consistent with body transfer dominating fixed proxy/EPP overhead. At 256 KiB,
the p99 values are also effectively tied: 147.32ms for Track B and 146.58ms
for the baseline. Track A large-prompt rows are included for context, but they
come from a separate Track A run and should not be used to claim Track A is
slower or faster at larger body sizes.

---

## GuideLLM: Simulator Echo

**Methodology:** GuideLLM concurrent profile, concurrency=4, 30s.

**Backend:** `llm-d-inference-sim` echo mode.

| Role | Profile | RPS | TTFT median | ITL median | Source |
|---|---|---:|---:|---:|---|
| Track A | `praxis-native` | 575 | 2.74ms | 0.014ms | Track A session |
| Track B | `praxis-go-epp` | 530 | 3.98ms | 0.015ms | Track B session |
| Baseline | `envoy-go-epp` | 433 | 5.30ms | 0.026ms | Track B session |

**Summary:** GuideLLM shows the same ordering as Vegeta for the same-session
Track B comparison: Praxis+Go EPP is ahead of Envoy+Go EPP. The gap is smaller
than in the Vegeta simulator echo run because this GuideLLM run uses lower
concurrency and includes streaming/client-side LLM accounting.

> **Track B vs Baseline (validated, same session):**
> `praxis-go-epp` is **1.22x higher RPS** and has **1.33x lower TTFT**
> than `envoy-go-epp`.

**Analysis:** The same-session GuideLLM comparison is 530 RPS and 3.98ms TTFT
for Track B vs 433 RPS and 5.30ms TTFT for the baseline. That is a smaller
throughput gap than the Vegeta echo test, but the direction is consistent.
GuideLLM is not a raw proxy-throughput harness: it processes streaming
responses and performs per-request LLM accounting. TTFT and ITL are also shallow
in echo mode because the simulator returns immediately; these metrics become
more meaningful with simulated inference latency or real GPU backends.

## Overall Interpretation

Across the same-session Track B comparisons, `praxis-go-epp` is consistently
faster than `envoy-go-epp` while using the same Go EPP scheduler. The strongest
gap appears on small simulator-echo requests, where proxy/runtime overhead is
most visible. The gap narrows with larger request bodies because body transfer
dominates total request time. Track A remains the expected fastest control path
architecturally because it removes the external Go EPP hop, but the Track A rows
were collected in a separate session and are included as directional context,
not as a controlled same-session comparison.

---

## Claim Boundaries

> **Validated comparisons:**
> Track B (`praxis-go-epp`) vs Baseline (`envoy-go-epp`) ran in the same
> session with the same Go EPP and backend. These comparisons are reliable
> within this benchmark environment.

> **Directional comparisons:**
> Track A (`praxis-native`) ran in a separate session with a different Praxis
> binary. Track A vs Track B or Track A vs Baseline comparisons show relative
> ordering but are not controlled experiments.

> **Not proven:**
> - GPU inference performance, real TTFT under generation, or production throughput.
> - Track B does **not** remove the Go EPP. It replaces Envoy with Praxis.
> - These results justify further testing — they are not a final answer.
