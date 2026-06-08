# Demo Outline: llm-d Performance Benchmarks

## Opening

- These benchmarks compare request-path overhead for three llm-d proxy paths:
  Track A, Track B, and the existing upstream llm-d Envoy+Go EPP baseline.
- The benchmark set uses `llm-d-inference-sim` echo mode, so it can run without
  GPUs and isolate proxy/scheduler overhead from model execution latency.
- These are early fuzzing results from a single-node development environment.
- The local benchmarks do not run the full llm-d API Gateway, Gateway API
  controller, CRDs, `llm-d-deployer`, real vLLM/SGLang workers, KV-transfer, or
  P/D data movement.

## Architecture Slide

Existing upstream llm-d baseline:

```text
Client
  -> Envoy ext_proc
  -> Go EPP scheduler
  -> Envoy ORIGINAL_DST
  -> llm-d-inference-sim
```

Track A:

```text
Client
  -> Praxis / Pingora
  -> llmd_endpoint_picker
  -> llm-d-inference-sim
```

Track B:

```text
Client
  -> Praxis / Pingora
  -> llmd_external_epp
  -> Go EPP scheduler
  -> x-gateway-destination-endpoint
  -> llm-d-inference-sim
```

Narration:

- Baseline means the existing upstream llm-d data-plane path today:
  Envoy plus Go EPP through `ext_proc`.
- Track B keeps the Go EPP but replaces Envoy with Praxis, so it isolates the
  proxy/runtime cost around the same scheduler.
- Track A removes both Envoy and the external Go EPP hop, moving scheduling
  into Praxis.

## Benchmark Profiles Slide

| Role | Profile | What it measures |
|---|---|---|
| Track A | `praxis-native` | Native llm-d scheduling inside Praxis |
| Track B | `praxis-go-epp` | Praxis as the proxy while keeping Go EPP |
| Baseline | `envoy-go-epp` | Existing upstream llm-d Envoy+Go EPP path |

Narration:

- Track B vs Baseline compares Praxis vs Envoy while holding Go EPP constant.
- Track A vs Baseline compares in-process scheduling against the existing
  external EPP architecture.
- Track A vs Track B shows the cost of preserving the external Go EPP hop.

## Workloads Slide

- **Vegeta simulator echo**
  - Small OpenAI-compatible chat request.
  - Highlights fixed proxy and scheduler overhead.
- **Vegeta large-prompt body handling**
  - 16 KiB, 64 KiB, and 256 KiB request bodies.
  - Shows how the gap changes as body buffering and transfer dominate.
- **GuideLLM simulator echo**
  - LLM-shaped client behavior with streaming response accounting.
  - Reports RPS, TTFT, and ITL in echo mode.

## Result Slide: Vegeta Simulator Echo

| Role | Profile | RPS | p99 |
|---|---|---:|---:|
| Track A | `praxis-native` | 12,726 | 3.42ms |
| Track B | `praxis-go-epp` | 5,230 | 6.58ms |
| Baseline | `envoy-go-epp` | 3,586 | 9.82ms |

Narration:

- Track B is 1.46x higher throughput than Baseline while still using Go EPP.
- Track A is 3.55x higher throughput than Baseline because it removes the
  external scheduler process entirely.
- This workload is where request-path overhead is easiest to see because the
  backend returns immediately.

## Result Slide: Large-Prompt Body Handling

| Role | 16 KiB RPS / p99 | 64 KiB RPS / p99 | 256 KiB RPS / p99 |
|---|---:|---:|---:|
| Track A | 2,814 / 12.16ms | 430 / 84.74ms | 113 / 232.68ms |
| Track B | 2,541 / 12.99ms | 526 / 47.22ms | 147 / 148.17ms |
| Baseline | 2,149 / 16.17ms | 498 / 49.15ms | 146 / 147.17ms |

Narration:

- Track B remains ahead of Baseline at 16 KiB and 64 KiB.
- At 256 KiB, Track B and Baseline are effectively tied because body transfer
  dominates the fixed proxy/runtime cost.
- This is a body-handling stress case, not a blanket latency ranking.

## Result Slide: GuideLLM Simulator Echo

| Role | Profile | RPS | TTFT median | ITL median |
|---|---|---:|---:|---:|
| Track A | `praxis-native` | 576 | 2.69ms | 0.015ms |
| Track B | `praxis-go-epp` | 476 | 4.08ms | 0.017ms |
| Baseline | `envoy-go-epp` | 394 | 5.88ms | 0.025ms |

Narration:

- GuideLLM preserves the same ordering as the small Vegeta run.
- Track B is 1.21x higher RPS and 1.44x lower TTFT than Baseline.
- TTFT and ITL are shallow in echo mode; GPU-backed validation is still needed.

## Claim Boundaries Slide

Can claim:

- Track B demonstrates Praxis can replace Envoy while keeping the Go EPP.
- Track A demonstrates a lower-overhead native scheduling path.
- The benchmark compares request-path overhead across the three architectures.

Cannot claim:

- Production throughput.
- GPU inference performance.
- Full llm-d control-plane behavior.
- Full Envoy ext_proc parity for Track B.

## Closing

- Track B provides a lower-cost compatibility path for the existing Go EPP.
- Track A provides the lowest-overhead architecture by moving scheduling into
  the proxy.
- The next validation step is GPU-backed testing with realistic latency,
  real model-serving backends, and the full llm-d deployment stack.
