# llm-d Performance Benchmark Results

> **Disclaimer:** All results below are from a single-node development
> environment using `llm-d-inference-sim` in echo mode without GPU inference.
> These are not validated performance claims. Results should not be referenced
> as production benchmarks until reproduced on properly sized and isolated
> hardware with real model serving backends.

---

## Profiles

### `praxis-simple` — Control

**Not an llm-d scheduler.** Generic Praxis proxy that routes and forwards.
Used to measure base proxy overhead for the same request shape.

```
Client -> Praxis router/load_balancer -> backend
```

### `praxis-native` — Track A

**Praxis replaces both Envoy and Go EPP.** Scheduling runs in-process via
`llmd_endpoint_picker`. No gRPC hop, no external process.

```
Client -> Praxis llmd_endpoint_picker -> selected backend
```

### `praxis-go-epp` — Track B

**Praxis replaces Envoy but keeps the Go EPP.** Praxis calls the Go EPP
through an ext_proc-compatible gRPC stream via `llmd_external_epp`.

```
Client -> Praxis llmd_external_epp -> Go EPP (gRPC) -> selected backend
```

### `envoy-go-epp` — Baseline

**Current llm-d architecture.** Envoy calls the Go EPP through `ext_proc`.

```
Client -> Envoy ext_proc -> Go EPP -> Envoy ORIGINAL_DST -> backend
```

---

## How To Read These Results

> **Compare profiles within the same table.** Do not compare numbers across
> different workload sections — backend speed differs. Do not compare
> GuideLLM RPS to Vegeta RPS — the clients work differently.

- **Vegeta** sends fixed HTTP requests at maximum rate. Best for measuring
  raw proxy throughput and p50/p95/p99 latency.
- **GuideLLM** sends OpenAI-compatible requests with streaming token
  processing. Measures TTFT, ITL, and token throughput. Lower absolute RPS
  than Vegeta because it does more client-side work per request.

## Run Metadata

| Item | Track A | Track B |
|---|---|---|
| Praxis commit | `a142106` | `e881dc9` |
| Go EPP commit | `bbb20ce` | `bbaff6ff` |
| Vegeta | v12.12.0 | v12.12.0 |
| GuideLLM | 0.6.0 | 0.6.0 |
| CPU | Intel Xeon E5-2686 v4 @ 2.30GHz | same |
| OS | Linux 6.14.0-1018-aws | same |

> **Track A and Track B ran in separate sessions** on the same machine.
> Within each session, all profiles ran against the same backend. Rows
> marked "Track A" cannot be directly compared to Track B rows —
> cross-session comparisons are **directional only**.

---

## Vegeta: Simulator Echo

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** `llm-d-inference-sim` echo mode, model `test-model`.

| Role | Profile | RPS | p50 | p95 | p99 | Success | Session |
|---|---|---:|---:|---:|---:|---:|---|
| Control | `praxis-simple` | 11,861 | 1.10ms | 2.54ms | 3.64ms | 100% | Track B |
| Track B | `praxis-go-epp` | 5,331 | 2.74ms | 4.99ms | 6.42ms | 100% | Track B |
| Baseline | `envoy-go-epp` | 3,628 | 4.08ms | 7.55ms | 9.68ms | 100% | Track B |

> **Key finding: Track B is 1.47x faster than the baseline.**
> `praxis-go-epp` (5,331 RPS) vs `envoy-go-epp` (3,628 RPS).
> Same Go EPP, same simulator, same session. **This is a validated comparison.**

**Why `praxis-simple` is so much faster (11,861 RPS):** It does no scheduling.
No body buffering, no gRPC call to the Go EPP, no endpoint selection. It just
routes and forwards. This is the cost of plain Praxis proxying.

**Why `praxis-go-epp` is slower than `praxis-simple` (5,331 vs 11,861):**
The ext_proc gRPC round-trip to the Go EPP roughly halves throughput. Every
request buffers the body, opens a gRPC stream, sends headers + body, reads
the response, and then forwards. That per-request overhead is the cost of
keeping the Go EPP in the path.

**Why `praxis-go-epp` is faster than `envoy-go-epp` (5,331 vs 3,628):**
Both call the same Go EPP over the same gRPC protocol. The only difference is
the proxy: Praxis/Pingora vs Envoy. Praxis has lower per-request overhead
for this workload.

**Track A (separate session, directional only):** `praxis-native` reached
12,551 RPS / 3.42ms p99 (Praxis `a142106`). Close to `praxis-simple` because
native scheduling runs in-process — no gRPC hop.

---

## Vegeta: Large-Prompt Body Handling

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** `llm-d-inference-sim` echo mode. **All rows are from the same Track B session.**

### 16 KiB Prompt

| Role | Profile | RPS | p99 |
|---|---|---:|---:|
| Control | `praxis-simple` | 5,393 | 6.97ms |
| Track B | `praxis-go-epp` | 2,566 | 12.76ms |
| Baseline | `envoy-go-epp` | 2,174 | 15.84ms |

> **Track B is 1.18x faster than the baseline.** The gap is narrower than the
> small-prompt result (1.47x) because the 16 KiB body takes real time to
> transfer over gRPC. Both proxies pay that transfer cost.

### 64 KiB Prompt

| Role | Profile | RPS | p99 |
|---|---|---:|---:|
| Control | `praxis-simple` | 592 | 40.65ms |
| Track B | `praxis-go-epp` | 530 | 46.57ms |
| Baseline | `envoy-go-epp` | 498 | 48.66ms |

