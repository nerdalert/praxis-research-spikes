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
  -> generic ext_proc (full-duplex streamed)
  -> Go EPP scheduler
  -> x-gateway-destination-endpoint
  -> endpoint_selector
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
| Track B | `praxis-ext-proc-full-duplex-go-epp` | Praxis as the proxy while keeping Go EPP |
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
  - Pending on this host because the tool was unavailable during the fresh run.

## Result Slide: Vegeta Simulator Echo

| Role | Profile | RPS | p99 |
|---|---|---:|---:|
| Track A | `praxis-native` | 12,726 | 3.42ms |
| Track B | `praxis-ext-proc-full-duplex-go-epp` | 7,260 | 4.03ms |
| Baseline | `envoy-go-epp` | 5,908 | 5.41ms |

Narration:

- Track B is 1.23x higher throughput than Baseline while still using Go EPP.
- Track A is 2.15x higher throughput than Baseline because it removes the
  external scheduler process entirely.
- This workload is where request-path overhead is easiest to see because the
  backend returns immediately.

## Result Slide: Large-Prompt Body Handling

| Role | 16 KiB RPS / p99 | 64 KiB RPS / p99 | 256 KiB RPS / p99 |
|---|---:|---:|---:|
| Track A | 2,814 / 12.16ms | 430 / 84.74ms | 113 / 232.68ms |
| Track B | 3,710 / 7.68ms | 733 / 35.48ms | 198 / 131.83ms |
| Baseline | 3,543 / 8.85ms | 713 / 35.05ms | 196 / 126.17ms |

Narration:

- Track B remains ahead of Baseline at 16 KiB and 64 KiB.
- At 256 KiB, Track B and Baseline are effectively tied because body transfer
  dominates the fixed proxy/runtime cost.
- This is a body-handling stress case, not a blanket latency ranking.

## Result Slide: GuideLLM Simulator Echo

GuideLLM is pending for the full-duplex Track B benchmark update because the
tool was unavailable on this host during the fresh same-window Track B/Baseline
run.

Narration:

- Do not publish older GuideLLM numbers beside the fresh Vegeta numbers.
- The authoritative published benchmark data for this pass is Vegeta simulator
  echo and Vegeta large-prompt body handling.
- GuideLLM remains useful follow-up validation because it exercises streaming
  response accounting and TTFT.

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
