
# Proposed Praxis Implementation: Responses API and Agentic Response Orchestration

## Core Decision

Praxis should support two explicit Responses API modes:

1. **Native pass-through mode** for backends that already support `/v1/responses`.
2. **Praxis-owned agentic orchestration mode** for deployments where Praxis is responsible for conversation state, approved local tool execution, guardrails, and repeated model calls.

These modes should be selected by configuration or routing policy. The presence of request fields such as `tools`, `store`, `conversation`, or `previous_response_id` should not automatically make Praxis take ownership of the workflow, because a native Responses backend may already support those fields correctly.

## Mode 1: Native Responses Pass-Through

In pass-through mode, Praxis acts as a transparent proxy for Responses API traffic.

```text
Client
  -> Praxis classification/routing
  -> Responses-capable backend
  -> Client
```

Requirements:

- Detect Responses requests for routing purposes without mutating the body.
- Preserve request bytes exactly, including unknown forward-compatible fields.
- Preserve fields such as `tools`, `tool_choice`, `store`, `conversation`, `previous_response_id`, `stream`, and encrypted or opaque reasoning content.
- Forward non-streaming responses unchanged.
- Forward SSE streaming responses unchanged.
- Do not parse, normalize, persist, execute tools, or claim ownership of the agent loop in this mode.

The classifier may expose small bounded routing facts such as API format, model name, `stream`, `store`, or the presence of continuation fields. Those facts are for routing and policy only.

## Mode 2: Praxis-Owned Agentic Response Orchestration

In agentic mode, Praxis owns the complete model/tool/model workflow.

```text
Client
  -> Praxis classifier and policy selection
  -> agentic response orchestrator
       -> load stored conversation state when needed
       -> run input guardrails
       -> call the configured model backend
       -> inspect the model response
       -> validate any requested tool calls
       -> execute approved local tools
       -> validate tool results
       -> inject tool outputs into the next model request
       -> call the model again
       -> repeat until final answer or limit
       -> persist state when requested
       -> return the final response to the client
```

The orchestrator is implemented as a terminal request-phase filter, such as `responses_orchestrator`, which owns internal subrequests and returns a local response when processing is complete.

## Why The Agentic Response Orchestrator Is Required

Praxis branch-chain re-entry currently works only before a normal upstream response exists. It cannot pause a model response, execute a tool, issue another model request, and then substitute the final answer returned to the client.

An agent loop requires exactly that behavior:

```text
User asks a question
  -> model requests a tool
  -> Praxis executes the approved tool
  -> Praxis sends the result back to the model
  -> model returns the final answer
  -> Praxis replies to the user
```

Because this flow cannot currently be implemented through ordinary response-phase filters and branch-chain re-entry, the stateful path must be owned by the agentic response orchestrator.

This does not mean the implementation should be monolithic. Parsing, state access, tool policy, tool adapters, streaming parsing, guardrails, and persistence should still be separate testable Rust modules used by the orchestrator.

## Request Classification And Routing

Praxis should include a body-aware Responses classifier that:

- Identifies Responses API requests versus Chat Completions traffic.
- Extracts bounded routing facts such as model name, streaming mode and state-related field presence.
- Preserves the original request body unchanged.
- Provides facts for routing into either native pass-through mode or Praxis-owned agentic mode.

The classifier should not decide that Praxis owns the workflow solely because a request contains tools or continuation fields. Ownership must be intentional and configured.

## Agent Loop Behavior

For a Praxis-owned agent request, the orchestrator should:

1. Parse and validate the incoming Responses request.
2. Determine the configured inference backend for the selected model.
3. Load prior context when `previous_response_id` or conversation state is used.
4. Run initial guardrails on user input and retrieved context.
5. Submit an inference subrequest to the model backend.
6. Parse the response for final output or tool-call items.
7. If the response is final, persist it when required and return it.
8. If the response requests tools, validate all requested tools before executing any of them.
9. Execute only tools Praxis is authorized to execute locally.
10. Run guardrails on tool output before reinserting it into model context.
11. Inject correlated `function_call_output` items using the original `call_id`.
12. Submit another inference subrequest.
13. Continue until final output, timeout, maximum iterations, maximum tool calls, or another controlled failure condition.

