# Track B: Praxis with Go EPP

Track B replaces Envoy with Praxis at the proxy edge while keeping the existing Go EPP as the scheduling brain.

## Request Path

```text
Client
  -> Praxis / Pingora
  -> llmd_external_epp HttpFilter
  -> ext_proc gRPC call (request headers + buffered body)
  -> Go EPP scheduler (file discovery, random picker)
  -> x-gateway-destination-endpoint response header
  -> Praxis sets ctx.upstream from EPP-selected endpoint
  -> selected inference backend
```

## What Track B Proves

- Praxis can call the real Go EPP through an ext_proc-compatible gRPC client.
- The Go EPP's `x-gateway-destination-endpoint` header correctly selects the upstream.
- Request headers and the complete buffered body traverse the ext_proc stream.
- Go EPP streamed body response chunks are reassembled.
- `ctx.upstream` set during body pre-read survives StreamBuffer and is honored by Pingora for upstream selection.
- Content-Length is repaired by the protocol layer after body mutation.
- EPP unavailability returns the configured `status_on_error` (fail-closed).
- Oversized request bodies are rejected with 413 before calling the EPP.
- The tonic gRPC channel reconnects after EPP restart (lazy `OnceCell` init).
- The h2 stream drain prevents `ENHANCE_YOUR_CALM` under sustained load.

## What Track B Does Not Prove

- Response-phase ext_proc (not implemented).
- Full Envoy ext_proc parity (Track B is a narrow request-phase-only client).
- Kubernetes-only EPP plugins (`InferenceModelRewrite`, `InferenceObjective`, etc.).
- True Envoy append header semantics (Track B uses overwrite, which is compatible with the Go EPP's echo pattern but not spec-correct for general ext_proc).
- Client-disconnect cancellation propagation to the Go EPP (timeout cancellation is tested; client disconnect is not).
- GPU-backed inference or real model scheduling quality.

## Filter: `llmd_external_epp`

```yaml
filter: llmd_external_epp
target: "http://127.0.0.1:9002"
request_timeout_ms: 10000
max_request_body_bytes: 4194304
status_on_error: 503
```

- Requires the `ext-proc` Cargo feature: `cargo build -p praxis --features ext-proc`.
- Buffers the full request body (`BodyMode::StreamBuffer`).
- Calls `process_request_phase()` at `end_of_stream = true`.
- Returns `FilterAction::Reject` for all EPP errors (always fail-closed).
- `ImmediateResponse` from the EPP preserves the EPP's status and body.

## Local Smoke

The local smoke proves the complete request path without Kubernetes:

```bash
cd demo/llm-d-track-b
TRACK_B_DIR=/path/to/track-b bash scripts/run-local-smoke.sh
```

Verifies: HTTP 200 with unique model name, 413 for oversized body (no EPP call), 503 for EPP unavailable.

## KIND Smoke

The KIND smoke proves the same path in Kubernetes:

```bash
cd demo/llm-d-track-b
TRACK_B_DIR=/path/to/track-b bash scripts/run-kind-smoke.sh
```

Verifies: HTTP 200, EPP log contains unique model and simulator ClusterIP, exact 503 on EPP scale-to-zero, recovery after EPP restart (restarted pod log verified).

## Benchmark Results

See [llm-d Benchmark Results](../llm-d-benchmarks/results.md) for Track B benchmark numbers compared against Track A and the Envoy baseline.
