# Track B: Architecture and Upstream PR Breakdown

## Executive Summary

Track B adds a generic full-duplex `ext_proc` gRPC client to Praxis so it
can call the existing Go EPP (Endpoint Picker/Proxy) for inference
scheduling. Praxis replaces Envoy at the proxy edge but does not replace the
Go EPP scheduler.

The implementation uses Envoy's standard `ExternalProcessor.Process`
bidirectional streaming protocol — not a custom filter. One persistent gRPC
stream per HTTP request carries request headers and body to the Go EPP. The
Go EPP makes its scheduling decision at body EOS and returns an endpoint
header mutation. A separate generic `endpoint_selector` filter reads the
trusted mutation and sets the upstream.

This is a request-routing milestone. The llm-d Go EPP scheduling decision
happens on the request path at body EOS, so response-phase lifecycle support
is not required for this milestone.

## Implementation Branch

The current implementation is on the
[ext_proc Praxis/llm-d POC branch](https://github.com/nerdalert/praxis/tree/ext-proc-llm-d-praxis-poc-v2)
at commit `d2ca1f1`.

## Request Path

```text
Client HTTP request
  |
  v
Praxis / Pingora HTTP listener
  |
  v
ext_proc filter (full_duplex_streamed mode)
  |-- open(): construct Process future + preload RequestHeaders
  |-- on_request_body(): send body chunks via select!-driven bootstrap
  |-- on_request_body(EOS): send terminal body, drain responses
  |-- receive(): resolve pending Process future, read header/body responses
  |-- apply mutations to filter context
  |
  v
endpoint_selector filter (required: true, strip_header: true)
  |-- resolve x-gateway-destination-endpoint from trusted mutation log
  |-- reject if absent (fail-closed, HTTP 503)
  |-- set ctx.upstream
  |-- strip routing header from session, snapshot, and provenance
  |
  v
Pingora upstream_peer
  |-- convert ctx.upstream to HttpPeer
  |
  v
Selected inference backend
```

## Component Responsibilities

| Component | Responsibility |
|-----------|---------------|
| `ext_proc` filter | Generic Envoy ext_proc gRPC client. Opens one Process stream per request. Sends headers and body incrementally. Drains responses at EOS. Applies header/body mutations and structured metadata. |
| `ExtProcExchange` | Single-owner duplex exchange state machine. Validates send/receive ordering, manages timeouts, classifies response events. No background tasks. |
| `SyncWrapper<PinnedProcessFuture>` | Wraps the pending tonic Process future for Sync compatibility. Polled inline from send() via select!, resolved by receive(). |
| `endpoint_selector` filter | Reads a configured header from trusted pre-read mutations. Validates host:port. Sets ctx.upstream. Strips the internal header. Configurable required mode with exact failure status. |
| `TrustedHeaderMutation` | Ordered mutation log preserving pre-read remove/set/add operations. Resolved by endpoint_selector without consulting original client headers. |
| Go EPP | Unchanged external process. Receives ext_proc requests, runs scheduling (discovery, scoring, selection), returns endpoint via header mutation. |

## Single-Owner Process Stream Lifecycle

```text
open()
  |-- create capacity-1 mpsc channel
  |-- preload first ProcessingRequest (headers + protocol config) via try_send
  |-- construct pinned Process future (owns client + ReceiverStream)
  |-- wrap in SyncWrapper for Sync bound
  |-- store as BootstrapState::Pending
  |-- return exchange (synchronous, no await)

send(body_chunk)
  |-- validate state transition
  |-- reserve_while_bootstrapping:
  |     select! {
  |       tx.reserve() => return permit (preserve Pending)
  |       pending_future => store Ready(response_stream), continue reserve
  |     }
  |-- commit message via permit.send()
  |-- update phase and deadline atomically

receive()
  |-- ensure_response_stream: await Pending future if not yet Ready
  |-- read from Ready stream
  |-- classify response event (headers, body, immediate, etc.)
  |-- validate processor output ordering

drain_complete
  |-- finish_sending: half-close request channel
  |-- drain_trailing: consume remaining server responses until EOF
  |-- clean h2 stream close (no RST_STREAM)

drop
  |-- drops SyncWrapper(pending future) or Ready(stream)
  |-- drops tx (closes request channel)
  |-- no detached task remains
```

## Request-Routing Flow: ext_proc to endpoint_selector

1. During StreamBuffer pre-read, the `ext_proc` filter sends request headers
   and body chunks to the Go EPP through the Process stream.

2. The Go EPP buffers the request, makes its scheduling decision at body
   EOS, and responds with a `HeaderMutation` containing
   `x-gateway-destination-endpoint: host:port`.

3. The `ext_proc` filter applies the mutation to the filter context's
   `extra_request_headers`. The protocol layer captures these as
   `TrustedHeaderMutation::Add` operations in the ordered pre-read mutation
   log.

4. After pre-read, the normal request pipeline runs. The `endpoint_selector`
   filter resolves `x-gateway-destination-endpoint` from the trusted
   mutation log — never from original client headers.

5. The selector validates the endpoint, sets `ctx.upstream`, and strips the
   internal routing header from pending mutations, session headers, request
   snapshot, and pre-read provenance.

6. Pingora's `upstream_peer` converts `ctx.upstream` to an `HttpPeer` and
   forwards the request.

## How This Differs from Envoy ext_proc

| Aspect | Envoy | Praxis Track B |
|--------|-------|---------------|
| Filter | Built-in ext_proc filter | Generic `ext_proc` filter (opt-in feature) |
| Stream | Per-phase callouts or bidirectional | One full-duplex bidirectional stream per request |
| Body mode | Buffered, streamed, or none | Full-duplex streamed (concurrent send/receive) |
| Endpoint selection | ORIGINAL_DST cluster | `endpoint_selector` filter with trusted mutation provenance |
| Bootstrap | Awaits process() response | Single-owner pending future, polled inline |
| Response phase | Full response lifecycle | Not needed for llm-d request routing; FD04 follow-up for broader parity |

## Base: Praxis PR #428

All Track B full-duplex work builds on PR #428, which added:

- Header-phase ext_proc tonic client foundations
- Proto type generation for Envoy ext_proc
- Request/response header conversion
- Header mutation application with full `HeaderAppendAction` semantics
- `ExtProcFilter` for header-only callouts
- Unit tests with mock gRPC server

PR #428 is the assumed base, not one of the three full-duplex PRs.

## Full-Duplex Implementation PRs

### PR 1: Request-Scoped Filter State and Pipeline Pinning

**Status:** Accepted

**Scope:**
- Per-request typed filter state keyed by stable filter invocation ID
- Pipeline pinning to survive hot configuration reload mid-request
- Filter identity for branch chains
- Set-before/clear-after lifecycle for `current_filter_id`

**Why it matters:**
The duplex exchange must persist across `on_request` and `on_request_body`
hooks. Per-filter state provides type-safe storage without global maps or
Arc<Mutex>. Pipeline pinning ensures the same filter instance handles both
hooks even during live config reload.

**Evidence:** 15 focused unit tests, hot-reload lifecycle tests, branch
identity tests.

### PR 2: Single-Owner Duplex Exchange Core

**Status:** Accepted

**Scope:**
- `ExtProcExchange` with six orthogonal state domains
- Transactional send: validate → reserve → commit → update (no await
  between commit steps)
- Typed response classification with processor-output ordering validation
- Per-message timeout with processor-requested override support
- Capacity-1 bounded request channel
- Direction-independent send/receive phase tracking
- `SyncWrapper<PinnedProcessFuture>` bootstrap state
- `BootstrapState::Pending` / `Ready` / `Closed` lifecycle

**Why it matters:**
The Go EPP requires a persistent bidirectional stream — not one-shot
callouts. The exchange owns one Process invocation with no spawned tasks,
enforces protocol ordering, and provides bounded backpressure through the
capacity-1 channel.

**Evidence:** 80+ duplex exchange tests covering state transitions, timeout
behavior, override handling, cancellation, concurrent exchanges, and
Send+Sync compile-time assertions.

### PR 3: Generic Full-Duplex Request-Routing Integration

**Status:** Accepted (request routing)

**Scope:**
- Full-duplex `request_body_mode: full_duplex_streamed` config and validation
- First-message preload for Go EPP compatibility
- `ensure_exchange_and_send_headers()` idempotent bootstrap
- Coalesced EOS drain with bounded lifecycle timeout
- `endpoint_selector` filter with trusted mutation provenance
- `TrustedHeaderMutation` ordered log (remove/set/add)
- `resolve_trusted_header()` with ambiguity rejection
- Configurable `status_on_required_failure` (default 500, Track B uses 503)
- Fail-closed via `Reject` (not `Err`), immune to `failure_mode: open`
- Routing header stripping from session, snapshot, and provenance
- Pre-read mutation preservation with `std::mem::take` (no deep clones)
- `Set` stores raw `HeaderValue` to preserve non-text bytes
- Server binary ext_proc feature registration
- Lazy runtime-local gRPC channel initialization

**Why it matters:**
This PR connects the exchange core to the Praxis filter pipeline and the
unchanged Go EPP. It proves the full request-routing path: pre-read body
processing, EPP communication, trusted endpoint selection, and upstream
forwarding — all without a custom filter or legacy compatibility layer.

**Evidence:** 100+ integration tests, 8-assertion local smoke, 5-assertion
KIND deployment, two clean-start smoke runs.

**Remaining work:** Broader `ext_proc` parity, especially response lifecycle,
is future work. It is not a blocker for the accepted llm-d request-routing
path.

## Non-Blocking Follow-Up Work

These items are useful for broader Envoy `ext_proc` parity and future llm-d
features, but they are not required for the llm-d request-routing path proven here.

| Item | Needed for current llm-d request routing? | Scope |
|------|---|-------|
| FD04A | No | Async multi-output response body foundation for future response lifecycle work. |
| FD04B | No | Complete response lifecycle integration for response metadata, response body processing, usage/eviction-style flows, and broader parity. |
| Request trailers | No | Blocked on a Pingora platform boundary; not used by the current Go EPP request-routing path. |
| Full Envoy `ext_proc` parity | No | Broader compatibility work such as response phases, mode overrides, and full mutation-rule coverage. |