## Tool Ownership And Execution Policy

A tool appearing in the model request does not automatically mean Praxis may execute it.

Praxis must distinguish between:

| Tool Type | Owner | Praxis Behavior |
| --- | --- | --- |
| Client-owned function tool | Calling application | Return the approved tool call to the client when configured for client execution. |
| Provider-owned/native tool | Responses-capable backend | Preserve it in native pass-through mode, or explicitly delegate it in agentic mode. |
| Praxis-owned local tool | Praxis configuration | Execute it locally inside the agentic response orchestrator. |
| Unknown or unadvertised tool | Nobody authorized | Reject or fail closed by default. |

For local execution, both conditions must be true:

1. The tool was intentionally advertised to the model for this request.
2. Praxis configuration authorizes local execution of that tool and identifies its backend.

The model should receive only the tools allowed for that request, not Praxis's entire global tool catalog.

Tool calls must be validated before execution so that one permitted tool is not executed before another invalid or unauthorized call is discovered.

## State Management

The stateful workflow requires substantial structured state, including:

- Original request information.
- Conversation transcript.
- Prior response references.
- Tool definitions and policy decisions.
- Pending tool calls and results.
- Model output items.
- Usage and status information.
- Streaming buffers.

This data must not be stored in `filter_metadata`. Praxis metadata is intended for small bounded routing facts and identifiers, not complete requests, conversations, tool outputs, or streamed response bodies.

The design should use:

- A typed request-scoped loop state object owned by the orchestrator.
- A typed response/conversation state store for durable state.
- Small metadata values only for identifiers and routing facts, such as mode, response ID, tenant ID or status.

State requirements include:

- Store the full transcript required to continue a conversation correctly.
- Honor `store: true` and `store: false`.
- Return a controlled error for missing or inaccessible `previous_response_id`.
- Include tenant, user or session scoping in state keys.
- Define TTL and retention behavior.
- Support a local implementation first and external durable backends through an abstraction.

## Internal Subrequests

Stateful orchestration requires Praxis to make internal calls to:

- The inference backend.
- Approved local tool backends.
- MCP services.
- Conversation/state services.
- File, search or vector-store services.

These calls should be made through a generic `SubRequestClient` abstraction rather than directly embedding a new HTTP client throughout agentic filters.

The subrequest layer should provide:

- Timeout enforcement.
- Maximum request and response byte limits.
- Header allowlists and reserved-header protection.
- Parent request and tracing propagation.
- Cancellation behavior.
- Metrics and controlled error mapping.
- Connection pooling and TLS behavior compatible with Praxis.

The e2e spike demonstrated that direct `reqwest` usage can conflict with the existing Pingora/rustls TLS path. The upstream implementation must resolve that through the subrequest abstraction before agentic execution depends on it.

## Guardrail Placement

Guardrails must be part of the loop, not only an initial input check.

Required guardrail points:

| Point | Purpose |
| --- | --- |
| Before initial inference | Validate user input and loaded conversation context. |
| After model response | Validate model output and requested tool calls. |
| Before tool execution | Validate tool name, arguments and execution policy. |
| After tool execution | Validate tool result before the model receives it. |
| Before each reinference call | Validate the updated conversation after injected tool results. |
| Before final client response | Validate the final output returned downstream. |

A tool result can contain unsafe or untrusted content. It must not be automatically injected back into the model without policy and guardrail checks.

## Streaming Policy

Streaming behavior differs by ownership mode.

### Stateless Streaming

For native pass-through mode:

- Forward upstream SSE events unchanged.
- Preserve event ordering and bytes.
- Do not buffer or reinterpret tool-call events.
- Let the native Responses backend own its streaming semantics.

### Stateful Streaming

For Praxis-owned agentic mode:

- Buffer upstream model SSE while determining whether the model is returning final text or requesting tool execution.
- Accumulate streamed function-call argument deltas until the tool call is complete.
- Do not expose intermediate tool-call responses as though they were the final answer when Praxis intends to execute those tools.
- Execute approved tools only after complete validated tool-call input is available.
- Continue the loop internally after tool results are injected.
- Return valid final Responses output to the client.

