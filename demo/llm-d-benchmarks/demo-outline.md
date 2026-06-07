# Demo Outline: Praxis llm-d Benchmarking

## Opening

- The purpose of this benchmark is to measure request-path overhead.
- The comparison is between current llm-d scheduling through Envoy plus Go EPP
  and native scheduling inside Praxis.
- The benchmark set uses mock backends and `llm-d-inference-sim` echo mode, so
  it can run without GPUs.
- The local benchmarks do not run the full llm-d API Gateway, Gateway API
  controller, CRDs, or `llm-d-deployer`; they run only the measured data-plane
  pieces.
- Results should be described as proxy and scheduler control-path overhead,
  not model execution performance.

## Architecture Slide

Baseline path:

```text
Client
  -> Envoy
  -> ext_proc gRPC call
  -> Go EPP scheduler
  -> Envoy selected endpoint
  -> mock backend (127.0.0.1:18080)
```

Praxis native path:

```text
Client
  -> Praxis / Pingora
  -> llmd_endpoint_picker HttpFilter
  -> mock backend (127.0.0.1:18080)
```

Praxis + Go EPP path (Track B):

```text
Client
  -> Praxis / Pingora
  -> llmd_external_epp HttpFilter
  -> ext_proc gRPC call
  -> Go EPP scheduler
  -> x-gateway-destination-endpoint
  -> mock backend (127.0.0.1:18080)
```

Narration:

- In the baseline, endpoint selection crosses process and protocol boundaries.
- In Praxis native mode, request parsing, candidate selection, scoring, and
  upstream assignment run inside the proxy.
- In Praxis + Go EPP mode (Track B), Praxis replaces Envoy at the edge but
  keeps the same Go EPP for scheduling. This isolates the proxy cost.
- The mock backend returns a static response immediately. Simulator runs use
  `llm-d-inference-sim` echo mode for OpenAI-compatible responses. Both isolate
  proxy and scheduler overhead from real model execution latency.
- The Go EPP profiles run the real `llm-d-router` EPP binary with file
  discovery. They validate the ext_proc/EPP handoff, not the full llm-d
  Kubernetes control plane.
- The reason this should carry over is that the request-path contract is the
  same: OpenAI request in, EPP callout, selected endpoint returned, original
  request forwarded. A full llm-d deployment adds the Gateway/API/controller
  machinery that creates and maintains that path.
- The risk is not the basic handoff; it is whether a full deployment enables
  extra Kubernetes-only EPP plugins, Envoy-specific metadata, service mesh
  filters, dynamic discovery, or real model-serving bottlenecks that the local
  benchmark intentionally leaves out.

## Benchmark Profiles Slide

- Praxis profile distinction:
  - `praxis-simple` is the Praxis proxy control.
  - `praxis-native` is the native llm-d scheduler path.
  - The difference between them is the incremental cost of
    `llmd_endpoint_picker`.
  - The difference between `praxis-native` and `envoy-go-epp` is the architecture
    comparison: in-process scheduling versus Envoy `ext_proc` plus Go EPP.

- `envoy-go-epp`:
  - Current-style llm-d baseline.
  - Request path: `Client -> Envoy ext_proc -> Go EPP -> ORIGINAL_DST -> backend`.
  - Envoy runs in Docker and calls the local Go EPP process through `ext_proc`.
  - Go EPP uses file discovery and one static endpoint in the smoke benchmark.
  - Purpose: measure Envoy plus external scheduler process overhead.

- `praxis-native`:
  - Main implementation path.
  - Request path: `Client -> Praxis llmd_endpoint_picker -> backend`.
  - Praxis runs model extraction, endpoint filtering, scoring, and upstream
    selection in process.
  - This is the profile that represents Praxis replacing the Go EPP scheduling
    decision path.
  - Purpose: measure native llm-d scheduling inside Praxis without Envoy,
    `ext_proc`, or Go EPP.

- `praxis-simple`:
  - Generic Praxis data-plane baseline.
  - Request path: `Client -> Praxis router/load_balancer -> backend`.
  - Praxis does not parse the OpenAI request body or run llm-d scheduling.
  - This is not an llm-d scheduler profile; it is the control for plain Praxis
    forwarding cost.
  - Purpose: isolate the incremental overhead of `llmd_endpoint_picker`.

- `envoy-praxis-native`:
  - Planned compatibility profile.
  - Request path: `Client -> Envoy -> Praxis llmd_endpoint_picker -> backend`.
  - Praxis performs native llm-d scheduling behind Envoy.
  - Purpose: evaluate a migration topology where Envoy remains at the edge.

## Workloads Slide

- `llmd-chat-small`:
  - Small OpenAI-compatible chat request.
  - Measures base parser, scheduler, and forwarding cost.

- `llmd-chat-large-prompt`:
  - Larger JSON body.
  - Measures body buffering and JSON parsing overhead.

- `llmd-chat-streaming`:
  - SSE-style response.
  - Measures long-lived request pressure.

- `llmd-load-aware`:
  - Simulator exposes fake vLLM metrics.
  - Measures metrics-driven scoring overhead.

- `llmd-saturation`:
  - Simulator exposes saturated queue/KV pressure.
  - Measures admission decision overhead.

## Demo Clip 1: Quick Smoke

Show quick validation that the harness works:

