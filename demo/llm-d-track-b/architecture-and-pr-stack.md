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

Follow-up work is intentionally staged into separate repo copies and PR-sized
branches. The operational inventory and rebase/open checklist live in the
companion planning workspace as `e2e-pr-staging-playbook.md`; the copy/paste
Claude prompts live there as `future-pr-claude-prompts.md`; the director notes
for the Codex/Claude workflow live there as `director-architecture-notes.md`.
The engineering feedback that drives PR6 and later is tracked in
[Engineering Q&A From Review](https://github.com/nerdalert/praxis-research-spikes/blob/main/demo/llm-d-track-b/code-walkthrough.md#engineering-qa-from-review).

## Implementation Branch

The current implementation is on the
[ext_proc Praxis/llm-d POC branch](https://github.com/nerdalert/praxis/tree/ext-proc-llm-d-praxis-poc-v2)
at commit `d2ca1f1`.

## Staged Follow-Up Workspaces

The upstream PRs are intentionally staged from separate repo copies so each
follow-up can be rebased, reviewed, and opened independently:

| Stage | Purpose | Local Planning Status |
|---|---|---|
| PR3 | Generic full-duplex request-routing integration. | Open upstream as praxis-proxy/praxis#707. |
| PR4 | Hermetic Rust integration tests for PR3. | Prepared locally; open only after PR3 merges and the branch is rebased. |
| PR5 | Real-cluster llm-d/vLLM validation harness for issue #295. | Prepared locally; reports PASS only with real scheduler evidence, otherwise SKIP. |
| PR6 | Response-header lifecycle, the first Envoy parity follow-up. | Staged locally with bounded cleanup and focused lifecycle tests; rebase and fully validate after PR3 merges. |
| PR7 | Generic async/multi-output response-body lifecycle foundation. | Design discovery next; no production code until a separate PR7 repo copy and design constraints are created. |
| PR8 | Response-body `ext_proc` integration on top of the PR7 body primitive. | Planned; do not start until PR7 proves the generic lifecycle boundary. |
| PR9 | Request/response trailers. | Planned; depends on a clear Pingora trailer hook boundary. |
| PR10 | Processing-mode override matrix. | Planned; depends on request, response-header, response-body, and trailer phase behavior being explicit. |
| PR11 | Mutation and forwarding rules. | Planned; includes generic header/body mutation policy, not llm-d-specific exceptions. |
| PR12 | Metadata options and attribute forwarding. | Planned; requires an explicit contract for structured metadata, gRPC metadata, and Envoy-style attributes. |
| PR13 | Failure, per-route, and processor-target overrides. | Planned; should stay generic and composable with existing filter config patterns. |
| PR14 | Observability mode. | Planned; processor observation without mutation must be separate from routing/mutation behavior. |
| PR15 | Fuller immediate-response parity. | Planned; covers direct responses beyond the minimal terminal response path needed by PR3. |
| PR16 | Stats, docs, examples, and conformance hardening. | Planned; final parity pass after the behavioral PRs land. |
| Product routing follow-up | Pool membership validation, cluster/pool routing, fallback endpoints, model-to-pool authorization, role and named-port validation. | Planned separately from Envoy parity; driven by llm-d product semantics and issue #295 evidence. |

The exact local directory inventory and rebase/open checklist are maintained in
the companion planning workspace as `e2e-pr-staging-playbook.md`.

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
| Response phase | Full response lifecycle | Not needed for llm-d request routing; PR6+ follow-up parity work |

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

**Status:** Merged as PR #609

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

**Status:** Merged as PR #627

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

**Status:** Under upstream review

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

**Evidence:** 191 ext-proc tests, 2,143 filter tests, 367 protocol tests,
43 server tests, 8-assertion local smoke, 7-assertion KIND deployment, and
two clean-start smoke runs. The separate hermetic integration-test PR adds
standard CI-style coverage for the documented example config.

**Reviewer validation output:** The Track B validation artifact is captured
under [`validation/`](validation/) with the focused integration-test command
output and assertion checklist.

**Remaining work:** Broader `ext_proc` parity, especially response lifecycle,
is future work. It is not a blocker for the llm-d request-routing path in PR3.

### PR 4: Hermetic Full-Duplex Request-Routing Integration Tests

**Status:** Staged locally; rebase and open after PR3 merges

**Scope:**
- In-process tonic `ExternalProcessor` mock
- Recording backend for no-backend-hit assertions
- Documented example-config integration test
- RequestHeaders first-message assertion
- RequestBody non-terminal chunk and terminal EOS assertions
- Spoofed destination rejection
- Invalid, missing, and ambiguous destination rejection
- Processor failure returns configured status
- Immediate response does not hit backend
- Repeated requests use independent Process streams

**Why it matters:**
PR4 turns the PR3 request-routing behavior into standard hermetic integration
coverage. It proves the generic Praxis `ext_proc` plus `endpoint_selector`
composition without Docker, KIND, the Go EPP, or vLLM.

**Boundary:** PR4 does not close llm-d issue #295. It proves Praxis behavior
with a mock processor, not real scheduler/cache/pool behavior.

### PR 5: Environment-Backed llm-d/vLLM Validation

**Status:** Staged locally as executable validation infrastructure; open after
PR4 shape is stable

**Scope:**
- Praxis as the gateway in an llm-d environment
- Real llm-d scheduler/EPP components
- vLLM model-serving pods where available
- EPP endpoint selection under load/cache scenarios
- Prefix cache-aware routing with shared system prompts
- InferenceModel traffic splitting across multiple InferencePools
- Disaggregated prefill/decode routing when supported by the installed llm-d
  version
- Repeatable validation command and sanitized reviewer output

**Why it matters:**
PR5 is the environment-backed validation phase for
[praxis-proxy/praxis#295](https://github.com/praxis-proxy/praxis/issues/295).
It should prove the real llm-d composition. It should not be presented as
generic Envoy `ext_proc` parity.

### PR 6: Response-Header Lifecycle

**Status:** Staged locally; rebase and revalidate after PR3 merges

**Scope:**
- Accept `response_header_mode: send`.
- Reuse the existing request exchange when response headers are configured.
- Send `ResponseHeaders` during `on_response`.
- Apply response header mutations.
- Preserve response-phase dynamic metadata.
- Define response-header `ImmediateResponse` behavior.
- Use bounded cleanup for request/response-header exchange paths outside the
  existing request-body lifecycle timeout.

**Why it matters:**
PR6 is the first Envoy parity follow-up. It proves the same single-owner
exchange can safely span request and response header phases without adding a
worker task, unbounded queue, or shared stream lock.

**Boundary:** PR6 does not implement response body, trailers, mode override,
mutation rules, metadata options, observability mode, per-route overrides, or
llm-d product routing.

### PR 7: Generic Response-Body Lifecycle Foundation

**Status:** Planned; design discovery next

PR7 should be design-first. It owns the generic Praxis async/multi-output
response-body lifecycle foundation. It should not start as `ext_proc` response
body code.

**Scope:**
- Define how a response body can be observed, buffered, streamed, replaced, or
  passed through by a filter.
- Define backpressure and ownership rules for async/multi-output body
  processing.
- Keep this generic to Praxis rather than coupling the primitive directly to
  `ext_proc`.
- Document how the body primitive interacts with `StreamBuffer`, response
  headers, downstream writes, and error handling.

**Boundary:** PR7 should not implement the Envoy `ResponseBody` protocol
messages yet. That belongs in PR8 after the generic lifecycle contract is clear.

### PR 8: Response-Body ext_proc Integration

**Status:** Planned after PR7

**Scope:**
- Send Envoy `ResponseBody` messages when response body processing is
  configured.
- Apply streamed response body mutations according to the PR7 lifecycle
  contract.
- Preserve pass-through behavior when the processor observes but does not
  mutate the body.
- Reuse the single-owner exchange model without adding per-request worker
  tasks, unbounded queues, or shared stream locks.

### PR 9: Request and Response Trailers

**Status:** Planned; platform-boundary discovery required

**Scope:**
- Add trailer processing only where Pingora exposes a safe lifecycle hook.
- Keep request trailers and response trailers separate if the platform support
  differs.
- Document unsupported phases explicitly rather than silently claiming Envoy
  parity.

### PR 10: Processing-Mode Override Matrix

**Status:** Planned after lifecycle phases are explicit

**Scope:**
- Validate mode combinations for headers, body, trailers, and response phases.
- Implement supported processor override behavior.
- Reject or ignore unsupported overrides with deterministic tests and docs.

### PR 11: Mutation and Forwarding Rules

**Status:** Planned

**Scope:**
- Add generic allow/deny mutation rules for request and response headers.
- Define forwarding rules separately from mutation rules.
- Keep authority/host protection generic.
- Avoid llm-d-specific header shortcuts.

### PR 12: Metadata Options and Attributes

**Status:** Planned

**Scope:**
- Define which request, route, upstream, and filter-state attributes Praxis can
  expose to an external processor.
- Decide which data travels as headers, structured metadata, gRPC metadata, or
  explicit protobuf fields.
- Keep the contract documented so llm-d and non-llm-d processors can rely on it.

### PR 13: Failure, Per-Route, and Processor-Target Overrides

**Status:** Planned

**Scope:**
- Add per-route and per-filter overrides for processor target, failure behavior,
  status codes, and timeouts.
- Preserve fail-closed request-routing semantics where required by
  `endpoint_selector`.
- Keep override precedence deterministic and tested.

### PR 14: Observability Mode

**Status:** Planned

**Scope:**
- Support observe-only processor flows without applying mutations.
- Ensure observability cannot accidentally select an upstream or alter the
  request/response.
- Add stats/logging hooks that distinguish observation from mutation.

### PR 15: Fuller Immediate-Response Parity

**Status:** Planned

**Scope:**
- Expand direct-response behavior beyond the minimal terminal response path
  covered by PR3 and PR4.
- Cover headers, body handling, metadata, and lifecycle cleanup across request
  and response phases.

### PR 16: Stats, Docs, Examples, and Conformance Hardening

**Status:** Planned after the behavioral PRs

**Scope:**
- Add stable counters and traces for each lifecycle outcome.
- Add example configs for each supported mode.
- Add conformance-style tests for supported Envoy `ext_proc` behavior.
- Clearly document unsupported Envoy features.

### Product Routing Follow-Up

**Status:** Separate from Envoy parity; driven by llm-d product semantics

**Scope:**
- Validate selected endpoints against InferencePool membership.
- Support cluster/pool routing if product requirements need it.
- Define fallback endpoint ordering and retry interaction.
- Authorize model-to-pool selections.
- Validate role-specific and named-port selections.

This product-routing track should use issue #295 real-cluster evidence. It
should not be mixed into generic Envoy `ext_proc` parity PRs unless a shared
primitive is genuinely required.

The detailed PR6+ implementation plan is captured in the companion Track B
planning workspace as `envoy-ext-proc-parity-gameplan.md`. This spike document
keeps the reviewer-facing scope boundary and PR sequence.

## Non-Blocking Follow-Up Work

These items are useful for broader Envoy `ext_proc` parity and future llm-d
features, but they are not required for the llm-d request-routing path proven here.

| Item | Needed for current llm-d request routing? | Scope |
|------|---|-------|
| Response body streaming foundation | No | PR7 design-first async multi-output response body foundation for future response lifecycle work. |
| Complete response lifecycle integration | No | Response metadata, response body processing, usage/eviction-style flows, and broader parity. |
| Request trailers | No | Blocked on a Pingora platform boundary; not used by the current Go EPP request-routing path. |
| Full Envoy `ext_proc` parity | No | PR6+ compatibility work such as response phases, mode overrides, mutation rules, metadata options, observability mode, and conformance hardening. |