The default stateful streaming behavior should be a buffered final response mode. Any progress-event forwarding should be explicit, separately designed and tested.

Stateful streaming must enforce:

- Maximum buffered bytes.
- Maximum buffered events.
- Timeouts.
- Terminal-event requirements.
- Complete function-call argument requirements.
- Fail-closed behavior for malformed, truncated or incomplete streams.

## External Services And OGX

Praxis should own the Responses agent loop when operating in agentic mode.

OGX or similar systems may still be used as external service backends for non-loop capabilities such as:

- Conversation or response storage.
- Files.
- Vector stores.
- Search.
- Skills.
- Containers or future execution environments.

Praxis should not delegate `/v1/responses` to OGX and then claim that Praxis implements the orchestration loop. The intended integration is:

```text
Praxis owns the loop
  -> OGX-backed state/file/search/vector services may support the loop
```


## Supported Initial Capability Target

The implementation target for the epic includes:

- Native byte-preserving Responses pass-through.
- Body-aware Responses classification and routing.
- Praxis-owned stateful orchestration.
- Responses JSON and SSE parsing.
- HTTP-first internal subrequests.
- Conversation and response state handling.
- At least one configured local HTTP tool.
- At least one MCP tool adapter.
- Local-versus-remote-versus-client tool policy.
- Guardrails around inference and tool results.
- Buffered stateful streaming semantics.
- External file/search/vector service callouts without delegating loop ownership.

## Explicit Non-Goals For The Core Implementation

The epic does not need to first implement:

- A generic asynchronous response-phase continuation engine for every Praxis filter.
- Cross-lifecycle branch-chain re-entry for arbitrary proxy flows.
- A complete production distributed state platform before the local typed abstraction works.
- gRPC or `ext_proc` parity before HTTP tool and model subrequests are proven.
- OGX ownership of the `/v1/responses` loop.
- Every future Responses tool type, such as code interpreter or computer use, before the core loop is complete.

## Failure And Limit Handling

The agentic response orchestrator must enforce explicit boundaries:

- Maximum inference iterations.
- Maximum total tool calls.
- Per-tool timeout.
- Total request timeout.
- Maximum injected tool-result size.
- Maximum model response bytes.
- Streaming buffer byte and event limits.
- Controlled handling of unknown tools.
- Controlled handling of malformed or incomplete SSE.
- Controlled handling of missing stored conversation state.

Failures must be returned as Responses-shaped errors or incomplete responses according to defined API behavior, rather than silently falling through or partially executing unauthorized work.

## Completion Criteria

The architecture is complete when Praxis can:

1. Forward native Responses requests and streams without mutation.
2. Route configured stateful requests into a Praxis-owned agentic response orchestrator.
3. Load and persist response/conversation state with correct `store` behavior.
4. Execute an approved local tool, inject its result and call the model again.
5. Distinguish locally executable tools from backend-owned and client-owned tools.
6. Fail closed for unknown or unauthorized tool calls.
7. Apply guardrails before inference and after tool output.
8. Buffer and safely process stateful streamed tool calls.
9. Enforce iteration, timeout, tool-count and buffer limits.
10. Use scoped state and safe subrequest plumbing suitable for upstream integration.
11. Integrate external files, search, vector-store or OGX-backed services without transferring ownership of the agent loop away from Praxis.

## Stacked Upstream PR Plan

The e2e spike should be completed first. Then replay the proven work into
reviewable PRs in this order.

### PR 1: Responses Format Classifier

Issues: #361, partial #355.

Scope:

1. Add a built-in HTTP filter, proposed name `responses_format`.
2. Implement pure parser functions for classifying:
   - Responses API request
   - Chat Completions request
   - unknown JSON
   - non-JSON
3. Extract `model` from both formats.
4. Extract bounded facts:
   - `stream`
   - `store`
   - presence of `previous_response_id`
   - presence of `conversation`
5. Promote configured headers for routing.
6. Write filter results for branch conditions.
7. Do not mutate the body.

Likely files:

```text
filter/src/builtins/http/ai/responses_format/
filter/src/builtins/http/ai/mod.rs
filter/src/registry.rs
examples/configs/ai/responses-format-routing.yaml
tests/integration/tests/suite/responses_format.rs
```

