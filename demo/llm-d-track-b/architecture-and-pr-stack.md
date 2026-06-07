# Track B: Architecture and Upstream PR Breakdown

## Executive Summary

Track B adds an ext_proc-compatible gRPC client to Praxis so it can call the existing Go EPP (Endpoint Picker/Proxy) for inference scheduling. Praxis replaces Envoy at the proxy edge but does not replace the Go EPP scheduler.

The implementation is a narrow request-phase-only ext_proc client — not full Envoy ext_proc parity. It proves that Praxis can serve as a drop-in proxy replacement for Envoy in the llm-d request path while keeping the Go EPP scheduling decision intact.

## Track B Request Path

```text
Client
  -> Praxis / Pingora (HTTP listener)
  -> llmd_external_epp HttpFilter (on_request_body, StreamBuffer mode)
  -> ext_proc gRPC bidirectional stream to Go EPP
     -> send ProcessingRequest::RequestHeaders
     -> send ProcessingRequest::RequestBody (end_of_stream=true)
     -> read ProcessingResponse::RequestHeaders (with x-gateway-destination-endpoint)
     -> read ProcessingResponse::RequestBody (streamed chunks, reassembled)
     -> drain trailing responses (5ms timeout, prevents h2 ENHANCE_YOUR_CALM)
  -> set ctx.upstream from EPP-selected endpoint
  -> apply request header mutations
  -> replace body if EPP mutated it
  -> FilterAction::Release (forward buffered body to upstream)
  -> selected inference backend
```

## What PR #428 Provided

Track B builds on top of Praxis PR #428, which added:

- Header-phase ext_proc tonic client foundations (`callout.rs`, `mutations.rs`)
- Proto type generation for Envoy ext_proc (`praxis-proto` crate)
- Request/response header conversion between Praxis `HttpFilterContext` and ext_proc `HttpHeaders`
- Header mutation application (append, overwrite, remove) with full `HeaderAppendAction` semantics
- `ExtProcFilter` for header-only ext_proc callouts
- Unit tests with fake gRPC server

Track B extends PR #428's header-only callout into a full request-phase exchange (headers + body on a single stream) and adds the `llmd_external_epp` filter that integrates it into the Praxis pipeline.

## What Track B Added

### Request-phase stream helper (`request_phase.rs`)

- Opens one `ExternalProcessor.Process` bidirectional gRPC stream
- Sends `RequestHeaders` then terminal `RequestBody` on the same stream
- Reads header response, then one or more body responses
- Handles Go EPP's `StreamedResponse` chunks (62 KB max each), reassembles into contiguous body
- Fail-closed: incomplete streamed sequences, mixed mutation types, and stream closure before `end_of_stream=true` are errors
- Drains trailing responses with 5ms timeout to prevent h2 `too_many_internal_resets` under sustained load
- Extracts `x-gateway-destination-endpoint` from header response mutations (case-insensitive)

### `llmd_external_epp` filter (`llmd_external_epp.rs`)

- Buffers the full request body via `BodyMode::StreamBuffer`
- Calls `process_request_phase()` at `end_of_stream=true` — exactly one EPP call per request
- Sets `ctx.upstream` from EPP-selected endpoint (validated: IPv4, DNS, bracketed IPv6, port 1-65535)
- Applies request header mutations from EPP response
- Replaces body if EPP mutated it (content-length repaired by protocol layer)
- All EPP errors return `FilterAction::Reject(status_on_error)` — always fail-closed, even if pipeline `failure_mode` is open
- `ImmediateResponse` from EPP preserves EPP's status and body
- Lazy tonic channel via `tokio::sync::OnceCell` (deferred from `from_config` to first request)

### StreamBuffer pre-read mutation preservation (`protocol` crate)

- `PreReadMutations` struct carries `request_headers_to_remove`, `request_headers_to_set`, and `extra_request_headers` from body-phase filters through StreamBuffer pre-read
- Without this fix, PR #428's `OverwriteIfExistsOrAdd` and removal mutations were silently dropped during body pre-read

### Server registration

- `build_default_registry()` adds `ext_proc` and `llmd_external_epp` when the `ext-proc` Cargo feature is enabled
- CLI validation (`--validate`, `--dump`) wrapped in a temporary tokio runtime for tonic `connect_lazy` compatibility
- Registration failures call `fatal()` (process exit) — invariant failure, matching existing Praxis convention

## Local Process Demo Architecture