> **Track B is 1.06x faster than the baseline.** At 64 KiB, most of the
> request time is moving the body through the gRPC stream. The proxy choice
> barely matters.

### 256 KiB Prompt

| Role | Profile | RPS | p99 |
|---|---|---:|---:|
| Control | `praxis-simple` | 153 | 153.12ms |
| Track B | `praxis-go-epp` | 148 | 147.32ms |
| Baseline | `envoy-go-epp` | 145 | 146.58ms |

> **Track B is 1.02x faster than the baseline.** At 256 KiB, body transfer
> completely dominates. All three profiles converge. The proxy overhead is
> negligible compared to moving a quarter-megabyte request body.

### Summary: How the Gap Narrows

| Prompt size | Track B RPS | Baseline RPS | Ratio |
|---|---:|---:|---|
| Small (echo) | 5,331 | 3,628 | **1.47x** |
| 16 KiB | 2,566 | 2,174 | **1.18x** |
| 64 KiB | 530 | 498 | **1.06x** |
| 256 KiB | 148 | 145 | **1.02x** |

> **The ext_proc gRPC overhead is a fixed per-request cost.** Small requests
> expose it because the proxy round-trip dominates total time. Large requests
> amortize it because body transfer takes much longer than the proxy hop. This
> is expected behavior, not a regression.

---

## Vegeta: Mock Backend

### Go Mock (same session, validated)

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** Go `net/http` mock returning a static JSON response. **All profiles
ran in the same session against the same backend.**

| Role | Profile | RPS | p50 | p95 | p99 | Success |
|---|---|---:|---:|---:|---:|---:|
| Control | `praxis-simple` | 16,029 | 0.77ms | 1.91ms | 2.82ms | 100% |
| Track B | `praxis-go-epp` | 5,992 | 2.42ms | 4.47ms | 5.84ms | 100% |
| Baseline | `envoy-go-epp` | 3,981 | 3.71ms | 6.78ms | 8.66ms | 100% |

> **Track B is 1.51x faster than the baseline** (5,992 vs 3,981 RPS).
> Consistent with the simulator result (1.47x). The ratio is stable across
> backends, confirming the gap is proxy overhead, not backend-dependent.

**Why these numbers are higher than simulator results:** The Go mock responds
instantly with a static JSON blob — no request parsing, no model lookup, no
token generation. The simulator does more work even in echo mode.

### Python Mock (Track A, separate session)

> **Not comparable to the Go mock table above.** The Python backend is much
> slower, so absolute RPS is lower.

| Role | Profile | RPS | p50 | p95 | p99 | Success |
|---|---|---:|---:|---:|---:|---:|
| Control | `praxis-simple` | 5,183 | 0.97ms | 2.02ms | 2.85ms | 100% |
| Track A | `praxis-native` | 5,343 | 0.95ms | 1.97ms | 2.80ms | 100% |
| Baseline | `envoy-go-epp` | 2,284 | 5.08ms | 9.92ms | 13.65ms | 100% |

`praxis-native` and `praxis-simple` are in the same band because native
scheduling adds very little overhead when the backend is slow. The baseline
is 2.3x slower because of the ext_proc gRPC round-trip.

---

## GuideLLM: Simulator Echo

**Methodology:** GuideLLM concurrent profile, concurrency=4, 30s, 100 prompts.

**Backend:** `llm-d-inference-sim` echo mode.

| Role | Profile | RPS | TTFT median | ITL median | Session |
|---|---|---:|---:|---:|---|
| Control | `praxis-simple` | 583 | 3.01ms | 0.015ms | Track B |
| Track B | `praxis-go-epp` | 530 | 3.98ms | 0.015ms | Track B |
| Baseline | `envoy-go-epp` | 433 | 5.30ms | 0.026ms | Track B |

> **Track B vs Baseline: 1.22x higher RPS, 1.33x lower TTFT.**
> Same Go EPP, same simulator, same session.

**Why GuideLLM RPS is lower than Vegeta:** GuideLLM processes streaming
responses token by token. Vegeta sends fixed HTTP requests with no streaming
overhead. They measure different things — do not compare them directly.

**Why the Track B vs Baseline gap is smaller here (1.22x vs 1.47x in Vegeta):**
GuideLLM runs at concurrency=4 — only 4 requests in flight at a time.
Vegeta runs 16 workers at open-loop maximum rate. At lower concurrency, the
client is the bottleneck, not the proxy, so proxy differences show up less.
The relative ordering is the same: Track B is faster than the baseline.

**TTFT and ITL in echo mode are shallow** because the simulator returns
instantly. These metrics become meaningful with simulated inference latency
or real GPU backends.

**Track A (separate session, directional only):** `praxis-native` reached
654 RPS / 2.74ms TTFT (Praxis `a142106`).

---

## Claim Boundaries

> **What these results prove:**
> - Track B (`praxis-go-epp`) is consistently faster than the baseline
>   (`envoy-go-epp`) across all workloads when using the same Go EPP.
> - The gap narrows as request body size grows because body transfer dominates.
> - Same-session comparisons are validated. Cross-session comparisons are
>   directional only.

> **What these results do not prove:**
> - GPU inference performance, real TTFT under generation, or production throughput.
> - That the throughput gap is the final answer — it justifies further testing.
> - Track B does **not** eliminate the Go EPP. It replaces Envoy with Praxis.