Implementation instructions:

1. Follow `json_body_field` for StreamBuffer body inspection.
2. Follow `mcp` for config validation and result/metadata naming.
3. Use `serde_json::Value` classification first. Do not introduce large
   schema structs in this PR.
4. Use `#[serde(deny_unknown_fields)]` on config structs.
5. Keep `on_invalid` configurable with defaults:
   - `continue` for mixed traffic listeners
   - `reject` only when explicitly configured

6. Header names must be configurable and must not allow spoofing of reserved
   internal prefixes.
7. Before pushing, run `make lint` locally and fix every clippy warning. For
   `responses_format`, specifically check doc comments, function length,
   `let...else` opportunities, struct constructor order, and small `Copy` enum
   arguments.

Tests:

1. Unit classification for Responses string input.
2. Unit classification for Responses item-array input.
3. Unit classification for Chat Completions `messages`.
4. Unit non-JSON pass-through.
5. Unit invalid JSON reject when configured.
6. Integration route by `x-praxis-ai-format`.
7. Example config parse test.
8. Large body over 64 KiB.

Definition of done:

1. No body mutation.
2. Existing Chat Completions examples still pass.
3. Classifier can be used before `router`.

### PR 2: Stateless Responses Pass-Through And Mock Backend

Issues: #355, partial #362.

Scope:

1. Add reusable Responses mock backend in `tests/utils`.
2. Add stateless example config.
3. Add pass-through integration tests proving body identity.
4. Add streaming pass-through tests.
5. Include encrypted reasoning / opaque field fixture.

Likely files:

```text
tests/utils/src/agentic/responses.rs
tests/integration/tests/suite/responses_stateless.rs
examples/configs/ai/responses-stateless-pass-through.yaml
tests/schema/tests/suite/examples/ai/responses_stateless.rs
```

Implementation instructions:

1. The mock must record raw bytes before parsing. The byte-preservation test
   should compare exact body bytes or SHA-256.
2. Do not use pretty-printed JSON for pass-through assertions.
3. Streaming mock should emit at least:
   - `response.created`
   - `response.output_text.delta`
   - `response.completed`
4. The stateless config should be simple:
   - `responses_format`
   - `router`
   - `load_balancer`

Tests:

1. Responses JSON body reaches backend byte-for-byte.
2. Unknown fields are preserved.
3. `previous_response_id` is forwarded.
4. Encrypted reasoning include/output fields are forwarded unchanged.
5. SSE stream is forwarded unchanged.

Definition of done:

1. The PR can close or substantially satisfy #355 if maintainers agree.
2. No stateful behavior is introduced.

### PR 3: Responses Parser And SSE Parser Foundation

Issues: partial #357, partial #362, supports #355.


Scope:

1. Add pure Rust parser module for Responses request/response/event shapes.
2. Parse non-streaming response output items for:
   - assistant messages
   - `function_call`
   - reasoning items as opaque data
   - tool result items
3. Add an SSE parser that buffers partial lines across chunks.
4. Recognize terminal events:
   - `response.completed`
   - `response.failed`
   - `response.incomplete`
5. Recognize function-call argument events:
   - `response.output_item.added`
   - `response.function_call_arguments.delta`
   - `response.function_call_arguments.done`
   - `response.output_item.done`
6. No tool execution yet.

Likely files:

```text
filter/src/builtins/http/ai/responses/
filter/src/builtins/http/ai/responses/parser.rs
filter/src/builtins/http/ai/responses/sse.rs
filter/src/builtins/http/ai/responses/tests.rs
```

Implementation instructions:

1. Use typed enums where the stable discriminators are known.
2. Keep unknown item/event types as `Unknown(Value)` so the proxy is
   forward-compatible.
3. Do not exceed source quote limits from external specs. Build fixtures from
   small local JSON samples.
4. Add split-chunk tests where a JSON event is split inside a string.
5. Add CRLF and LF tests.

Tests:

1. Parse function call item and extract `call_id`, `name`, `arguments`.
2. Parse function_call_output and correlate by `call_id`.
3. Parse event stream with split lines.
4. Parse malformed event and return structured parser error.
5. Parse terminal response and expose status.