```text
                    ┌─────────────┐
                    │   Client    │
                    │  (curl/     │
                    │   vegeta)   │
                    └──────┬──────┘
                           │ HTTP POST /v1/chat/completions
                    ┌──────▼──────┐
                    │   Praxis    │ :18090 (or :18091 for smoke)
                    │ llmd_ext_epp│
                    └──────┬──────┘
                           │ ext_proc gRPC (tonic)
                    ┌──────▼──────┐
                    │   Go EPP    │ :9002 gRPC
                    │ file disc.  │
                    └──────┬──────┘
                           │ x-gateway-destination-endpoint
                    ┌──────▼──────┐
                    │  Simulator  │ :18080
                    │ (or mock)   │
                    └─────────────┘
```

The local smoke (`e2e/local-go-epp/run-smoke.sh`) starts all three processes, sends a request with a unique per-run model name, and verifies:
- HTTP 200 with correct model in response and EPP log
- HTTP 413 for oversized body (EPP log proves no EPP call)
- HTTP 503 when EPP is stopped

## KIND Demo Architecture

```text
                    ┌─────────────┐
                    │   Client    │
                    │  (curl)     │
                    └──────┬──────┘
                           │ NodePort :30092
                    ┌──────▼──────┐
                    │   Praxis    │ Deployment + NodePort Service
                    │ llmd_ext_epp│
                    └──────┬──────┘
                           │ ClusterIP Service :9002
                    ┌──────▼──────┐
                    │   Go EPP    │ Deployment + ClusterIP Service
                    │ ConfigMap   │ (file discovery, patched endpoint)
                    └──────┬──────┘
                           │ Simulator ClusterIP :8000
                    ┌──────▼──────┐
                    │  Simulator  │ Deployment + ClusterIP Service
                    └─────────────┘
```

The KIND smoke (`e2e/kind-go-epp/run-kind-smoke.sh`) builds three container images, creates a dedicated `llmd-track-b` cluster, deploys with dynamically patched EPP endpoints, and verifies:
- HTTP 200 with unique model in response, EPP log, and simulator endpoint IP
- HTTP 503 after scaling EPP to zero
- HTTP 200 recovery after EPP scale-up (verified through restarted pod logs)

## What Is Proven

- Praxis calls the real Go EPP through ext_proc-compatible gRPC
- Go EPP file discovery works without modification
- Go EPP streamed body response chunks are correctly reassembled
- `ctx.upstream` set during body pre-read is honored by Pingora for upstream connection
- Request header mutations (append, overwrite, remove) survive StreamBuffer pre-read
- Content-Length is repaired by the protocol layer after body mutation
- Lazy tonic channel reconnects after EPP restart
- h2 stream drain prevents connection-level errors under sustained load
- The complete path works in both local-process and KIND Kubernetes deployments

## What Is Not Proven

- Response-phase ext_proc (not implemented)
- Full Envoy ext_proc parity (request-phase only, narrow scope)
- True Envoy append header semantics (overwrite semantics work for Go EPP but deviate from spec)
- Client-disconnect cancellation propagation (timeout cancellation is tested)
- Kubernetes-only EPP plugins (`InferenceModelRewrite`, `InferenceObjective`)
- GPU-backed inference or real scheduling quality
- Production TLS/mTLS, service mesh, or auth integration

## Risks and Deferred Work

| Risk | Status | Impact |
|---|---|---|
| Overwrite-vs-append header semantics | Known deviation | Works for Go EPP; would break processors relying on true multi-value append |
| Go EPP plugins requiring K8s state | Not tested | File discovery proves the handoff; full K8s plugins may need additional data |
| Response-phase ext_proc | Not implemented | Some processors expect response-phase callbacks |
| h2 connection sharing under extreme load | Mitigated by drain | The 5ms drain timeout is a pragmatic bound, not a protocol guarantee |
| Endpoint validation edge cases | DNS labels validated | Malformed but syntactically valid hostnames could reach upstream |

## Upstream PR Breakdown

### PR-core-1: Pre-read body mutation plumbing

**Scope**: Praxis core prerequisite — does not depend on ext-proc or llm-d.

- `PreReadMutations` struct in `stream_buffer.rs`
- `apply_pre_read_mutations_to_request` / `_to_session` in `mod.rs`
- Collects `request_headers_to_remove`, `request_headers_to_set`, and `extra_request_headers` from body-phase filters through StreamBuffer pre-read
- Applies in order: remove, set, extra
- 6 protocol tests proving remove/set/extra/ordering/noop behavior

