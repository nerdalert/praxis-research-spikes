# llm-d Performance Benchmark Results

> **Disclaimer:** These are early fuzzing results from a single-node
> development environment using `llm-d-inference-sim` in echo mode without GPU
> inference. They compare request-path behavior and relative overhead; they are
> not production performance claims.

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
Each workload uses the same simulator and methodology across all three
profiles. The EPP profiles (`praxis-go-epp` and `envoy-go-epp`) use the same
Go EPP binary; Track A does not use Go EPP.

**Baseline** means the existing upstream llm-d Envoy+Go EPP request path today:
Envoy receives the request, calls the Go EPP through `ext_proc`, receives the
selected endpoint, and forwards through the Envoy routing path.

## Run Metadata

| Item | Value |
|---|---|
| Track A Praxis commit | `84b4241` (branch `e2e-llm-d-epp-benchmarking`) |
| Track B benchmark worktree | `52f0bfb` (branch `track-b-benchmarking`; implementation base includes `e881dc9`) |
| Go EPP binary | `llm-d-router` at `bbaff6ff` |
| Simulator | `llm-d-inference-sim` echo mode |
| Vegeta | v12.12.0, rate 0, max-workers 16 |
| GuideLLM | v0.6.0, concurrent profile, concurrency=4 |
| CPU | Intel Xeon E5-2686 v4 @ 2.30GHz |
| OS | Linux 6.14.0-1018-aws |
| Run date | 2026-06-08 |

Raw artifacts:

- Track A benchmark worktree: `target/criterion/`
- Track B benchmark worktree: `target/criterion/`

---

## Vegeta: Simulator Echo

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** `llm-d-inference-sim` echo mode, model `test-model`.

| Role | Profile | RPS | p50 | p95 | p99 | Success |
|---|---|---:|---:|---:|---:|---:|
| Track A | `praxis-native` | 12,726 | 1.02ms | 2.32ms | 3.42ms | 100% |
| Track B | `praxis-go-epp` | 5,230 | 2.80ms | 5.09ms | 6.58ms | 100% |
| Baseline | `envoy-go-epp` | 3,586 | 4.10ms | 7.62ms | 9.82ms | 100% |

![Vegeta Simulator Echo: Throughput](assets/svgwrite/simulator-echo-rps.svg)

![Vegeta Simulator Echo: p99 Latency](assets/svgwrite/simulator-echo-p99.svg)

**Summary:** Track A is the fastest path on the small simulator echo workload.
Track B is clearly ahead of the Envoy baseline while still calling the same
Go EPP scheduler as Envoy.

> **Track A vs Baseline:** `praxis-native` is **3.55x higher throughput**
> and has **2.87x lower p99** than `envoy-go-epp`. Track A removes the
> Go EPP entirely — scheduling runs in-process with no gRPC hop.

> **Track B vs Baseline:** `praxis-go-epp` is **1.46x higher throughput**
> and has **1.49x lower p99** than `envoy-go-epp`. Both call the same
> Go EPP over gRPC — the difference is Praxis vs Envoy at the proxy edge.

> **Track A vs Track B:** `praxis-native` is **2.43x higher throughput**
> than `praxis-go-epp`. The gap is the ext_proc gRPC round-trip that
> Track B pays on every request.

**Analysis:** This is the workload where fixed proxy and scheduler overhead is
most visible because the simulator echo backend returns quickly. The Baseline
path pays for Envoy's HTTP data path, Envoy's ext_proc stream management,
the external Go EPP call, endpoint metadata propagation, and Envoy's selected
upstream routing. Track B keeps the same Go EPP scheduling component but
replaces Envoy's side of that exchange with Praxis/Pingora and a narrow
request-phase `llmd_external_epp` filter. That removes some Envoy-specific
routing and ext_proc machinery while preserving the process hop to Go EPP,
which is why Track B improves over Baseline but remains materially slower than
Track A.

Track A is fastest because the scheduler is no longer a second service. Model
extraction, candidate filtering, scoring, and upstream assignment happen inside
Praxis, so the request avoids the gRPC callout, Go EPP process scheduling, and
the extra response interpretation needed to carry `x-gateway-destination-endpoint`
back into the proxy. That architecture is the best fit for small requests where
the backend returns immediately and request-path overhead dominates.

---

## Vegeta: Large-Prompt Body Handling

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** `llm-d-inference-sim` echo mode.

| Role | Profile | 16 KiB RPS / p99 | 64 KiB RPS / p99 | 256 KiB RPS / p99 |
|---|---|---:|---:|---:|
| Track A | `praxis-native` | 2,814 / 12.16ms | 430 / 84.74ms | 113 / 232.68ms |
| Track B | `praxis-go-epp` | 2,541 / 12.99ms | 526 / 47.22ms | 147 / 148.17ms |
| Baseline | `envoy-go-epp` | 2,149 / 16.17ms | 498 / 49.15ms | 146 / 147.17ms |

![Large-Prompt Throughput](assets/svgwrite/large-prompt-rps.svg)

