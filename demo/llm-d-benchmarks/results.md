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
| Track B | `praxis-ext-proc-full-duplex-go-epp` | Client -> Praxis generic `ext_proc` (full-duplex) -> Go EPP -> `endpoint_selector` -> selected backend |
| Baseline | `envoy-go-epp` | Client -> Envoy `ext_proc` -> Go EPP -> selected backend |

---

## How To Read These Results

Each table has exactly three rows: Track A, Track B, and the Baseline.
Each workload uses the same simulator and methodology across all three
profiles. The EPP profiles (`praxis-ext-proc-full-duplex-go-epp` and
`envoy-go-epp`) use the same Go EPP binary; Track A does not use Go EPP.

**Baseline** means the existing upstream llm-d Envoy+Go EPP request path today:
Envoy receives the request, calls the Go EPP through `ext_proc`, receives the
selected endpoint, and forwards through the Envoy routing path.

## Run Metadata

| Item | Value |
|---|---|
| Track A Praxis | `84b4241` (branch `e2e-llm-d-epp-benchmarking`) — **unchanged, not rerun** |
| Track B Praxis | [`ext-proc-llm-d-praxis-poc-v2`](https://github.com/nerdalert/praxis/tree/ext-proc-llm-d-praxis-poc-v2) at `d2ca1f1` — generic `ext_proc` + `endpoint_selector` |
| Baseline Envoy | `envoyproxy/envoy:distroless-v1.33.2` |
| Go EPP binary | `llm-d-router` — unchanged |
| Simulator | `llm-d-inference-sim` echo mode |
| Vegeta | v12.12.0, rate 0, max-workers 16 |
| Track B + Baseline fresh run date | 2026-06-14 |
| Track A accepted run date | 2026-06-08 |
| GuideLLM | Pending on this host; tool unavailable during this pass |
| CPU | Intel Xeon E5-2686 v4 @ 2.30GHz |
| OS | Linux 6.14.0-1018-aws |

Raw artifacts:

- Track A benchmark worktree: `target/criterion/`
- Track B benchmark worktree: `target/criterion/`

---

## Vegeta: Simulator Echo

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 8, median.

**Backend:** `llm-d-inference-sim` echo mode, model `test-model`.

| Role | Profile | RPS | p50 | p95 | p99 | Success |
|---|---|---:|---:|---:|---:|---:|
| Track A | `praxis-native` | 12,726 | 1.02ms | 2.32ms | 3.42ms | 100% |
| Track B | `praxis-ext-proc-full-duplex-go-epp` | 7,260 | 2.08ms | 3.27ms | 4.03ms | 100% |
| Baseline | `envoy-go-epp` | 5,908 | 2.52ms | 4.27ms | 5.41ms | 100% |

![Vegeta Simulator Echo: Throughput](assets/svgwrite/simulator-echo-rps.svg)

![Vegeta Simulator Echo: p99 Latency](assets/svgwrite/simulator-echo-p99.svg)

**Summary:** Track A is the fastest path on the small simulator echo workload.
Track B full-duplex is ahead of the Envoy baseline while calling the same
Go EPP scheduler.

> **Track A vs Baseline:** `praxis-native` is **2.15x higher throughput**
> and has **1.58x lower p99** than `envoy-go-epp`. Track A removes the
> Go EPP entirely — scheduling runs in-process with no gRPC hop.

> **Track B vs Baseline:** `praxis-ext-proc-full-duplex-go-epp` is
> **1.23x higher throughput** and has **1.34x lower p99** than
> `envoy-go-epp`. Both call the same Go EPP over gRPC — the difference
> is Praxis vs Envoy at the proxy edge.

**Analysis:** This is the workload where fixed proxy and scheduler overhead is
most visible because the simulator echo backend returns quickly. Track B
full-duplex keeps the same Go EPP scheduling component but replaces Envoy's
proxy path with Praxis/Pingora using the generic `ext_proc` filter with
full-duplex streaming. The single-owner Process driver, incremental body
forwarding, and lean Pingora HTTP path account for the throughput advantage
over the Envoy baseline.

Track A is fastest because the scheduler runs in-process — no gRPC hop,
no Go EPP process, no ext_proc stream management.

---

## Vegeta: Large-Prompt Body Handling

**Methodology:** 3 runs x 30s, 5s warmup, Vegeta rate 0, max-workers 16, median.

**Backend:** `llm-d-inference-sim` echo mode.

| Role | Profile | 16 KiB RPS / p99 | 64 KiB RPS / p99 | 256 KiB RPS / p99 |
|---|---|---:|---:|---:|
| Track A | `praxis-native` | 2,814 / 12.16ms | 430 / 84.74ms | 113 / 232.68ms |
| Track B | `praxis-ext-proc-full-duplex-go-epp` | 3,710 / 7.68ms | 733 / 35.48ms | 198 / 131.83ms |
| Baseline | `envoy-go-epp` | 3,543 / 8.85ms | 713 / 35.05ms | 196 / 126.17ms |

All runs: 100% success, zero h2 reset/GOAWAY errors.

![Large-Prompt Throughput](assets/svgwrite/large-prompt-rps.svg)

**Summary:** Larger request bodies compress the differences between profiles.
Track B full-duplex remains ahead of the Envoy baseline at 16 KiB, but the
larger sizes converge as body I/O dominates.

> **Track B vs Baseline ratio by prompt size:**
>
> | Prompt | Track B RPS | Baseline RPS | Ratio |
> |---|---:|---:|---:|
> | 16 KiB | 3,710 | 3,543 | **1.05x** |
> | 64 KiB | 733 | 713 | **1.03x** |
> | 256 KiB | 198 | 196 | **1.01x** |

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

**Analysis:** The Track B advantage falls from 1.05x at 16 KiB to 1.01x at
256 KiB. Body movement, JSON normalization, protobuf conversion, gRPC
transfer, and forwarding dominate at larger sizes, compressing the proxy-path
difference. Both profiles achieve 100% success across all sizes.

Track A removes the Go EPP body callout, which helps at 16 KiB, but it still
does native body buffering and request parsing for model-aware routing. Its
64 KiB and 256 KiB p99 values are higher in this benchmark, so the large-body
result should be read as a body-handling stress case rather than a blanket
latency ranking. The important component-level takeaway is that large payloads
shift the bottleneck away from scheduler/proxy control flow and toward body
movement, memory pressure, and replay behavior.

---

## GuideLLM: Simulator Echo

**Status:** Pending. GuideLLM was not available on this host during the fresh
Track B/Baseline benchmark pass, so this deck does not publish updated
GuideLLM numbers.

**Planned methodology:** GuideLLM concurrent profile, concurrency=4, 30s,
against `llm-d-inference-sim` echo mode.

**Analysis:** GuideLLM remains useful because it exercises an OpenAI-style
client path with streaming response accounting. It can make request setup and
time-to-first-token overhead more visible than a simple HTTP throughput test.
Until fresh GuideLLM data is collected for both Track B full-duplex and the
Envoy baseline in the same run window, the Vegeta simulator echo and
large-prompt results are the authoritative published benchmark data.

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
- FD04 response lifecycle is not implemented; response-phase benchmarks are
  not applicable.

## Engineering Notes

Earlier benchmark runs observed ~0.01% 503 errors caused by Go h2 server
`ENHANCE_YOUR_CALM` (`too_many_internal_resets`) at sustained high gRPC
stream creation rates. The root cause was abrupt h2 stream closure
(RST_STREAM) when the exchange was dropped after drain without consuming
trailing server data. Adding `drain_trailing()` + `finish_sending()` after
the coalesced response drain eliminated the issue entirely. All fresh
benchmark runs reported here achieved 100% success with zero h2
reset/GOAWAY errors.
