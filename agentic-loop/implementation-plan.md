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