Definition of done:

1. Parser is independent of the proxy pipeline.
2. Later PRs can use it without re-parsing ad hoc JSON.

### PR 4: Generic HTTP Subrequest Core

Issues: #358, partial #28.

Scope:


1. Add a generic subrequest API that filters can use for HTTP callouts.
2. Include service registry config:
   - name
   - URL
   - method
   - timeout
   - max request bytes
   - max response bytes
   - failure mode
   - static headers
   - allowed forwarded headers
3. Add connection reuse/pooling through the selected HTTP client.
4. Add tracing/metrics fields:
   - parent request id
   - service name
   - attempt
   - duration
   - status class
   - timeout/error

Implementation instructions:

1. First inspect Pingora's available HTTP client APIs. Prefer existing runtime
   dependencies if they can provide safe pooling and TLS.
2. If adding `reqwest`, isolate it behind a `SubRequestClient` trait and
   document the rustls provider initialization implications seen in the
   historical `http_ext_auth` work.
3. Do not bake Responses-specific behavior into the subrequest layer.
4. Enforce max response bytes before buffering an entire body.
5. Propagate cancellation by dropping futures when the parent request is done.
6. Add request id and attempt headers with a reserved prefix stripped from
   downstream input.

Tests:

1. Successful JSON callout.
2. Timeout.
3. Response over max bytes.
4. Connection refused.
5. Header allowlist and reserved-header stripping.
6. Fail-open and fail-closed behavior.

Definition of done:

1. No Responses orchestrator yet.
2. One minimal test filter may be added only to exercise the API.
3. gRPC config may exist as `unsupported` but should not be claimed.

### PR 5: Conversation State Abstraction And Local Store

Issues: #359.

Scope:

1. Add typed conversation/response state traits:
   - `ConversationStore`
   - `ResponseStore` or combined `ResponsesStateStore`
2. Add local in-memory implementation with TTL.
3. Add deterministic test ID generator and production ID generator.
4. Define key scope:
   - tenant
   - user

   - session/conversation
   - response id
5. Add error types:
   - not found
   - expired
   - conflict
   - backend unavailable
   - invalid scope

Implementation instructions:

1. Do not expose raw `KvBackend` directly to filters.
2. The existing `KvStoreRegistry` may be used underneath for local runtime
   storage only if a typed wrapper enforces TTL and serialization.
3. Store full bodies outside `filter_metadata`.
4. Keep response item payloads as `serde_json::Value` initially unless strong
   typed structs have already landed in PR 3.
5. Make `store: false` explicit in tests.


Tests:

1. Create/get/append/delete.
2. TTL expiry.
3. Tenant isolation.
4. User/session isolation.
5. Missing previous response.
6. Deterministic response id generation in tests.

Definition of done:

1. Local store works without external services.
2. No inference or orchestration behavior yet.

### PR 6: Stateful Load And Persist Filters

Issues: #356, #359.

Scope:

1. Add `responses_state_load` filter.
2. Add `responses_state_persist` filter.
3. Support `previous_response_id`, `conversation`, and `store`.
4. Add external HTTP store backend using PR 4 subrequests.
5. Add example config for stateful non-tool orchestration.

Implementation instructions:

1. Keep this PR non-agentic. It should prove state load/persist around a
   single inference call, not tool loops.
2. If the current normal upstream path cannot persist response bodies without
   async response-body work, scope this PR to:
   - request-side load
   - response header facts
   - non-streaming response body buffering with sync parsing and async flush
     only if it is safe
3. If persistence requires the terminal orchestrator, move persistence into
   PR 8 and keep PR 6 as store types plus request-side load.
4. `store: false` must not write durable response state.
5. `conversation` and `previous_response_id` together should be rejected or
   resolved by explicit config. OGX rejects the combination.

Tests:

1. Previous response loaded and included in inference request.
2. Missing previous response returns Responses-shaped error.
3. `store: true` persists final response.
4. `store: false` does not persist.
5. Tenant isolation.
6. External mock backend timeout/failure behavior.

Definition of done:

1. #356 is partially satisfied for non-tool flows.
2. Tool loop remains out of scope.

### PR 7: Tool Registry And Execution Policy

Issues: partial #357, partial #360.