### PR-B01: ext_proc request-phase client foundation

**Scope**: `filter/ext-proc/src/request_phase.rs` and related test infrastructure.

- `process_request_phase()`: opens one `ExternalProcessor.Process` stream, sends headers + body, reads responses
- `RequestPhaseResult` and `RequestPhaseError` types
- Go EPP `StreamedResponse` chunk handling with reassembly
- Fail-closed: `IncompleteBodyStream` error for incomplete/mixed sequences
- `drain_stream()` with 5ms timeout preventing h2 `ENHANCE_YOUR_CALM`
- `response_variant_name` visibility change in `callout.rs`
- Fake EPP mock with `AtomicUsize` call counter
- `CancellationObserverMock` / `ResponseCancellationMock` for stream lifecycle tests

### PR-B02: `llmd_external_epp` filter

**Scope**: `filter/ext-proc/src/llmd_external_epp.rs` and filter tests.

- Filter config: `target`, `request_timeout_ms`, `max_request_body_bytes`, `status_on_error`
- `BodyAccess::ReadWrite`, `BodyMode::StreamBuffer { max_bytes }`
- Calls `process_request_phase()` at `end_of_stream=true`
- Extracts and validates `x-gateway-destination-endpoint` (IPv4, DNS, bracketed IPv6, port 1-65535)
- Sets `ctx.upstream` from EPP-selected endpoint
- Applies header mutations, replaces body if mutated
- All EPP errors → `FilterAction::Reject(status_on_error)` (not `FilterError`)
- `ImmediateResponse` preserves EPP status
- Lazy tonic channel via `OnceCell<Channel>`
- `praxis-core` dependency for `Upstream` / `ConnectionOptions`
- Config, capability, integration, validation, and cardinality tests

### PR-B03: Server registration and validation

**Scope**: `server/` crate changes.

- `build_default_registry()`: extends `FilterRegistry::with_builtins()` with `ext_proc` and `llmd_external_epp` when `--features ext-proc`
- `register_ext_proc_filters()`: `fatal()` on duplicate (invariant failure)
- `praxis-ext-proc` optional dependency gated on `ext-proc` feature
- `commands.rs`: tokio runtime wrapper for CLI validation (`connect_lazy` compatibility)
- Registration tests: registry contains filters, valid/invalid config validation through production `validate_config_for_startup` path

### PR-B04: Failure modes and hardening

**Scope**: Tests and documentation proving fail-closed behavior.

- EPP call cardinality: zero before EOS, exactly one at EOS, no retry after timeout/error
- Server-observed response-stream cancellation on timeout (`tx.closed()`)
- `failure_mode: open` pipeline test: `Reject` survives open mode
- Endpoint validation: `[not-ipv6]:8080`, `bad/host:8080`, DNS label rules, RFC 952/1123 length limits
- Example config: `examples/configs/ai/llmd-external-epp.yaml`
- Production validation tests via `commands::validate_config_for_startup`

### PR-B05: Local and KIND e2e smoke harness

**Scope**: `e2e/` directory (not upstreamed to Praxis).

- `e2e/local-go-epp/`: local-process smoke with process-owned readiness, unique model verification, 413 no-EPP-call proof, exact 503
- `e2e/kind-go-epp/`: KIND deployment with `Containerfile.praxis-track-b`, manifests, simulator ClusterIP patching, EPP `--v=3` for endpoint logging, recovery pod verification
- Dedicated cluster policy, bounded cleanup, image evidence

### PR-B06: Benchmark branch (not upstream implementation)

**Scope**: `track-b-benchmarking` branch only. Not part of the upstream implementation PRs.

- Separate Praxis copy at `praxis-track-b-benchmarking/`
- `run-same-backend-benchmark.sh`: 3-profile Go mock comparison
- `run-track-b-sim-benchmark.sh`: 3-profile simulator echo
- `run-track-b-large-prompt.sh`: body-size scaling (16K/64K/256K)
- `run-track-b-guidellm-sim.sh`: GuideLLM concurrent profile
- Go mock backend for 100% success under open-loop load
- h2 drain fix backported from benchmark worktree to implementation tree
- Results feed `demo/llm-d-benchmarks/results.md`

### PR-B07: Public demo docs

**Scope**: `demo/llm-d-track-b/` in the research spikes repo.

- Track B demo README
- Architecture and PR breakdown (this document)
- Claim boundaries