**Summary:** Larger request bodies compress the differences between profiles.
Track B remains ahead of the Envoy baseline at 16 KiB and 64 KiB, but the
256 KiB results are effectively tied.

> **Track B vs Baseline ratio by prompt size:**
>
> | Prompt | Track B RPS | Baseline RPS | Ratio |
> |---|---:|---:|---:|
> | 16 KiB | 2,541 | 2,149 | **1.18x** |
> | 64 KiB | 526 | 498 | **1.06x** |
> | 256 KiB | 147 | 146 | **1.01x** |

Large bodies narrow the gap because the dominant cost shifts from proxy control
flow to moving bytes: buffering the request, sending or replaying the body,
parsing JSON, and forwarding the payload. At that point, Praxis and Envoy spend
much of their time doing similar body I/O work, so the fixed savings from a
lighter proxy path become a smaller share of total request time.

The 256 KiB result does not prove the proxies are identical. It means this
benchmark is dominated by body-transfer cost and local simulator behavior.
Differences in buffering strategy, memory copies, HTTP framing, gRPC body
handling, and backpressure can still skew results, so the large-body numbers
should be read as a body-handling stress test rather than a pure proxy-runtime
comparison.

**Analysis:** The Track B advantage falls from 1.18x at 16 KiB to 1.01x at
256 KiB, which shows that body movement dominates once the payload is large
enough. Track B has to buffer the full request body in Praxis, send that body to
Go EPP over ext_proc-compatible gRPC, reassemble the EPP body response, and then
forward the request to the selected backend. The Baseline performs the analogous
body path through Envoy ext_proc. At smaller sizes, Praxis still has enough
lower proxy/runtime overhead to stay ahead. At 256 KiB, the cost of copying,
buffering, and transferring the body dominates the fixed proxy difference, so
Track B and Baseline converge.

Track A removes the Go EPP body callout, which helps at 16 KiB, but it still
does native body buffering and request parsing for model-aware routing. Its
64 KiB and 256 KiB p99 values are higher in this benchmark, so the large-body
result should be read as a body-handling stress case rather than a blanket
latency ranking. The important component-level takeaway is that large payloads
shift the bottleneck away from scheduler/proxy control flow and toward body
movement, memory pressure, and replay behavior.

---

## GuideLLM: Simulator Echo

**Methodology:** GuideLLM concurrent profile, concurrency=4, 30s.

**Backend:** `llm-d-inference-sim` echo mode.

| Role | Profile | RPS | TTFT median | ITL median |
|---|---|---:|---:|---:|
| Track A | `praxis-native` | 576 | 2.69ms | 0.015ms |
| Track B | `praxis-go-epp` | 476 | 4.08ms | 0.017ms |
| Baseline | `envoy-go-epp` | 394 | 5.88ms | 0.025ms |

![GuideLLM Simulator Echo](assets/svgwrite/guidellm-rps-ttft.svg)

**Summary:** GuideLLM preserves the same ordering as the simulator echo Vegeta
test: Track A first, Track B second, Envoy baseline third. Track B improves both
RPS and TTFT relative to the Envoy baseline.

> **Track B vs Baseline:** `praxis-go-epp` is **1.21x higher RPS** and
> has **1.44x lower TTFT** than `envoy-go-epp`.

> **Track A vs Baseline:** `praxis-native` is **1.46x higher RPS** and
> has **2.19x lower TTFT** than `envoy-go-epp`.

GuideLLM RPS is lower than Vegeta because it processes streaming responses
token by token. TTFT and ITL are shallow in echo mode — meaningful only
with simulated inference latency or real GPU backends.

**Analysis:** GuideLLM is a different client model than Vegeta, so the absolute
RPS numbers should not be compared across tools. GuideLLM exercises an
OpenAI-style client path with streaming response accounting, which makes request
setup and time-to-first-token more visible than a simple HTTP throughput test.
Within this GuideLLM run, Track B's 476 RPS and 4.08ms median TTFT show the
same component-level benefit over Envoy as the Vegeta tests: the Go EPP remains
constant, while the proxy/runtime around it changes from Envoy to Praxis.

Track A again has the lowest TTFT because it avoids the external EPP round trip
entirely. The improvement is meaningful as a proxy-path signal, especially for
fast responses and cache-friendly workloads, but it is not a real generation
latency claim. In a GPU-backed deployment, model prefill/decode time would
dominate many requests; the proxy improvement would still reduce fixed overhead,
but total end-to-end speedup would depend on prompt size, cache behavior,
queueing, and model latency.

---

## Claim Boundaries

- All results are **request-path overhead**, not GPU inference performance.
- Track B does **not** remove the Go EPP. It replaces Envoy with Praxis.
- The simulator echo backend returns instantly — results measure proxy and
  scheduler overhead, not model serving latency.
- The full llm-d API Gateway, Gateway API controllers, Kubernetes CRDs,
  `llm-d-deployer`, InferencePool reconciliation, and real vLLM/SGLang
  workers are not part of these benchmarks.
- Production claims require isolated hardware and real model-serving backends.
