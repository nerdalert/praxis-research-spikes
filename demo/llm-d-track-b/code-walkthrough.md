# Track B Code Walkthrough

This walkthrough explains the current Track B implementation: Praxis uses the
generic Envoy-compatible `ext_proc` filter plus a generic `endpoint_selector`
filter to call the existing llm-d Go EPP and route the request to the selected
backend.

Implementation branch:
[`nerdalert/praxis:ext-proc-llm-d-praxis-poc-v2`](https://github.com/nerdalert/praxis/tree/ext-proc-llm-d-praxis-poc-v2)
at commit `d2ca1f1`.

## Short Version

**Summary:**

Praxis is standing where Envoy normally stands. The client sends an OpenAI-style
request to Praxis. Praxis sends the request headers and body to the existing Go
EPP over the standard `ext_proc` gRPC protocol. The Go EPP picks a backend and
returns that backend address as a header mutation. Praxis trusts that processor
mutation, strips the internal routing header, and forwards the request to the
selected backend.

**Technical summary:**

Track B is not a custom llm-d filter anymore. The current path composes two
generic filters:

- `ext_proc`: owns one full-duplex `ExternalProcessor.Process` stream per HTTP
  request.
- `endpoint_selector`: reads the trusted
  `x-gateway-destination-endpoint` mutation and sets `ctx.upstream`.

This milestone proves the llm-d request-routing path: request headers, request
body, Go EPP endpoint selection, trusted mutation handling, and upstream
forwarding. Full response-phase lifecycle support is FD04 follow-up work.

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

| File | Primary code | Why it matters |
|---|---|---|
| `filter/ext-proc/src/lib.rs` | `ExtProcFilter`, config validation, `ensure_exchange_and_send_headers()`, `drain_exchange()`, body response coalescing, dynamic metadata conversion. | This is the filter integration point. It maps Praxis filter hooks onto Envoy `ext_proc` messages, keeps the Go EPP call inside request processing, and converts processor responses back into header/body mutations. |
| `filter/ext-proc/src/duplex.rs` | `ExtProcExchange`, `BootstrapState`, `ExchangeEvent`, `SendPhase`, `OutputPhase`, `ActiveProcessingState`, timeout override handling. | This is the full-duplex transport core. It owns one `ExternalProcessor.Process` RPC, enforces ordering, manages backpressure, avoids per-request worker tasks, and makes the async behavior reviewable in one state machine. |
| `filter/ext-proc/src/mutations.rs` | Request/response header conversion, pseudo-header synthesis, mutation application helpers, immediate response mapping. | This is the Envoy/Praxis translation layer. It preserves `ext_proc` header-mutation semantics while writing into Praxis request and response mutation queues. |
| `filter/ext-proc/src/tests.rs` | Mock external processor, exchange state tests, full-duplex request-routing tests, failure-mode tests, smoke-style assertions. | The test volume is intentionally larger than production code. It proves deferred Go EPP behavior, timeout edges, cancellation, response classification, one-stream behavior, and security properties around trusted routing headers. |
| `filter/src/context.rs` | `HttpFilterContext`, typed `filter_state`, stable filter identity, structured metadata, `TrustedHeaderMutation`, `resolve_trusted_header()`. | This is the shared per-request contract. It lets `ExtProcFilter` persist the exchange across hooks and lets `endpoint_selector` read trusted processor mutations without trusting original client headers. |
| `filter/src/pipeline/http.rs` | Filter hook execution and `current_filter_id` setup/clear. | This is what makes typed filter state safe for multiple filters and branches. State is keyed by stable filter identity rather than by type or global storage. |
| `filter/src/pipeline/build.rs` and `filter/src/pipeline/build_branch.rs` | Stable filter ID assignment and branch-chain filter construction. | Pipeline identity must remain stable across normal chains and branch chains so request-scoped state does not collide under reloads or nested filter graphs. |
| `filter/src/builtins/http/traffic_management/endpoint_selector.rs` | Generic `endpoint_selector`, host:port validation, required-mode rejection, trusted-header stripping. | This separates endpoint selection from `ext_proc`. The Go EPP supplies a trusted mutation; this filter validates it, sets `ctx.upstream`, and removes the internal routing header from all mutation sources. |
| `filter/src/registry.rs` | Built-in filter registration for `endpoint_selector`. | Makes the selector usable through ordinary Praxis YAML composition instead of a special llm-d-only integration path. |
| `protocol/src/http/pingora/context.rs` | `PingoraRequestCtx`, pinned pipeline, filter state writeback, pre-read mutation storage. | This bridges Pingora's request context with Praxis filter contexts. It preserves state and trusted mutation provenance across pre-read, normal request filtering, body filtering, and response hooks. |
| `protocol/src/http/pingora/handler/request_filter/stream_buffer.rs` | StreamBuffer pre-read loop, body hook execution, ordered mutation capture. | This is where request body chunks are made visible to body filters before upstream selection. It records mutation provenance while preserving request body replay behavior. |
| `protocol/src/http/pingora/handler/request_filter/mod.rs` | Applies pre-read mutations to session and request snapshot, clears provenance after routing, runs `upstream_peer`. | This makes pre-read EPP mutations visible to the normal request pipeline while still preventing client-supplied destination headers from being trusted. |
| `protocol/src/http/pingora/handler/{with_body,no_body}.rs` | Handler lifecycle and pinned-pipeline usage. | These handlers ensure a request keeps the same filter pipeline across phases, including hot reload boundaries. |
| `server/src/main.rs` | Feature-gated `ext_proc` filter registration. | The server binary exposes the generic `ext_proc` filter when built with the `ext-proc` feature, so the demo uses normal Praxis startup/configuration. |
| `demo/llm-d-track-b/scripts/local-request-routing/` | Local smoke harness. | Validates the full local process path: Praxis, Go EPP, simulator backend, malicious-header rejection, one Process stream, body preservation, exact 503, and recovery. |
| `demo/llm-d-track-b/scripts/kind-request-routing/` | KIND smoke harness and manifests. | Validates the same composition in Kubernetes with v2-specific images and failure/recovery checks. |

## Request Flow

**Summary:**

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

**Summary:**

`ExtProcFilter` is the part of Praxis that speaks the external-processor
protocol. It knows where the Go EPP lives, when to send headers and body, and
how to turn EPP responses back into Praxis request changes.

**Technical walkthrough:**

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

**Key behavior:**

`ensure_exchange_and_send_headers()` is idempotent. This matters because the
body pre-read path can invoke `on_request_body()` before the normal `on_request`
pipeline has completed. The method stores `ExtProcState` in request-scoped
filter state so the same exchange is reused across callbacks.

**Processing mode contract:**

The demo config sets:

```yaml
processing_mode:
  request_header_mode: send
  response_header_mode: skip
  request_body_mode: full_duplex_streamed
  response_body_mode: none
  request_trailer_mode: skip
  response_trailer_mode: skip
```

These are Envoy `ext_proc` processing-mode concepts exposed through the generic
Praxis filter. They are explicit because `ext_proc` is not llm-d-specific.
Track B requires `request_header_mode: send` and
`request_body_mode: full_duplex_streamed` because the Go EPP needs request
metadata plus request body EOS before it can select a backend. The response and
trailer modes are skipped because they are not needed for current llm-d request
routing.

**Hook-level behavior:**

| Hook | Full-duplex Track B behavior | Performance / correctness reason |
|---|---|---|
| `on_request` | Builds `RequestHeaders`, preloads it into the exchange, stores `ExtProcState`. | Starts the Go EPP conversation before body chunks arrive. The first message is queued without waiting for a server response, avoiding the deadlock where the Go EPP waits for body EOS before responding. |
| `on_request_body` with non-EOS chunk | Sends one `RequestBody` message containing that chunk. | Body bytes are forwarded incrementally during StreamBuffer pre-read. The final EOS callback does not resend accumulated body data. |
| `on_request_body` at EOS | Sends an empty terminal `RequestBody(end_of_stream=true)`, drains EPP responses, applies mutations, half-closes and drains trailing stream data. | The Go EPP makes the endpoint decision at body EOS. Clean stream closure prevents h2 reset/GOAWAY behavior from abrupt drop. |
| `on_response` | Returns `Continue` for full-duplex request-routing mode. | Response lifecycle is not needed for Go EPP endpoint selection and remains FD04 follow-up work. |

## `ExtProcExchange`

**Summary:**

`ExtProcExchange` is the one live conversation with the Go EPP for a request. It
owns the gRPC stream, sends messages in order, reads replies, and makes sure
Praxis does not consume replies in the wrong phase.

**Technical walkthrough:**

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

**Why it differs from the initial async-worker idea:**

The accepted exchange does not spawn one background worker per request. The
pending tonic future stays owned by the exchange and is polled through `send()`
and `receive()`. This avoids extra task scheduling and keeps lifecycle,
cancellation, and backpressure local to the request.

## Full-Duplex Async Performance Model

**Summary:**

The performance-sensitive part of this feature is not protobuf conversion by
itself. The critical path is how Praxis drives a bidirectional gRPC stream
without turning every request into a mini actor system. The accepted design keeps
the stream single-owner, bounded, and locally driven from the request's filter
callbacks.

**No per-request worker task:**

The first version of the full-duplex idea used an async worker to drive the
bidirectional stream. That shape is easy to reason about, but it adds task
creation, scheduling, wakeups, and channel handoff on the hot path. The accepted
design instead stores the pending tonic `process()` future inside the
`ExtProcExchange`:

```text
ExtProcExchange
  |
  +-- BootstrapState::Pending(SyncWrapper<PinnedProcessFuture>)
  +-- request_tx: mpsc::Sender<ProcessingRequest>
  +-- request/response state machines
```

The future is polled only when the request already needs to make progress:

- `send()` polls it while trying to reserve outbound channel capacity.
- `receive()` resolves it before reading processor responses.

That means there is no detached per-exchange driver task, no oneshot response
handoff, and no `Arc<Mutex<_>>` around stream state. Ownership stays local to
the filter's per-request state.

**Why `SyncWrapper` is used:**

Pingora requires the request context to be `Send + Sync`. Praxis stores typed
filter state as `Box<dyn Any + Send + Sync>`. A tonic `process()` future is
`Send` but not `Sync`, because futures contain mutable poll state. Wrapping the
pinned future in `SyncWrapper` satisfies the context bound while preserving the
actual access rule: the future is only polled through `&mut ExtProcExchange`.

This is different from adding a mutex. There is no runtime lock acquisition in
the normal exchange path. The wrapper expresses an ownership invariant: the
future is stored in a `Sync` container, but only the owning request path mutably
polls it.

**Backpressure location:**

The exchange uses a capacity-1 `mpsc` channel for outbound
`ProcessingRequest` messages:

```text
request body callback
  -> tx.reserve().await
  -> permit.send(ProcessingRequest)
  -> state commit
```

Capacity 1 is intentional. It prevents unbounded buffering if the processor or
HTTP/2 transport stops consuming. It also keeps the request path honest: a body
callback cannot run arbitrarily far ahead of the gRPC stream. When the channel
is full, the request body callback naturally awaits capacity.

The important detail is transaction ordering. `send()` computes the transition
first, then awaits channel capacity, then commits the message and state without
another await:

```text
compute_send_transition(request)  // pure validation, no mutation
reserve_while_bootstrapping()     // cancellable await
checked deadline creation         // after reserve, before commit
permit.send(message)              // commit to channel
apply_send_transition()           // state update, no await below
```

If the future is cancelled while waiting for capacity, no send-state mutation
has happened. If the message is committed, the state is updated immediately in
the same synchronous section. That is what keeps cancellation from producing a
phantom "body sent" state.

**Bootstrap without deadlock:**

The Go EPP does not send the endpoint decision after request headers. It waits
until request body EOS. A naive `open().await` that waits for gRPC response
headers can deadlock: Praxis waits for Go EPP to respond, while Go EPP waits for
Praxis to send body EOS.

The accepted `open()` is synchronous:

```text
open()
  -> create channel
  -> pre-load RequestHeaders with try_send()
  -> construct process(request_stream) future
  -> store BootstrapState::Pending
  -> return
```

The first message is already available to the request stream when the Process
RPC is driven. Praxis can continue into body callbacks and send EOS before it
requires the Go EPP's response.

**Driving bootstrap during send:**

`reserve_while_bootstrapping()` uses `tokio::select!` while the Process future is
still pending:

```text
select {
  permit = tx.reserve() => send can proceed
  result = pending_process_future => response stream is ready
}
```

If channel capacity is available first, the body message is sent and the Process
future remains pending. If the gRPC Process call completes first, the response
stream is stored as `BootstrapState::Ready`, and the reserve attempt continues.
This avoids a separate driver task while still letting the underlying tonic/h2
machinery make progress when the request path is active.

**Clean close behavior:**

After draining the request-routing responses, the filter calls:

```text
finish_sending()
drain_trailing().await
```

`finish_sending()` drops the outbound sender and half-closes the request stream.
`drain_trailing()` reads until EOF from the server response stream. This matters
under sustained load: dropping a gRPC/h2 stream while the server still has
trailing messages can cause reset-heavy behavior. The clean half-close plus
trailing drain is why fresh benchmark runs report zero h2 reset/GOAWAY errors.

## Exchange State Machine Deep Dive

`ExtProcExchange` is deliberately split into several small state domains rather
than one large enum. That makes each invariant local and testable.

| State domain | Type | What it protects |
|---|---|---|
| Bootstrap | `BootstrapState` | Whether the Process RPC is still pending, has produced a response stream, or is closed. |
| Outbound request direction | `DirectionSendState` + `SendPhase` | Request-side send ordering: headers before body, body before EOS/trailers, no duplicate headers. |
| Outbound response direction | `DirectionSendState` + `SendPhase` | Same ordering rules for future response lifecycle support. |
| Processor request output | `OutputPhase` | Ordering of processor responses for request headers/body/trailers. |
| Processor response output | `OutputPhase` | Same output ordering for future response lifecycle support. |
| Active non-full-duplex wait | `ActiveProcessingState` | Expected response type, absolute deadline, and at-most-once timeout override. |
| Terminal state | `terminal` | Prevents late sends/receives after timeout, transport error, or immediate response. |

**BootstrapState:**

```text
Pending(SyncWrapper<PinnedProcessFuture>)
  -> Ready(Streaming<ProcessingResponse>)
  -> Closed
```

`Pending` means the tonic `process()` future has been constructed but has not
yet yielded the response stream. `Ready` means the stream exists and `receive()`
can read `ProcessingResponse` messages. `Closed` means bootstrap failed or the
stream is no longer usable.

**SendPhase:**

```text
NotStarted -> Headers -> BodyOpen -> BodyEos
                         |
                         +-> Trailers
```

The request direction uses this immediately. The response direction is already
modeled so FD04 can add response lifecycle without redesigning the exchange.

The transition rules reject:

- body before headers
- duplicate headers
- body after EOS
- trailers before headers
- trailers after EOS
- body messages when the configured body mode is `none`

**Full-duplex versus non-full-duplex active state:**

Non-full-duplex modes create `ActiveProcessingState`. That means "we sent one
message and now expect exactly one matching response before another
non-full-duplex send can proceed." The state carries:

- `expected`: exact response variant, such as `RequestHeaders` or
  `RequestBody`
- `deadline`: absolute timeout for that processor response
- `override_consumed`: whether the processor already used its one timeout
  override for this processing state

Full-duplex request mode is different. For `request_body_mode:
full_duplex_streamed`, request headers, body chunks, and EOS do not create
active processing state. Praxis can send the sequence the Go EPP expects before
waiting for the deferred response:

```text
send(RequestHeaders)
send(RequestBody chunk)
send(RequestBody chunk)
send(RequestBody EOS)
receive(RequestHeaders response with endpoint mutation)
receive(RequestBody response chunks)
```

This is the central compatibility point for llm-d Go EPP. The Go EPP is allowed
to delay its routing response until body EOS without blocking Praxis from
sending that EOS.

**Receive classification:**

`receive()` returns typed `ExchangeEvent` variants:

```text
RequestHeaders
RequestBody
RequestTrailers
ResponseHeaders
ResponseBody
ResponseTrailers
Immediate
```

The exchange validates that the response is solicited. In non-full-duplex modes,
the response must exactly match `ActiveProcessingState.expected`. In full-duplex
request mode, the exchange uses committed outbound evidence to reject
unsolicited responses; for example, a body response is invalid if Praxis never
committed a request body message.

**Transactional output validation:**

Processor output phase is advanced on a local copy first:

```text
let mut local_output = self.request_output;
validate_body_output(&mut local_output, response)?;
self.request_output = local_output;
```

If validation fails, the exchange does not corrupt its output history. That
matters for error handling and tests: a rejected wrong-phase response cannot
accidentally move the state machine forward and make the next invalid response
look valid.

**Timeout override handling:**

Envoy `ext_proc` allows the processor to send an
`override_message_timeout` envelope. The exchange treats any response envelope
with an override field as an override envelope, not a normal response, even if a
response oneof is also populated. The envelope is consumed and never classified
as a headers/body/trailers response.

An override is accepted only when:

- active processing state exists
- no override has already been consumed for that state
- `max_message_timeout` is configured
- the protobuf duration is valid
- the duration is at least 1ms

Invalid overrides are consumed and ignored. Valid overrides replace the active
deadline, clamped to `max_message_timeout`.

**ImmediateResponse:**

`ImmediateResponse` is terminal. Once it is classified, `receive()` marks the
exchange terminal, and `ExtProcFilter` maps it to a Praxis rejection. This covers
processor-driven failures such as routing denial or upstream selection failure.

## Request-Scoped Filter State

**Summary:**

Praxis needs to remember the EPP conversation between request headers and body
callbacks. Request-scoped filter state is the pocket where the filter keeps that
conversation.

**Technical walkthrough:**

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

**Summary:**

The backend address must come from the Go EPP, not from the client. Otherwise a
client could send `x-gateway-destination-endpoint` and try to route itself to an
arbitrary target.

**Technical walkthrough:**

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

**Summary:**

The Go EPP returns the selected backend in a header mutation. The
`endpoint_selector` filter turns that trusted header value into the Praxis
upstream target.

**Technical walkthrough:**

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

- Full Envoy `ext_proc` parity. This milestone proves request routing through
  Go EPP; full response-phase lifecycle support is FD04 follow-up work.
- Request trailers, blocked by a Pingora platform boundary.
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
