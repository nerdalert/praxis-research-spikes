# Track B Code Walkthrough

This walkthrough explains the current Track B implementation: Praxis uses the
generic Envoy-compatible `ext_proc` filter plus a generic `endpoint_selector`
filter to call the existing llm-d Go EPP and route the request to the selected
backend.

Implementation branch:
[`nerdalert/praxis:ext-proc-llm-d-praxis-poc-v2`](https://github.com/nerdalert/praxis/tree/ext-proc-llm-d-praxis-poc-v2)
at commit `d2ca1f1`.

## Short Version

Layman summary:

Praxis is standing where Envoy normally stands. The client sends an OpenAI-style
request to Praxis. Praxis sends the request headers and body to the existing Go
EPP over the standard `ext_proc` gRPC protocol. The Go EPP picks a backend and
returns that backend address as a header mutation. Praxis trusts that processor
mutation, strips the internal routing header, and forwards the request to the
selected backend.

Technical summary:

Track B is not a custom llm-d filter anymore. The current path composes two
generic filters:

- `ext_proc`: owns one full-duplex `ExternalProcessor.Process` stream per HTTP
  request.
- `endpoint_selector`: reads the trusted
  `x-gateway-destination-endpoint` mutation and sets `ctx.upstream`.

Response lifecycle support is future FD04 work. The accepted milestone proves
request routing through the unchanged Go EPP.

```text
Client
  |
  v
Praxis / Pingora
  |
  | 1. ext_proc sends RequestHeaders + RequestBody chunks
  v
Go EPP
  |
  | 2. Go EPP returns x-gateway-destination-endpoint
  v
Praxis endpoint_selector
  |
  | 3. set ctx.upstream, strip internal header
  v
Selected inference backend
```

## Code Map

Important implementation files in the Praxis branch:

| File | Role |
|---|---|
| `filter/ext-proc/src/lib.rs` | `ExtProcFilter`: config validation, lazy channel creation, full-duplex request hooks, EOS drain, mutation application. |
| `filter/ext-proc/src/duplex.rs` | `ExtProcExchange`: single-owner bidirectional stream state machine for `ExternalProcessor.Process`. |
| `filter/ext-proc/src/tests.rs` | Mock EPP tests, full-duplex exchange tests, request-routing behavior tests. |
| `filter/src/context.rs` | Request-scoped filter state, structured metadata, trusted pre-read mutation resolution. |
| `filter/src/builtins/http/traffic_management/endpoint_selector.rs` | Generic upstream selector from trusted header mutations. |
| `protocol/src/http/pingora/context.rs` | Pingora request context fields for pinned pipeline, filter state, and pre-read mutations. |
| `protocol/src/http/pingora/handler/request_filter/stream_buffer.rs` | Reads body chunks before normal request routing and records ordered trusted mutations. |
| `protocol/src/http/pingora/handler/request_filter/mod.rs` | Applies pre-read mutations to session and request snapshot, then runs the normal request pipeline. |
| `server/src/main.rs` | Registers `ext_proc` when the server is built with the `ext-proc` feature. |

## Request Flow

Layman summary:

Praxis has to show the Go EPP the same information Envoy would have shown it.
That means request headers first, then body chunks, then an end-of-body marker.
The Go EPP waits until it has the request body, chooses a backend, and sends the
backend address back to Praxis.

Technical sequence:

1. `ExtProcFilter::on_request()` starts the exchange and sends
   `RequestHeaders`.
2. StreamBuffer pre-read calls `ExtProcFilter::on_request_body()` for body
   chunks.
3. Each non-EOS body callback sends a `RequestBody` chunk with
   `end_of_stream=false`.
4. The EOS callback sends a synthetic empty `RequestBody` with
   `end_of_stream=true`.
5. `drain_exchange()` reads the deferred `RequestHeaders` response from the Go
   EPP.
6. Header mutations are applied to the filter context.
7. Request body responses are drained and coalesced.
8. `finish_sending()` half-closes the request stream.
9. `drain_trailing()` consumes remaining response messages so the h2 stream
   closes cleanly.
10. The normal request pipeline runs `endpoint_selector`.
11. `endpoint_selector` resolves the selected endpoint from trusted mutation
    provenance and sets `ctx.upstream`.
12. Pingora converts `ctx.upstream` into an upstream peer and forwards the
    request.

```text
on_request
  |
  | ensure_exchange_and_send_headers()
  | - build RequestHeaders
  | - preload first message
  | - store ExtProcState in filter_state
  v
StreamBuffer pre-read
  |
  | on_request_body(chunk)
  | - send RequestBody(chunk, eos=false)
  |
  | on_request_body(EOS)
  | - send RequestBody(empty, eos=true)
  | - drain deferred EPP responses
  | - apply header/body mutations
  v
normal request pipeline
  |
  | endpoint_selector
  | - resolve trusted endpoint mutation
  | - set ctx.upstream
  | - strip routing header
  v
upstream_peer -> backend
```

## `ExtProcFilter`

Layman summary:

`ExtProcFilter` is the part of Praxis that speaks the external-processor
protocol. It knows where the Go EPP lives, when to send headers and body, and
how to turn EPP responses back into Praxis request changes.

Technical walkthrough:

- `from_config()` parses the YAML config and validates unsupported modes early.
- `channel()` lazily creates the tonic `Channel` on first request, inside the
  request-processing runtime.
- `request_body_mode()` returns `BodyMode::StreamBuffer` for
  `full_duplex_streamed`, so Praxis pre-reads request body chunks through the
  body filter path.
- `on_request()` bootstraps the exchange and sends request headers.
- `on_request_body()` sends body chunks, sends terminal EOS, then drains the
  Go EPP responses.
- `on_response()` intentionally skips response-phase callout in full-duplex
  request-routing mode. Response lifecycle is FD04 scope.

```text
ExtProcFilter
  |
  +-- config validation
  +-- lazy gRPC channel
  +-- request header bootstrap
  +-- request body streaming
  +-- EOS response drain
  +-- request mutation application
```

Key behavior:

`ensure_exchange_and_send_headers()` is idempotent. This matters because the
body pre-read path can invoke `on_request_body()` before the normal `on_request`
pipeline has completed. The method stores `ExtProcState` in request-scoped
filter state so the same exchange is reused across callbacks.

## `ExtProcExchange`

Layman summary:

`ExtProcExchange` is the one live conversation with the Go EPP for a request. It
owns the gRPC stream, sends messages in order, reads replies, and makes sure
Praxis does not consume replies in the wrong phase.

Technical walkthrough:

- `open()` creates a capacity-1 request channel, preloads the first
  `ProcessingRequest`, constructs the tonic `process()` future, and returns
  without awaiting the server.
- The pending `process()` future is stored as
  `BootstrapState::Pending(SyncWrapper<PinnedProcessFuture>)`.
- `send()` validates the outbound transition, reserves bounded channel
  capacity, commits the message, then updates state with no await between commit
  steps.
- `receive()` resolves the pending process future if needed, reads the next
  processor response, applies timeout override rules, classifies the response,
  and validates output ordering.
- `finish_sending()` half-closes the request stream.
- `drain_trailing()` consumes remaining messages to avoid dropping the h2 stream
  while the server still has data.

```text
ExtProcExchange
  |
  +-- request_tx: capacity-1 mpsc sender
  +-- bootstrap:
  |     Pending(SyncWrapper<PinnedProcessFuture>)
  |     Ready(Streaming<ProcessingResponse>)
  |     Closed
  +-- request/response send phases
  +-- request/response output phases
  +-- active non-full-duplex processing deadline
```

Why it differs from the initial async-worker idea:

The accepted exchange does not spawn one background worker per request. The
pending tonic future stays owned by the exchange and is polled through `send()`
and `receive()`. This avoids extra task scheduling and keeps lifecycle,
cancellation, and backpressure local to the request.

## Request-Scoped Filter State

Layman summary:

Praxis needs to remember the EPP conversation between request headers and body
callbacks. Request-scoped filter state is the pocket where the filter keeps that
conversation.

Technical walkthrough:

- `HttpFilterContext` has typed `filter_state`.
- Each filter invocation gets a stable `filter_id`.
- State is keyed by `filter_id`, so two filters of the same type do not collide.
- Pingora context moves state into `HttpFilterContext` for a hook and writes it
  back afterward.
- Pipeline pinning keeps the same filter pipeline attached to the request even
  if configuration reloads while the request is in flight.

```text
PingoraRequestCtx
  |
  | filter_context! macro
  v
HttpFilterContext
  |
  | ExtProcFilter inserts ExtProcState
  v
PingoraRequestCtx
  |
  | next hook
  v
HttpFilterContext sees the same ExtProcState
```

## Trusted Header Provenance

Layman summary:

The backend address must come from the Go EPP, not from the client. Otherwise a
client could send `x-gateway-destination-endpoint` and try to route itself to an
arbitrary target.

Technical walkthrough:

- During pre-read, header mutations are recorded as ordered
  `TrustedHeaderMutation` entries.
- The log records `Remove`, `Set`, and `Add` operations.
- `resolve_trusted_header()` computes the final trusted value without reading
  original client headers.
- Distinct duplicate values are rejected as ambiguous.
- Identical duplicate values are accepted.
- Non-text bytes are preserved for `Set` with `HeaderValue`.

```text
Client header
  x-gateway-destination-endpoint: malicious:9999

Go EPP mutation
  Add x-gateway-destination-endpoint: backend:8000

endpoint_selector reads:
  trusted mutation log -> backend:8000

endpoint_selector never reads:
  original client header -> malicious:9999
```

## `endpoint_selector`

Layman summary:

The Go EPP returns the selected backend in a header mutation. The
`endpoint_selector` filter turns that trusted header value into the Praxis
upstream target.

Technical walkthrough:

- Reads `source_header`, usually `x-gateway-destination-endpoint`.
- Checks pending mutations first, then trusted pre-read mutations.
- Does not read original request headers.
- Validates `host:port`, including DNS names, IPv4, and bracketed IPv6.
- Sets `ctx.upstream`.
- In `required: true` mode, rejects missing or invalid destinations with the
  configured status, normally 503 for Track B.
- Strips the internal routing header from:
  - removal queue
  - pending extra headers
  - pending set headers
  - pre-read mutation provenance

```text
trusted mutation
  |
  v
endpoint_selector
  |
  +-- validate host:port
  +-- ctx.upstream = selected backend
  +-- strip internal header
  v
Pingora upstream_peer
```

## How This Replaces Envoy In The llm-d Path

Envoy baseline:

```text
Client
  -> Envoy ext_proc filter
  -> Go EPP
  -> x-gateway-destination-endpoint
  -> Envoy ORIGINAL_DST cluster
  -> backend
```

Track B:

```text
Client
  -> Praxis generic ext_proc filter
  -> Go EPP
  -> x-gateway-destination-endpoint
  -> Praxis endpoint_selector
  -> ctx.upstream
  -> backend
```

What stays the same:

- Go EPP remains the scheduler.
- Go EPP receives Envoy ext_proc protobuf messages.
- The selected endpoint still comes back as
  `x-gateway-destination-endpoint`.

What changes:

- Praxis replaces Envoy as the HTTP proxy runtime.
- Praxis uses `ctx.upstream` instead of Envoy `ORIGINAL_DST`.
- Trusted routing-header provenance is enforced by the filter pipeline.

## Current Boundaries

This walkthrough describes the accepted request-routing milestone.

Not included yet:

- FD04 response lifecycle.
- Request trailers, blocked by a Pingora platform boundary.
- Full Envoy ext_proc parity.
- Native in-process scheduling; that is Track A.
- Removing the Go EPP.

## Validation Evidence

The implementation has been validated with:

- `183` ext-proc tests.
- Parallel and single-threaded exchange tests.
- Local request-routing smoke with eight wire-level assertions.
- KIND request-routing smoke with five assertions.
- Fresh benchmark runs for Track B and Baseline with clean gRPC stream closure.

See:

- [Architecture and PR Stack](architecture-and-pr-stack.md)
- [Sample Output](sample-output.md)
- [Benchmark Results](../llm-d-benchmarks/results.md)
