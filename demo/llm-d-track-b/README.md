# Track B: Praxis Full-Duplex ext_proc with Go EPP

> **Current refinement path:** Track B is currently refining only the
> Praxis generic `ext_proc` + `endpoint_selector` integration for llm-d
> request routing. The accompanying benchmark material provides context
> for understanding data-plane performance tradeoffs. This is not a
> proposal to replace all of llm-d or to present multiple competing
> implementation paths.

| Resource | Link |
|----------|------|
| Architecture and PR Stack | [architecture-and-pr-stack.md](architecture-and-pr-stack.md) |
| Code Walkthrough | [code-walkthrough.md](code-walkthrough.md) |
| Deployment Guide | [deploy.md](deploy.md) |
| Demo Scripts | [scripts/](scripts/) |
| Sample Output | [sample-output.md](sample-output.md) |
| Benchmark Results | [../llm-d-benchmarks/results.md](../llm-d-benchmarks/results.md) |
| ext_proc Praxis/llm-d POC Branch | [`nerdalert/praxis:ext-proc-llm-d-praxis-poc-v2`](https://github.com/nerdalert/praxis/tree/ext-proc-llm-d-praxis-poc-v2) |
| Praxis llm-d Epic | [praxis-proxy/praxis#413](https://github.com/praxis-proxy/praxis/issues/413) |
| Base Praxis PR | [praxis-proxy/praxis#428](https://github.com/praxis-proxy/praxis/pull/428) |

## What Track B Proves

Track B proves **Praxis can replace Envoy as the proxy data plane** while
the existing Go EPP remains the scheduler. Praxis uses the standard Envoy
`ext_proc` gRPC protocol to call the Go EPP through one persistent
full-duplex `ExternalProcessor.Process` stream per HTTP request. The Go EPP
makes its scheduling decision and returns the selected backend endpoint as a
header mutation. Praxis applies the mutation and forwards the request to the
selected backend.

> **Claim boundary:** In Track B, Praxis is the proxy. Go EPP is the
> scheduler. Praxis does not claim native model-aware, load-aware,
> prefix-cache, P/D, or policy behavior. Those scheduling decisions
> happen inside the Go EPP. Praxis transports and applies the EPP's
> decision.

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

### Track B (Praxis + Go EPP — Full-Duplex)

```
Client
  -> Praxis / Pingora (generic ext_proc filter, full-duplex streamed)
  -> one ExternalProcessor.Process bidirectional gRPC stream to Go EPP
      - preload RequestHeaders into the stream
      - send RequestBody chunks incrementally during StreamBuffer pre-read
      - send terminal RequestBody(end_of_stream=true) at EOS
      - Go EPP responds with endpoint selection at body EOS
  -> endpoint_selector reads x-gateway-destination-endpoint from trusted mutations
  -> strips the internal routing header from session and snapshot
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

## Track A vs Track B

| | Track A | Track B |
|---|---|---|
| **What Praxis does** | Parses model, scores endpoints, selects upstream | Calls Go EPP via ext_proc, applies EPP's endpoint selection |
| **What runs scheduling** | Praxis `llmd_endpoint_picker` (in-process) | Go EPP (external process) |
| **Envoy in path** | No | No |
| **Go EPP in path** | No | Yes |
| **What the demo proves** | Praxis-owned scheduling features | Praxis carries the Go EPP scheduling decision without Envoy |

## Filter Configuration

```yaml
filters:
  - filter: ext_proc
    target: "http://go-epp:9002"
    message_timeout_ms: 5000
    lifecycle_timeout_ms: 10000
    status_on_error: 503
    processing_mode:
      request_header_mode: send
      response_header_mode: skip
      request_body_mode: full_duplex_streamed
      response_body_mode: none
      request_trailer_mode: skip
      response_trailer_mode: skip
  - filter: endpoint_selector
    source_header: x-gateway-destination-endpoint
    required: true
    status_on_required_failure: 503
    strip_header: true
```

## Demo Matrix

### Validated Demos

| # | Demo | Environment | What it proves |
|---|---|---|---|
| 01 | Local request routing | Local processes | Client -> Praxis ext_proc -> Go EPP -> backend. Correct model, malicious header ignored, header stripped, body preserved, one Process stream, exact 503, restart recovery. |
| 02 | KIND deployment | KIND cluster | Same composition in Kubernetes. EPP failure/recovery, image identity, no h2 resets. |
| 03 | Benchmark comparison | Local benchmark | `praxis-ext-proc-full-duplex-go-epp` vs `envoy-go-epp`. |

## Running the Demos

### Prerequisites

See [deploy.md](deploy.md) for full setup instructions including
Go EPP, inference simulator, and Praxis build requirements.

### Local Request Routing (8 assertions)

```bash
bash scripts/local-request-routing/run-request-routing.sh
```

### KIND Deployment (5 assertions)

```bash
bash scripts/kind-request-routing/run-request-routing.sh
```

## What Track B Does Not Prove

- Not full Envoy ext_proc parity — request-phase only; response-phase
  lifecycle (FD04) is remaining work.
- Not native in-process endpoint picking — that is Track A.
- Not removal of the external Go EPP process.
- Not full Gateway API provider support.
- Not production GPU inference performance.
- Not byte-identical request body preservation — JSON field order may be
  normalized by the proxy path. Semantic content is preserved without
  duplication.
- Request trailer processing is not available due to a Pingora platform
  boundary.

## Historical Context

The earlier Track B prototype used a custom `llmd_external_epp` filter that
buffered the entire request body before calling the Go EPP in a single-shot
exchange. The current implementation replaces this with the generic Praxis
`ext_proc` filter using full-duplex streaming, a single-owner pending
Process driver (no per-exchange spawned tasks), and a separate
`endpoint_selector` filter for trusted upstream selection.

## Benchmark Results

See [llm-d Benchmark Results](../llm-d-benchmarks/results.md) for
`praxis-ext-proc-full-duplex-go-epp` vs `envoy-go-epp` comparison.