Scope:

1. Add config model for tool registry:
   - tool name
   - kind: `http`, `mcp`, `grpc`, `remote`, `client`
   - backend service name
   - timeout
   - max response bytes
   - argument schema policy
   - result injection policy
2. Add local-vs-remote matching.
3. Add unknown-tool policy:
   - `reject` default
   - `surface_to_client`
   - `delegate_remote`
4. Add allow/deny tool selectors.
5. Add pure tests for matching and policy.

Implementation instructions:

1. Reuse Envoy AI Gateway's deny-wins selector idea.
2. Reuse MCP/A2A plan metric guidance: do not label raw tool names by default
   unless bounded/allowlisted.
3. Do not execute tools in this PR.
4. A client-advertised tool is not executable unless the registry says it is.
5. Reject duplicate local tool names at config load.

Tests:

1. Local HTTP tool matched.
2. Remote tool not executed locally.
3. Client-side function tool surfaced.
4. Unknown tool rejected by default.
5. Deny selector overrides include selector.
6. Duplicate name rejected.

Definition of done:

1. User's #354 comment about local advertised tools vs remote invocation is
   addressed structurally.

### PR 8: Non-Streaming Responses Orchestrator With HTTP Tools

Issues: #357, #358, #356.

Scope:

1. Add `responses_orchestrator` terminal filter.
2. Use PR 4 subrequests to call an inference backend.
3. Use PR 3 parser to detect function calls.
4. Use PR 7 registry to execute local HTTP tools.
5. Inject `function_call_output` items by `call_id`.
6. Loop until final response or limit.
7. Run guardrails at configured points.
8. Persist state through PR 5/6 store when `store: true`.
9. Return a local JSON response to downstream.

Implementation instructions:

1. Start with non-streaming model responses.
2. Treat this PR as the required fix for the branch re-entry gap described in
   "Branch Re-Entry, Agentic Loop Scope, And Fix Strategy." Do not implement
   the loop by extending generic `branch_chains` or by running tool execution
   from `on_response_body`.
3. Use a clear loop state struct:
   - response id
   - iteration count
   - started_at
   - accumulated input items
   - pending tool calls
   - tool outputs
   - usage if available
4. Enforce:
   - `max_iterations`
   - total timeout
   - per-tool timeout
   - max total tool calls
   - max injected result bytes
5. Tool results should be JSON strings unless configured otherwise.
6. On max iterations, return a Responses-shaped `incomplete` response if
   possible. If not possible, return a clear error response. Pick one behavior
   and test it.
7. Do not use response body hooks for tool execution.

Tests:

1. One HTTP tool call loops to final response.
2. Two sequential tool iterations.
3. Max iterations.
4. Tool timeout.
5. Tool returns non-2xx.
6. Tool output guardrail blocks reinference.
7. Unknown tool fails closed.
8. Store true/false behavior with loop.

Definition of done:

1. First useful stateful Praxis-owned agentic mode exists.
2. It does not claim streaming support yet.
3. It does not claim MCP/gRPC tools yet.

### PR 9: Stateful Streaming Orchestration

Issues: #357, #355, #362.

Scope:

1. Add buffered upstream SSE parsing to `responses_orchestrator`.
2. Accumulate function-call argument deltas.
3. Execute tools after function-call completion.
4. Emit downstream Responses SSE for final response.
5. Add buffer and event limits.

Implementation instructions:

1. Keep stateless streaming pass-through untouched.
2. For stateful streaming, do not forward upstream tool-call events directly
   unless the configured mode is `progress_events`.
3. Default mode should be `buffered_final_stream`.
4. Preserve event ordering and monotonically increasing `sequence_number` in
   synthesized final streams.
5. Include tests for split chunks, CRLF, malformed JSON, missing terminal
   event, and timeout.

Tests:

1. Model streams function call arguments in chunks; one tool call executes.
2. Model streams final text only; downstream receives SSE response.
3. Malformed event fails closed.
4. Buffer limit exceeded fails closed.
5. Guardrail buffers output before release.

Definition of done:

1. Stateful `stream: true` is supported with explicit buffering semantics.
2. Moderation/guardrail risk is documented.

