# Track B: Praxis with Go EPP Demo

| Resource | Link |
|----------|------|
| Track B Deployment Guide | [deploy.md](deploy.md) |
| Track B Demo Scripts | [scripts/](scripts/) |
| Track B Architecture and PR Stack | [architecture-and-pr-stack.md](architecture-and-pr-stack.md) |
| Track B Sample Output | [sample-output.md](sample-output.md) |
| Track B Praxis Branch | [`nerdalert/praxis:track-b`](https://github.com/nerdalert/praxis/tree/track-b) |
| Praxis llm-d Epic | [praxis-proxy/praxis#413](https://github.com/praxis-proxy/praxis/issues/413) |
| Required Praxis PR | [praxis-proxy/praxis#428](https://github.com/praxis-proxy/praxis/pull/428) |

## What Track B Proves

Track B proves **Praxis can replace Envoy as the proxy data plane** while
the existing Go EPP remains the scheduler. Praxis calls the Go EPP through
ext_proc-compatible gRPC, receives the endpoint decision, and forwards the
original request to the selected backend.

> **Claim boundary:** In Track B, Praxis is the proxy. Go EPP is the
> scheduler. Praxis does not claim native model-aware, load-aware,
> prefix-cache, P/D, or policy behavior. Those scheduling decisions
> happen inside the Go EPP. Praxis transports and applies the EPP's
> decision.

## Track A vs Track B

| | Track A | Track B |
|---|---|---|
| **What Praxis does** | Parses model, scores endpoints, selects upstream | Calls Go EPP, applies EPP's endpoint selection |
| **What runs scheduling** | Praxis `llmd_endpoint_picker` (in-process) | Go EPP (external process) |
| **Envoy in path** | No | No |
| **Go EPP in path** | No | Yes |
| **What the demo proves** | Praxis-owned scheduling features | Praxis carries the Go EPP scheduling decision without Envoy |

## Architecture

### Current Baseline (Envoy + Go EPP)

```
  Client
    -> Envoy (ext_proc filter)
    -> gRPC ext_proc stream to Go EPP
    -> Go EPP: discovery, scheduling, endpoint selection
    -> x-gateway-destination-endpoint header back to Envoy
    -> Envoy ORIGINAL_DST cluster
    -> selected backend
```

### Track B (Praxis + Go EPP)

```
  Client
    -> Praxis / Pingora (llmd_external_epp filter)
    -> ext_proc-compatible gRPC stream to Go EPP
        - send RequestHeaders + RequestBody
        - read selected endpoint from response
        - drain trailing responses
    -> x-gateway-destination-endpoint -> ctx.upstream
    -> apply request header/body mutations from EPP
    -> selected backend
```

### Track A (Praxis Native — for contrast)

```
  Client
    -> Praxis (llmd_endpoint_picker filter)
        - model extraction, endpoint scoring, upstream selection
        - no Envoy, no ext_proc, no Go EPP
    -> selected backend
```

## Why Track B Matters

- **Lower risk.** Replacing Envoy is a smaller change than replacing both
  Envoy and Go EPP. The Go EPP scheduling investment is preserved.
- **Stepping stone.** Gives llm-d a Praxis/Pingora proxy path without
  requiring the native scheduler (Track A) to be ready first.
- **Same Go EPP semantics.** The Go EPP makes the same scheduling decisions
  it makes today. Only the proxy changes.
- **Measurable.** `praxis-go-epp` vs `envoy-go-epp` isolates the proxy
  cost with the same Go EPP held constant.

## Demo Matrix

### P0: Core Track B Demos

| # | Demo | Environment | What it proves |
|---|---|---|---|
| 01 | [Praxis-to-Go-EPP request path](scripts/01-praxis-to-go-epp-request-path/) | Local processes | Client -> Praxis -> Go EPP -> backend. HTTP 200, EPP log proof, no Envoy in path. |
| 02 | [Failure behavior and recovery](scripts/02-failure-behavior-and-recovery/) | Local processes | Oversized body 413 (no EPP call), EPP-down 503, EPP restart recovery. |
| 03 | [Kubernetes Go EPP load-aware routing](scripts/03-kubernetes-go-epp-load-aware-routing/) | KIND cluster | Two backends, asymmetric load. Go EPP scores by KV cache utilization, picks idle backend. Praxis applies the decision. |
| 04 | [Benchmark comparison](../llm-d-benchmarks/results.md) | Local benchmark | `praxis-go-epp` vs `envoy-go-epp` with same Go EPP and backend. Vegeta + GuideLLM. |

### P1: Optional (only if Go EPP is configured for the behavior)

| # | Demo | What it would prove | Claim boundary |
|---|---|---|---|
| 5 | Go EPP model-aware selection | Go EPP performs model-aware routing; Praxis carries and applies the decision. | Praxis does **not** extract or score the model. |
| 6 | Go EPP K8s discovery | Go EPP discovers endpoints via K8s; Praxis calls Go EPP and forwards to the chosen endpoint. | Praxis does **not** read InferencePool or discover pods. |

### Not Claimed in Track B

These are Track A (native Praxis) capabilities. Track B does not implement
them — the Go EPP may perform equivalent behavior internally, but Praxis
only transports the EPP's decision:

- Praxis-native load-aware scoring
- Praxis-native prefix-cache affinity
- Praxis-native saturation/admission gating
- Praxis-native P/D role routing
- Praxis-native InferenceModelRewrite
- Praxis-native InferenceObjective handling

## Running the Demos

### Setup

```bash
# Clone and build Praxis
git clone -b track-b-benchmarking https://github.com/nerdalert/praxis.git praxis-track-b
cd praxis-track-b && cargo build --release -p praxis --features ext-proc
export TRACK_B_DIR="$(pwd)"
cd ..

# Clone and build Go EPP
git clone https://github.com/llm-d/llm-d-router.git
cd llm-d-router && go build -o bin/epp ./cmd/epp && cd ..
export EPP_BIN="$(pwd)/llm-d-router/bin/epp"

# Clone and build Simulator
git clone https://github.com/llm-d/llm-d-inference-sim.git
cd llm-d-inference-sim && make build && cd ..
export SIM_BIN="$(pwd)/llm-d-inference-sim/bin/llm-d-inference-sim"
```

### Run

```bash
cd demo/llm-d-track-b

# 01 - Praxis-to-Go-EPP request path
bash scripts/01-praxis-to-go-epp-request-path/run-request-path.sh

# 02 - Failure behavior and recovery
bash scripts/02-failure-behavior-and-recovery/run-failure-recovery.sh

# 03 - Kubernetes Go EPP load-aware routing (also needs track-b impl branch)
export TRACK_B_IMPL_DIR=/path/to/praxis-track-b-impl  # git clone -b track-b ...
bash scripts/03-kubernetes-go-epp-load-aware-routing/run-kubernetes-load-aware.sh

# 04 - Benchmark results
# Open demo/llm-d-benchmarks/results.md
```

## What Track B Does Not Claim

- Not full Envoy ext_proc parity — request-phase only, no response-phase.
- Not native in-process endpoint picking — that is Track A.
- Not removal of the external Go EPP process.
- Not full Gateway API provider support.
- Not production GPU performance.
- Track B feature categories may mirror llm-d scheduling scenarios, but
  **ownership stays in Go EPP**. Track B validates the proxy replacement
  path, not native scheduling parity.

## Filter Configuration

```yaml
filter: llmd_external_epp
target: "http://127.0.0.1:9002"
request_timeout_ms: 10000
max_request_body_bytes: 4194304
status_on_error: 503
```

## Benchmark Results

See [llm-d Benchmark Results](../llm-d-benchmarks/results.md) for
`praxis-go-epp` vs `envoy-go-epp` comparison tables.

## Prerequisites

See [deploy.md](deploy.md) for full setup instructions.