```console
./benchmarks/llm-d/run-smoke.sh 5 1
LLM_D_ROUTER_REPO=../llm-d-router ./benchmarks/llm-d/run-envoy-go-epp-smoke.sh 5 1
```

Narration:

- Three profiles, same mock backend, same workload.
- Quick runs to verify everything starts and produces results.

## Demo Clip 2: Extended Benchmark

Show the extended benchmark with longer duration and multiple runs:

```console
LLM_D_ROUTER_REPO=../llm-d-router ./benchmarks/llm-d/run-extended-benchmark.sh 30 5 3
```

Show the summary table:

```
         Profile       RPS       p50       p95       p99   Success
------------------------------------------------------------
   praxis-simple      5183     0.97ms    2.02ms    2.85ms   100.00%
   praxis-native      5343     0.95ms    1.97ms    2.80ms   100.00%
    envoy-go-epp      2284     5.08ms    9.92ms   13.65ms   100.00%

praxis-native vs envoy-go-epp:
  Throughput: 2.3x
  p99 latency: 4.9x lower
```

Narration:

- Median of 3 runs at 30 seconds each reduces noise.
- Requests genuinely traverse Envoy, ext_proc gRPC, and the Go EPP process.
- The native Praxis path shows substantially lower control-path overhead.
- This is a mock-backend baseline; the gap justifies testing with a real
  simulator.

## Demo Clip 3: llm-d-inference-sim Backend

Show the same three profiles with the real simulator:

```console
LLM_D_ROUTER_REPO=../llm-d-router \
LLM_D_SIM_REPO=../llm-d-inference-sim \
  ./benchmarks/llm-d/run-sim-benchmark.sh 30 5 3
```

Show the summary table:

```
         Profile       RPS       p50       p95       p99   Success
------------------------------------------------------------
   praxis-simple     12709     1.01ms    2.37ms    3.41ms   100.00%
   praxis-native     12551     1.03ms    2.37ms    3.42ms   100.00%
    envoy-go-epp      3677     3.99ms    7.46ms    9.76ms   100.00%

praxis-native vs envoy-go-epp:
  Throughput: 3.4x
  p99 latency: 2.9x lower
```

Narration:

- The simulator is more realistic than the Python mock: it implements
  OpenAI-compatible endpoints, model serving, and vLLM metrics behavior.
- Even with a faster backend, the Envoy + Go EPP path remains materially
  slower than native Praxis.
- praxis-native and praxis-simple are in the same throughput envelope,
  confirming `praxis-native` is within the same performance band as
  `praxis-simple` in this benchmark.
- The important comparison is praxis-native vs envoy-go-epp, not
  praxis-native vs praxis-simple.

## Demo Clip 4: Large-Prompt Body Handling

Show the large-prompt benchmark:

```console
LLM_D_ROUTER_REPO=../llm-d-router \
LLM_D_SIM_REPO=../llm-d-inference-sim \
  ./benchmarks/llm-d/run-sim-large-prompt-benchmark.sh 30 5 3
```

Show how the gap changes by prompt size:

```
Prompt Size | praxis-native | envoy-go-epp | Ratio
Small 100B  |   12,551 rps  |    3,677 rps |  3.4x
16 KiB      |    2,821 rps  |    1,504 rps |  1.9x
64 KiB      |      436 rps  |      342 rps |  1.3x
256 KiB     |      113 rps  |       95 rps |  1.2x
```

Narration:

- Large prompts stress request body handling and ext_proc body movement.
- The architecture-overhead gap narrows as prompt size grows because
  body transfer time dominates and ext_proc overhead becomes a smaller
  fraction.
- At small prompts, ext_proc round-trip is the dominant cost difference.
- This confirms the ext_proc penalty is a per-request fixed cost, not
  proportional to body size.

## Demo Clip 5: GuideLLM LLM-Specific Metrics

Show GuideLLM running across all three profiles:

```console
./benchmarks/llm-d/run-guidellm-sim-benchmark.sh 30
```

Show GuideLLM output table with TTFT, ITL, token throughput.

Narration:

- GuideLLM provides LLM-specific metrics: TTFT, inter-token latency, token
  throughput per second.
- No proxy config changes needed: GuideLLM disables backend health validation
  and uses explicit model name.
- TTFT and ITL are shallow in echo mode; they become meaningful with simulated
  or real inference latency.
- GuideLLM supports concurrent, constant, poisson, and sweep traffic profiles
  for future GPU-backed validation.
- Vegeta remains the architecture/control-path harness; GuideLLM adds
  LLM-shaped workload coverage.

## Demo Clip 6: Load-Aware Scenario (Future)

When `llm-d-inference-sim` is wired as the backend:

- Show simulator fake metrics for idle and busy endpoints.
- Show benchmark request load.
- Show routing correctness smoke proof.
- Show benchmark summary.

Narration:

- Fake metrics come from `llm-d-inference-sim`.
- Praxis and Go EPP both treat them as vLLM-compatible metrics.
- The benchmark measures cost of making load-aware decisions, not real GPU load.

## Closing

- The no-GPU benchmark harness is the first step.
- It is enough to compare architecture overhead and scheduling path cost.
- GPU-backed validation is still needed for production claims around TTFT,
  throughput under model load, real KV-cache behavior, and P/D data movement.