### PR 10: MCP Tool Executor Adapter

Issues: #357, #24, partial #360.

Scope:

1. Add MCP tool backend kind to the tool registry.
2. Use existing MCP mock server in integration tests.
3. Support Streamable HTTP MCP tool calls.
4. Add backend session reuse if needed by strict backends.
5. Add header forwarding allowlist and auth injection.

Implementation instructions:

1. Reuse the local MCP classifier/mock conventions.
2. Do not implement full MCP gateway in this PR.
3. Treat MCP as a tool backend for Responses orchestration.
4. Keep old SSE MCP transport out of the first adapter unless e2e proves it.
5. Session IDs and auth headers must not leak to unrelated backends.

Tests:

1. MCP `tools/call` receives the unprefixed tool name.
2. Backend session reused for subsequent tool call.
3. Header forwarding allowlist works.
4. Unauthorized/missing backend returns controlled tool error.
5. MCP timeout is handled.

Definition of done:

1. Responses orchestrator can execute MCP tools through Praxis-owned policy.

### PR 11: File Service Callouts

Issues: #360.

Scope:

1. Add file service client/filter primitives:
   - upload
   - retrieve
   - list
2. Add OGX-compatible HTTP backend config.
3. Add result injection into Responses input context.

Implementation instructions:

1. Keep file content size bounded.
2. Tenant and user scope must be explicit.
3. Do not put file bytes in metadata.
4. For first PR, support retrieval/listing used by model context, not full file
   management parity.

Tests:

1. Retrieve file by id and inject as context item.
2. Missing file returns controlled error.
3. Tenant isolation.
4. Oversized file rejected or truncated by explicit policy.

Definition of done:

1. File service is usable as a stateful building block.

### PR 12: Search And Vector Store Callouts

Issues: #360.

Scope:

1. Add search service callout.
2. Add vector store search callout.
3. Add tool registry integration for `web_search`, `knowledge_search`, and
   `file_search` style tools where configured locally.
4. Add result injection as tool outputs or context snippets.

Implementation instructions:

1. Start with HTTP JSON service contracts.
2. Make backend-specific payload mapping configurable enough for OGX mock and
   one generic backend.
3. Bound result count, result bytes, and citation metadata.
4. Keep embeddings generation out of this PR unless needed by the external
   service contract.

Tests:

1. Search returns deterministic context.
2. Vector store returns deterministic chunks.
3. Tool call result includes citations/metadata in bounded form.
4. Timeout and backend failure behavior.

Definition of done:

1. RAG-style tool path is available without hardwiring OGX as the loop owner.

### PR 13: OGX Non-Agentic Backend Adapters

Issues: #356, #359, #360.

Scope:

1. Add OGX-compatible adapters for:
   - conversations/responses state
   - files
   - vector stores
   - search/tool runtime if stable
2. Add examples showing Praxis orchestrator with OGX stateful services.
3. Add integration tests against OGX-shaped mocks, not necessarily a live OGX
   server.

Implementation instructions:

1. Document that OGX `/v1/responses` delegation is not Praxis-owned
   orchestration.
2. Use OGX service APIs as storage/tool service backends, not as the
   inference-loop implementation.
3. If OGX API contracts are unstable, keep the adapter generic and document
   the tested version/commit.

Tests:

1. Conversation load/persist through OGX-shaped mock.
2. File retrieval through OGX-shaped mock.
3. Vector search through OGX-shaped mock.
4. Tenant headers propagated.

Definition of done:

1. The #354 comment "use non-agentic loop pieces of OGX" is implemented in
   code and examples.

### PR 14: Final Examples, Conformance, And Documentation

Issues: #362, final #354 integration.

Scope:

1. Add complete examples:
   - stateless pass-through
   - stateful no tools
   - stateful HTTP tool loop
   - stateful MCP tool loop
   - stateful search/vector/file loop
2. Add docs for modes and caveats.
3. Add conformance-style fixtures from OpenResponses-inspired cases.
4. Add observability docs and metric cardinality guidance.

Tests:

1. All example configs parse.
2. Integration suite covers the complete flows.
3. Large-body regression included.
4. Streaming buffered mode included.
5. Security tests for reserved headers and tool spoofing included.

