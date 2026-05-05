# Praxis Stateful Proxy Research Notes

Primary repository: https://github.com/praxis-proxy/praxis

Reference projects:

- https://github.com/Kuadrant/mcp-gateway
- https://github.com/envoyproxy/ai-gateway
- https://github.com/cloudflare/pingora

Related planning documents:

- MCP/A2A implementation planning document
- Praxis issue/state mapping document

Note: older local docs reference `#65 Spike: Stateful Options`, but GitHub currently reports that issue as deleted. Treat `#99 Spike: Stateful Proxy Analysis` as the active stateful-analysis issue.

Relationship to the proposal draft: this document is the long-form research reference. The shorter spike proposal should cite or summarize these findings rather than duplicate every table.

## Research Summary

Praxis is moving from a mostly stateless reverse proxy into an AI-native proxy that must make decisions based on request bodies, response bodies, protocol sessions, task ownership, token usage, quota ledgers, and multi-step orchestration state.

Issue #99 asks for a proposal that inventories the state Praxis needs, then compares local and external storage mechanisms. This document is the supporting research notebook for that proposal: it captures issue mapping, terminology, comparison tables, code-inspection notes, open questions, and implementation slices to investigate.

Several feature areas drive the need for stateful proxy capabilities:

- MaaS needs token ledgers, request descriptor counters, usage accounting, policy snapshots, and quota state.
- llm-d and inference routing need endpoint metrics, KV-cache hints, scheduler decisions, model/backend affinity, and multi-step orchestration state.
- Observability, caching, security, traffic management, extension runtimes, and transport features all add state that must be scoped and bounded correctly.
- MCP and A2A need session/task state because they are not clean one-request/one-response protocols from a proxy perspective.
- MCP needs gateway session IDs, backend MCP session IDs, tool catalogs, backend session invalidation, elicitation ID mapping, and possibly SSE resumability.
- A2A needs task ID and context ID routing, streaming task update parsing, terminal task cleanup, and task ownership across replicas.

The research currently points toward a layered model:

1. Keep per-request facts in in-memory `filter_metadata`.
2. Add typed state traits for state that must outlive a single request.
3. Provide local in-memory stores for tests, dev, and single-replica mode.
4. Provide Redis/Valkey-backed stores for multi-replica correctness.
5. Keep SQL/Kubernetes/control-plane state out of the hot path except as configuration sources.
6. Define strict TTLs, key schemas, failure behavior, and observability for every state class.

## Research Scope From Issue #99

Upstream issue #99 states:

> The purpose of this spike is to analyze what state management we will need for Praxis given our current scope and goals.
>
> The result of this spike should be a proposal discussion created for us to build consensus on before we put the plan into motion.
>
> The proposal should provide a table of all the state and related features that we need to support here, and both local and external mechanisms for storing that state.

These notes are not an implementation plan by themselves. They are reference material for the proposal and for follow-up implementation issues.

## Research Context: Why Praxis Needs Stateful Proxy Capabilities

Traditional proxies try to keep request handling stateless. That is still desirable where possible, but AI gateway, security, routing, quota, and protocol features move meaningful decision state into the proxy path.

| Area | Why stateless routing is insufficient | State Praxis may need |
| --- | --- | --- |
| MCP | A client-facing MCP session may fan out to several backend MCP sessions. Later `tools/call` requests must reuse the correct backend session. | Gateway session ID, backend session map, client capability flags, backend session TTLs, invalidation state. |
| A2A | A backend that creates a task owns follow-up task operations. Later `GetTask`, `CancelTask`, or `SubscribeToTask` requests may arrive on a different proxy replica. | Task ID to backend mapping, context ID to backend mapping, terminal task cleanup. |
| MaaS token controls | Token budgets are not request counters. They are ledgers keyed by tenant/user/model/provider over windows. | Token usage counters, quota buckets, over-limit state, usage export checkpoints. |
| Inference routing | Routing may depend on recent endpoint health, cost, load, KV-cache placement, or scheduler decisions. | Routing scores, endpoint telemetry snapshots, request affinity, model/backend cache state. |
| Semantic cache | Cache hit/miss decisions depend on embedding/index lookups and response storage. | Cache index entries, response references, eviction metadata. |
| Guardrails/policy | Some policy decisions depend on external scans or stateful user/session context. | Policy decision cache, scanner call checkpoints, user/session policy snapshot. |
| Orchestration | Multi-step workflows need safe retry and checkpoint behavior. | Attempt counters, checkpoint state, selected workers, sub-request results. |
| Observability/billing | Billing-grade usage records should survive process restart and be exported reliably. | Usage events, idempotency keys, export offsets or retry state. |

## Working State Terminology

Use consistent terms while doing the spike. These categories should not be conflated in the final proposal.

| Term | Lifetime | Example | Storage expectation |
| --- | --- | --- | --- |
| Per-request metadata | One downstream request | `mcp.method`, `a2a.task_id`, extracted model name | In-memory `HttpFilterContext::filter_metadata`; never sent over the wire unless a filter explicitly uses it. |
| Per-connection state | One downstream TCP/HTTP session | client address, protocol version, HTTP upgrade state | Pingora/Praxis request or connection context. |
| Local process state | Until process restart | local token bucket, local circuit breaker, local MCP session map | In-memory store, safe only with one replica or sticky affinity. |
| Shared hot-path state | Cross-replica, latency-sensitive | rate-limit counters, MCP backend sessions, A2A task ownership | Redis/Valkey or equivalent low-latency external store. |
| Durable business state | Long lived, consistency-sensitive | tenant subscriptions, billing records, audit logs | Control plane, database, object store, event stream; usually not directly in filter hot path. |
| Configuration state | Runtime config snapshot | routes, clusters, model maps, MCP server registry | Validated config snapshot, later dynamic reload/controller. |
| Derived telemetry state | Operational signals | endpoint scores, passive health, circuit breaker status | local plus optional shared/aggregated telemetry backend. |

## Upstream Issues Used As Research Inputs

| Issue | Title | State relevance |
| --- | --- | --- |
| #99 | Spike: Stateful Proxy Analysis | Primary spike. Must produce the state inventory and local/external mechanism proposal. |
| #24 | AI Agentic Protocol Support | Umbrella for MCP, A2A, and shared sessions. |
| #25 | MCP Protocol Support | Requires MCP gateway sessions, backend session maps, tool catalogs, elicitation mapping, and possibly SSE event state. |
| #26 | Agent-to-Agent Protocol Support | Requires task/context ownership and streaming task capture. |
| #27 | Agent Sessions | Explicitly asks for shared session management, affinity, state tracking, lifecycle, timeout, cleanup, tests, and examples. |
| #28 | Sub-requests from within the filter pipeline | Adds orchestration needs: timeouts, cancellation, idempotency, checkpoints, and attempt tracking. |
| #20 | Token Counting | Produces token facts that need storage/metrics/usage accounting. |
| #21 | Token Rate Limiting | Requires distributed quota/counter state to replace Limitador-style global enforcement. |
| #42 | Traffic shaping and response caching | Requires cache state, coalescing state, and possibly shared response/semantic cache metadata. |
| #66 | Routing Scorers | Requires state/telemetry inputs for endpoint scoring and policy-driven selection. |


## Open Issue State-Needs Map

Pulled from GitHub on 2026-05-05 with `gh issue list -R praxis-proxy/praxis --state open --limit 300`. There were 93 open issues at the time of this pass. This is a research snapshot, not a permanent source of truth.

This table is intentionally broader than MCP/A2A. MCP/A2A protocol support is one source of state requirements, but the state spike is project-wide. The table below maps every open issue to the state questions it creates for Praxis.

| Issue | State needed | Local mechanism candidate | External/shared mechanism candidate | #99 spike note |
| --- | --- | --- | --- | --- |
| [#7 HTTP/3 via QUIC](https://github.com/praxis-proxy/praxis/issues/7) | QUIC connection state, connection migration events, Alt-Svc listener config. | Per-connection Pingora/QUIC context; listener config snapshot. | Shared certificate/config source only; no hot-path distributed state expected. | State spike should ensure connection migration exposes state changes to filters without cross-request persistence. |
| [#8 Prometheus Metrics](https://github.com/praxis-proxy/praxis/issues/8) | Metrics counters, histograms, active gauges, bounded label state. | In-process metrics recorder/exporter state. | Prometheus scrape storage outside Praxis. | Cardinality policy is a state concern: labels must be bounded before metrics become production state. |
| [#9 Per-filter metrics](https://github.com/praxis-proxy/praxis/issues/9) | Per-filter execution timing and phase counters. | In-process metrics recorder with filter/phase labels. | Prometheus/OTel backend for retention. | Needs label governance to avoid dynamic filter-name/cardinality problems. |
| [#10 Distributed Tracing (OpenTelemetry)](https://github.com/praxis-proxy/praxis/issues/10) | Trace context, span lifecycle, sampling state, batch export buffers. | Per-request trace metadata and local span/export queues. | OTLP collector for durable trace storage. | Trace IDs are per-request state; exporter buffers and sampling config are runtime state. |
| [#12 Authentication](https://github.com/praxis-proxy/praxis/issues/12) | Auth identity, JWT claims, JWKS cache, API-key validation cache, token-source extraction metadata. | Per-request identity metadata; local JWKS/decision cache. | JWKS endpoint, external auth/key service, optional shared policy cache. | Security-critical state should fail closed by default; cache TTL/rotation must be explicit. |
| [#14 External Auth Filter](https://github.com/praxis-proxy/praxis/issues/14) | External auth decision, propagated identity headers, timeout/failure-mode status. | Per-request auth metadata and optional short decision cache. | External auth service; possible shared decision cache. | MaaS HTTP ext-auth is a subset; full issue includes gRPC/ext_authz compatibility. |
| [#15 Istio Compatibility](https://github.com/praxis-proxy/praxis/issues/15) | xDS resources, identity certs, workload metadata, mesh telemetry state. | Local xDS resource cache and active config snapshot. | istiod/xDS control plane, SDS secret source. | State proposal must distinguish control-plane config state from data-plane hot-path state. |
| [#16 llm-d](https://github.com/praxis-proxy/praxis/issues/16) | InferencePool/model mapping, endpoint metrics, KV-cache hints, scheduler state, P/D orchestration state. | Local endpoint score snapshots and request affinity metadata. | GIE/llm-d scheduler, Redis/Valkey or metrics backend for shared routing hints. | One of the strongest drivers for stateful routing. |
| [#17 External Processing](https://github.com/praxis-proxy/praxis/issues/17) | gRPC ext_proc stream state, per-request mutation state, timeout/failure status. | Per-stream/request context; local callout bookkeeping. | External processor owns deeper policy/business state. | State layer should not force all state into Praxis when ext_proc is configured as the state owner. |
| [#18 Wasm Runtime](https://github.com/praxis-proxy/praxis/issues/18) | Wasm module lifecycle, sandbox limits, fuel/memory counters, host context propagation. | Runtime/module registry, per-invocation context, local resource accounting. | Optional module registry/config source; no required shared hot-path store. | Sandbox state must be isolated from global proxy state unless explicitly exposed. |
| [#19 AI Inference](https://github.com/praxis-proxy/praxis/issues/19) | Model/provider routing metadata, credential refs/cache, failover state, streaming token facts. | Per-request AI metadata, local credential cache, local circuit/failover counters. | Secret store, provider APIs, optional shared routing/cost state. | Core AI gateway state should be typed; avoid ad hoc header-only state. |
| [#20 Token Counting](https://github.com/praxis-proxy/praxis/issues/20) | Input/output/total token counts and tokenizer selection facts. | Per-request token metadata; local tokenizer cache. | Usage sink or quota ledger consumes counts; model tokenizer assets may be external. | Token counts are facts, not budgets. Counts should flow into quota and billing state. |
| [#21 Token Rate Limiting](https://github.com/praxis-proxy/praxis/issues/21) | Token quota buckets, windows, remaining budget, retry-after calculation. | Local token bucket only for dev/single replica. | Redis/Valkey atomic counters/scripts or external rate-limit service. | Production token limits require shared hot-path state. |
| [#24 AI Agentic Protocol Support](https://github.com/praxis-proxy/praxis/issues/24) | Shared MCP/A2A protocol facts and session/task ownership. | Per-request JSON-RPC metadata; local session/task maps for dev. | Redis/Valkey state backend for multi-replica sessions/tasks. | Shared protocol sessions are one of several state categories covered by #99. |
| [#25 MCP Protocol Support](https://github.com/praxis-proxy/praxis/issues/25) | MCP gateway sessions, backend session map, tool/catalog metadata, elicitation correlation IDs. | Local store plus sticky affinity for early/dev mode. | Redis/Valkey hashes/strings with TTL; possible encrypted client token design. | Needs explicit session lifecycle and invalidation behavior. |
| [#26 Agent-to-Agent Protocol Support](https://github.com/praxis-proxy/praxis/issues/26) | A2A task ID/context ID ownership, streaming task updates, terminal cleanup. | Local task/context map and response-derived update queue. | Redis/Valkey shared task store for multi-replica correctness. | Response-body parsing likely queues state writes for async flush. |
| [#27 Agent Sessions](https://github.com/praxis-proxy/praxis/issues/27) | Cross-protocol agent session state, lifecycle, affinity, cleanup. | Local map with TTL and consistent-hash routing caveat. | Redis/Valkey backend with TTL and cleanup semantics. | Directly maps to first typed state-store trait work. |
| [#30 Context Forge](https://github.com/praxis-proxy/praxis/issues/30) | Context Forge compatibility state: MCP/tool registry, auth identity, RBAC/workspace info, observability usage facts. | Per-request metadata and local config/tool cache. | Existing Context Forge/MaaS APIs, database/cache, Redis/Valkey if Praxis owns subset. | Research should clarify what stays in Context Forge versus Praxis data plane. |
| [#35 gRPC-aware proxying](https://github.com/praxis-proxy/praxis/issues/35) | gRPC status/trailer metadata, health check results, protocol condition facts. | Per-request trailer metadata; local health status. | Optional external health/control-plane store. | Mostly local/per-request state, but health status may feed routing state. |
| [#42 Traffic shaping and response caching](https://github.com/praxis-proxy/praxis/issues/42) | Response cache objects, coalescing locks, mirror/split counters, semantic cache metadata. | Local LRU/cache locks for dev/single node. | Redis/Valkey/object store/vector DB depending cache class. | Caching is a major state category; semantic cache should not be forced into simple KV. |
| [#45 Protocol infrastructure: PROXY protocol, CONNECT tunneling](https://github.com/praxis-proxy/praxis/issues/45) | Original client IP/protocol detection, CONNECT tunnel connection state. | Per-connection metadata from PROXY protocol and tunnel state. | None required except config/certs. | Preserved client identity becomes input to auth/rate-limit state. |
| [#49 Spike: Custom Filter Sandbox](https://github.com/praxis-proxy/praxis/issues/49) | Sandbox runtime policy, resource counters, permitted host capabilities. | Local sandbox registry and per-filter resource accounting. | Optional policy/config source. | State access must be capability-scoped for custom filters. |
| [#61 Support Envoy sidecar compatibility for AuthBridge](https://github.com/praxis-proxy/praxis/issues/61) | AuthBridge ext_proc/ext_authz call state, original destination, token exchange metadata. | Per-request auth/mutation metadata; local original-dst connection facts. | Existing AuthBridge service may own identity/token state. | Compatibility mode may externalize state through Envoy-compatible protocols. |
| [#66 Spike: Routing Scorers](https://github.com/praxis-proxy/praxis/issues/66) | Routing scorer inputs: endpoint metrics, model scores, cost, load, KV-cache hints. | Local scoring snapshots and per-request candidate metadata. | Metrics/probe backend, Redis/Valkey, scheduler service. | A core reason for shared state: routing decisions need fresh external facts. |
| [#81 Warn or reject failure_mode: open on security-critical filters](https://github.com/praxis-proxy/praxis/issues/81) | Security filter classification and failure-mode policy state. | Static config validation and per-filter security metadata. | None required. | Security-critical state should have stricter fail-open validation rules. |
| [#91 Multi-Tenancy Support](https://github.com/praxis-proxy/praxis/issues/91) | Tenant identity, tenant-scoped policy/rate limits/routing/observability dimensions. | Per-request tenant metadata from headers/auth; local dev buckets. | Shared quota/policy store and durable tenant config source. | Tenant is not a core proxy struct; it should be metadata consumed by features. |
| [#92 This Week In Rust - Initial Post](https://github.com/praxis-proxy/praxis/issues/92) | No proxy runtime state. | None. | None. | No #99 impact except project communication. |
| [#95 Avoid synchronous DNS resolution on HTTP request path](https://github.com/praxis-proxy/praxis/issues/95) | DNS cache entries, resolver health, refresh timers, negative cache state. | Local async resolver cache with TTL and bounded entries. | Optional DNS/control-plane resolver; no Redis expected. | Blocking DNS is state-adjacent because cache/refresh policy removes hot-path sync lookups. |
| [#96 Inference API Translation](https://github.com/praxis-proxy/praxis/issues/96) | Provider schema mapping state, selected provider/model facts, translation config. | Per-request translation metadata and local mapping config. | Control-plane/provider registry for mappings. | Translation should preserve state needed for response normalization and logging. |
| [#97 Epic: Mixture-of-Models / Intelligent Routing](https://github.com/praxis-proxy/praxis/issues/97) | Model topology, capability scores, routing rationale, cost/latency/load history. | Local scorer cache and per-request decision metadata. | Metrics/probe service, Redis/Valkey, control-plane model registry. | This is a broad driver for #99. |
| [#98 Gateway API Inference Extension](https://github.com/praxis-proxy/praxis/issues/98) | InferencePool/InferenceModel state, endpoint readiness, scheduler decisions. | Local reconciled config and endpoint snapshots. | Gateway API controller/GIE endpoint picker/scheduler state. | Decide what Praxis owns versus consumes from GIE. |
| [#99 Spike: Stateful Proxy Analysis](https://github.com/praxis-proxy/praxis/issues/99) | Project-wide state inventory and storage mechanism proposal. | N/A. | N/A. | Primary issue; this table is a direct input to the proposal. |
| [#100 Praxis Blog Post #1](https://github.com/praxis-proxy/praxis/issues/100) | No proxy runtime state. | None. | None. | No #99 impact except communication. |
| [#102 UDP Proxy Support](https://github.com/praxis-proxy/praxis/issues/102) | UDP flow/session table, idle timers, packet routing affinity. | Local UDP session map with TTL. | Optional shared affinity not expected initially. | Session table limits and eviction must be explicit. |
| [#107 Advanced Retry Policies](https://github.com/praxis-proxy/praxis/issues/107) | Retry attempt history, budgets, backoff timers, tried-host set. | Per-request attempt state; local retry-budget counters. | Shared retry-budget counters optional for fleet-level protection. | Retries need idempotency metadata and amplification controls. |
| [#108 Sticky Sessions / Session Affinity](https://github.com/praxis-proxy/praxis/issues/108) | Session-to-endpoint affinity map, cookies, learned upstream session IDs. | Local affinity map/cookie signer; per-request chosen endpoint. | Shared session affinity store for multi-replica correctness. | Directly overlaps MCP/A2A and tenant affinity patterns. |
| [#109 Additional Load Balancing Algorithms](https://github.com/praxis-proxy/praxis/issues/109) | Endpoint load counters, consistent-hash rings, locality metadata, priority health. | Local LB state and endpoint metadata snapshots. | Optional shared endpoint telemetry/control-plane state. | LB algorithms need bounded, versioned endpoint state. |
| [#110 Slow Start for Upstream Endpoints](https://github.com/praxis-proxy/praxis/issues/110) | Endpoint warm-up start time and effective weight. | Local endpoint lifecycle state. | Control-plane endpoint generation; shared state not required initially. | Restart behavior must be defined so slow-start does not reset dangerously. |
| [#111 Hedged Requests](https://github.com/praxis-proxy/praxis/issues/111) | Hedge request attempts, cancellation state, hedge budget counters. | Per-request parallel attempt state; local budget counters. | Optional shared hedge budget for fleet-level cap. | State spike should classify hedge budget as protection state. |
| [#112 ACME Automatic Certificate Provisioning](https://github.com/praxis-proxy/praxis/issues/112) | ACME account, challenges, cert order state, certificate storage/renewal timers. | Local challenge handling and renewal timers. | Persistent cert/key storage, Kubernetes Secrets, ACME CA. | Durable secret/cert state is not hot-path filter state but must be classified. |
| [#113 TLS Session Tickets and Resumption](https://github.com/praxis-proxy/praxis/issues/113) | TLS ticket keys, rotation windows, session cache. | Local ticket/session cache and key ring. | Shared key files/secret store across replicas. | Cross-replica resumption needs shared/rotated key state. |
| [#114 Encrypted Client Hello (ECH)](https://github.com/praxis-proxy/praxis/issues/114) | ECH key config and acceptance/retry status. | Local listener TLS state and per-connection ECH status. | Secret/config distribution for ECH keys. | Expose ECH facts to filters/logging as per-connection state. |
| [#115 Kernel TLS Offload (kTLS)](https://github.com/praxis-proxy/praxis/issues/115) | Kernel TLS capability and connection offload status. | Per-connection transport state. | None. | Mostly performance state; no shared app state. |
| [#116 Client Certificate Fields in Filter Context](https://github.com/praxis-proxy/praxis/issues/116) | Client cert fields, verification status, SPIFFE ID. | Per-connection/per-request identity metadata. | Certificate trust/config sources. | Identity metadata feeds RBAC, tenancy, and audit state. |
| [#117 TLS Certificate Compression (RFC 8879)](https://github.com/praxis-proxy/praxis/issues/117) | Certificate compression config and negotiated status. | Per-listener config and per-connection TLS fact. | None beyond cert config. | Low #99 impact. |
| [#118 Role-Based Access Control (RBAC)](https://github.com/praxis-proxy/praxis/issues/118) | RBAC policy state, authenticated principals, dry-run decisions. | Per-request identity/policy decision metadata; local policy snapshot. | Control-plane policy source; optional decision cache. | Security policy state must be versioned and fail closed. |
| [#119 CSRF Protection Filter](https://github.com/praxis-proxy/praxis/issues/119) | Trusted origin allowlist, rollout percentage, per-request CSRF decision. | Local config and per-request decision metadata. | None required initially. | Rollout percentage may need deterministic bucketing state/input. |
| [#120 WAF Integration (Coraza)](https://github.com/praxis-proxy/praxis/issues/120) | WAF rule set, inspection transaction state, provider errors. | Per-request WAF transaction state; local compiled rules. | Coraza operator/rule source; optional shared rule cache. | Rule updates and fail-mode policy should be part of state classification. |
| [#121 URL Signing / Secure Links](https://github.com/praxis-proxy/praxis/issues/121) | Signing secrets, URL expiration validation, replay/nonce state if added. | Local secret cache and per-request validation metadata. | Secret store; optional nonce/replay store. | If replay prevention is included, it requires shared state. |
| [#122 GeoIP Filter](https://github.com/praxis-proxy/praxis/issues/122) | GeoIP database cache, reload generation, per-request geo metadata. | Local MMDB cache and reload state. | Database file/config source. | Mostly local derived metadata; database refresh policy matters. |
| [#123 Connection Rate Limiting](https://github.com/praxis-proxy/praxis/issues/123) | Connection counters and rates per source IP. | Local counters for single instance. | Redis/Valkey or peer-replicated counters for fleet enforcement. | A direct non-AI distributed state requirement. |
| [#124 Bandwidth Limiting Filter](https://github.com/praxis-proxy/praxis/issues/124) | Bandwidth token buckets per connection/source IP. | Local byte token buckets. | Shared counters if per-source limits must span replicas. | Bytes/rate state should share abstractions with request/token rate limits. |
| [#125 Admin Dashboard and Stats API](https://github.com/praxis-proxy/praxis/issues/125) | Admin-visible runtime state: config, clusters, endpoints, listeners, active connections, certs, profiling state. | Local admin state snapshots. | External observability stores only for retention. | Admin API should expose state safely without becoming a mutable hot-path store by accident. |
| [#126 Customizable Access Log Format](https://github.com/praxis-proxy/praxis/issues/126) | Access log templates, output sinks, per-route overrides. | Local config and per-request formatted fields. | External log sinks. | Needs bounded variable access to metadata/state. |
| [#127 Traffic Tap / Capture Filter](https://github.com/praxis-proxy/praxis/issues/127) | Captured request/response buffers, tap sessions, runtime enablement flags. | Local ring buffers/files/admin streams. | External file/object/log sinks. | High-risk state: body capture retention, bounds, and security controls matter. |
| [#128 xDS Protocol Client](https://github.com/praxis-proxy/praxis/issues/128) | xDS resource cache, ACK/NACK versions, ADS stream state, SDS secrets. | Local xDS cache and active config snapshot. | xDS control plane; secret source. | Major config-state input to #99; config state and request state must remain separate. |
| [#130 Runtime Key-Value Store](https://github.com/praxis-proxy/praxis/issues/130) | Runtime-updatable key-value mappings for routing, rate limiting, variables. | Local named KV stores with optional persistence. | Admin API/file persistence; possibly shared store later. | This is a generic state primitive and must not become an unsafe replacement for typed domain stores. |
| [#131 Config Validation and Dump Mode](https://github.com/praxis-proxy/praxis/issues/131) | Effective config snapshot and validation output. | Local parse/validation state. | None. | Useful for making state-bearing config inspectable before startup. |
| [#133 Dynamic Filter Loading via Shared Libraries](https://github.com/praxis-proxy/praxis/issues/133) | Dynamic module registry, ABI version state, loaded library lifecycle. | Local loaded filter registry. | Plugin artifact source if added. | State access for dynamic filters must be constrained. |
| [#134 Go Extension System](https://github.com/praxis-proxy/praxis/issues/134) | Go runtime/filter process lifecycle, unix socket shim sessions, resource accounting. | Local embedded runtime state or per-shim process state. | Out-of-process shim may own custom state. | Extension systems need state API boundaries and sandbox rules. |
| [#136 LLM Provider Failover](https://github.com/praxis-proxy/praxis/issues/136) | Failover chain position, provider circuit state, translation context, failover event metadata. | Per-request failover attempt state and local provider breakers. | Optional shared health/routing state. | Failover decisions must be observable and may feed cost/budget state. |
| [#137 Prompt Enrichment Filter](https://github.com/praxis-proxy/praxis/issues/137) | Prompt enrichment config and per-request mutation metadata. | Local config and request body transformation state. | External prompt store if dynamic prompts are supported later. | If prompts become dynamic, state source/security must be explicit. |
| [#138 Multi-Provider AI Guardrails](https://github.com/praxis-proxy/praxis/issues/138) | External guardrail callout decisions, PII findings, response inspection state. | Per-request findings metadata; local recognizer config. | External guardrail providers; optional decision/audit sink. | Security/content state should define retention and fail-mode behavior. |
| [#139 Model Aliasing](https://github.com/praxis-proxy/praxis/issues/139) | Model alias table and resolved model metadata. | Local alias config and per-request resolved model metadata. | Control-plane model registry if dynamic. | Alias resolution becomes input to routing/cost state. |
| [#140 AI Cost and Budget Controls](https://github.com/praxis-proxy/praxis/issues/140) | Cost budgets, token ledgers, attribution dimensions, budget status. | Local only for tests/dev. | Redis/Valkey counters plus durable usage/billing sink. | This is one of the clearest requirements for shared state. |
| [#141 Built-in PII Detection](https://github.com/praxis-proxy/praxis/issues/141) | Recognizer definitions and per-request PII findings/masks. | Local compiled regex recognizers and findings metadata. | External recognizer/rule source optional. | Findings retention must be carefully scoped for privacy. |
| [#142 Prompt Caching Configuration](https://github.com/praxis-proxy/praxis/issues/142) | Prompt caching policy, cache eligibility facts, provider cache-control state. | Local policy config and per-request cache metadata. | Provider cache state; optional shared cache metadata. | Clarify whether Praxis only configures provider caching or owns cache entries. |
| [#144 OpenAPI-to-MCP Bridge](https://github.com/praxis-proxy/praxis/issues/144) | OpenAPI spec cache, generated MCP tool definitions, server prefix mappings. | Local parsed spec/tool catalog cache. | Spec source/control plane; optional shared catalog. | This is primarily config/catalog state. |
| [#145 Overload Manager](https://github.com/praxis-proxy/praxis/issues/145) | Resource pressure readings, overload level, action state. | Local monitors and overload state machine. | Cluster-level pressure aggregation optional later. | Protective state must be cheap and local first; exported to metrics/admin. |
| [#146 Zero-Downtime Binary Upgrade](https://github.com/praxis-proxy/praxis/issues/146) | Inherited listener sockets, drain state, in-flight connection set, stats continuity. | Local old/new process coordination state. | Shared stats store optional; OS FD passing. | Upgrade state is process/runtime state, not filter state. |
| [#147 io_uring Support](https://github.com/praxis-proxy/praxis/issues/147) | io_uring operation state and benchmark telemetry. | Kernel/local runtime state. | None. | Low #99 impact beyond transport runtime state. |
| [#148 Zero-Copy Forwarding](https://github.com/praxis-proxy/praxis/issues/148) | Forwarding-mode eligibility and per-connection zero-copy state. | Local connection/body-mode state. | None. | Interacts with body filters: stateful inspection disables some zero-copy paths. |
| [#149 TCP Tuning Configuration](https://github.com/praxis-proxy/praxis/issues/149) | Socket option config and listener runtime state. | Local listener/socket state. | None. | Low #99 impact. |
| [#150 Request and Response Decompression](https://github.com/praxis-proxy/praxis/issues/150) | Compression/decompression stream state and body-mode facts. | Per-request streaming decoder/encoder state. | None. | Important for content filters because body state may expand and must remain bounded. |
| [#151 Response Body Rewriting Filter](https://github.com/praxis-proxy/praxis/issues/151) | Response rewrite matcher state and buffered/streaming replacement state. | Per-response transformation state. | None. | State spike should classify body-transform state as bounded per-request state. |
| [#153 Fault Injection Filter](https://github.com/praxis-proxy/praxis/issues/153) | Fault policy, random fraction counters/seeds, override metadata. | Local config and per-request decision metadata. | Optional shared experiment config. | Mostly local; deterministic rollout may need stable hashing inputs. |
| [#154 Body Transformation Filter](https://github.com/praxis-proxy/praxis/issues/154) | Request/response transformation state, expression variables, buffered body state. | Per-request body mutation state. | External template/config source optional. | Must be bounded and composed with body access modes. |
| [#155 Distributed In-Memory Counters](https://github.com/praxis-proxy/praxis/issues/155) | Distributed counters for clients/sessions/errors/bytes. | Local bounded in-memory table with expiry. | Peer replication or Redis/Valkey for distributed enforcement. | This is a central candidate primitive for state architecture; compare with typed stores. |
| [#156 Advanced Condition and Matching System](https://github.com/praxis-proxy/praxis/issues/156) | Reusable condition definitions, extracted variables, sample fetch values. | Per-request match context and local compiled matchers. | Control-plane config source only. | Must decide how conditions read state/metadata without materializing everything. |
| [#158 CEL Policy Engine](https://github.com/praxis-proxy/praxis/issues/158) | CEL compiled expressions, evaluation context variables, optional policy decision cache. | Local compiled expression cache and per-request eval context. | External policy/config source optional. | CEL will pressure the metadata/state API; avoid unrestricted access to expensive state. |
| [#159 Guardrails](https://github.com/praxis-proxy/praxis/issues/159) | Guardrail rule/provider state, inspection findings, decision/audit facts. | Per-request findings and local rule config. | External guardrail providers and audit sinks. | Umbrella issue; overlaps #120/#138/#141. |
| [#160 Observability](https://github.com/praxis-proxy/praxis/issues/160) | Metrics/traces/logs/admin runtime state. | Local exporters, buffers, active gauges. | Prometheus/OTLP/log sinks. | Umbrella for observability state and cardinality policy. |
| [#161 TLS Hardening](https://github.com/praxis-proxy/praxis/issues/161) | TLS runtime/config state. | Local TLS listener/connection state. | Secret/cert distribution where applicable. | Umbrella; details in #112-#117. |
| [#162 Security](https://github.com/praxis-proxy/praxis/issues/162) | Identity, authz, threat decision state. | Per-request identity/decision metadata and local policies. | Auth services, policy sources, shared decision cache. | Umbrella; security state should define fail-closed defaults. |
| [#163 Resilience and Traffic Management](https://github.com/praxis-proxy/praxis/issues/163) | LB/retry/rate-limit/cache/overload state. | Local counters, health, buckets, circuit state. | Redis/Valkey/probes/control plane for shared state. | Umbrella for much of the operational state model. |
| [#164 Extensibility Platform](https://github.com/praxis-proxy/praxis/issues/164) | Extension runtime/module state and host capability access. | Local runtime registries and per-extension resource state. | External extension services/artifacts. | Extensions need explicit state APIs and isolation boundaries. |
| [#165 Performance Engineering](https://github.com/praxis-proxy/praxis/issues/165) | Transport performance runtime state. | Local connection/socket/kernel state. | None generally. | Umbrella; mostly local/per-connection state. |
| [#166 Content Processing](https://github.com/praxis-proxy/praxis/issues/166) | Body inspection/transformation streaming state. | Per-request body buffers/parsers/decoders. | External providers only for some inspection modes. | Umbrella; body state must be bounded and compatible with StreamBuffer. |
| [#170 Pipeline Parallelization](https://github.com/praxis-proxy/praxis/issues/170) | Parallel filter task graph, scatter/gather results, cancellation and timeout state. | Per-request async task state and result aggregation. | External callout services may own sub-state. | Needs careful lifecycle design so state writes do not race after request cancellation. |
| [#171 Spike: Machine Learning Framework](https://github.com/praxis-proxy/praxis/issues/171) | Model/runtime assets, embedding/classification outputs, local ML inference caches. | Local ML model registry/cache and per-request inference metadata. | Model artifact store; optional vector/cache backend. | ML outputs become routing/cache/policy state; model loading state is large and long-lived. |
| [#172 Spike: Probes](https://github.com/praxis-proxy/praxis/issues/172) | Long-running probe process state, message queues, latest probe readings. | Local probe registry and cached readings. | Metrics systems or shared state if readings feed multi-replica decisions. | Probes may become the standard source of routing scorer state. |
| [#173 Feature: Agent-to-Proxy Feedback Loop for Dynamic Service Level Adjustment](https://github.com/praxis-proxy/praxis/issues/173) | Agent feedback, session-level escalation state, backend quality scores. | Per-session feedback cache and local aggregate scores. | Redis/Valkey or telemetry store for shared adaptation. | Feedback-driven adaptation intersects intelligent routing and stateful policy. |
| [#174 Feature: Response Metadata for Routing Transparency and Policy Overrides](https://github.com/praxis-proxy/praxis/issues/174) | Routing decision metadata, override reasons, debug traces, propagated policy signals. | Per-request decision metadata and optional debug trace buffer. | Audit/log sink for longer retention. | Response transparency depends on preserving decision state through response phase. |

## Current Praxis State Baseline To Verify

This is the starting point to validate during the research phase. Treat these as inspection notes until confirmed against the target branch for implementation.

| Existing mechanism | Location | State type | Current limits |
| --- | --- | --- | --- |
| `filter_metadata` | `filter/src/context.rs`, `protocol/src/http/pingora/context.rs` | Per-request durable metadata across Pingora phases | In-memory only; not suitable for session/task state across requests. |
| `filter_results` | filter pipeline | Temporary branch evaluation output | Cleared during pipeline execution; intentionally not durable. |
| Request/response body counters | `PingoraRequestCtx` | Per-request observability facts | Per-request only. |
| Load balancer state | `filter/src/load_balancing` and built-in LB filters | Local process routing/health selection | Not shared across replicas. |
| Consistent hash | `filter/src/load_balancing/consistent_hash.rs` | Stateless-ish affinity selector based on input key | Helps local store mode only when paired with sticky routing. |
| Rate limiter local buckets | `filter/src/builtins/http/traffic_management/rate_limit` | Local request counters | Not distributed; restart loses state; insufficient for global quotas. |
| Circuit breaker | `filter/src/builtins/http/traffic_management/circuit_breaker` | Local endpoint/cluster health state | Local only; good for fast local protection but not global truth. |
| Pingora cache/LRU code | `pingora-cache`, `pingora-lru` | Local cache primitives | Useful reference, but not a shared state layer for Praxis filters. |
| Config snapshot | Praxis config loader/pipeline build | Runtime config | Hot reload is separate issue; control-plane state not solved here. |

## State Inventory Research Table

The final proposal should distill this table into decisions. This research version intentionally keeps candidates and unresolved failure behavior visible.

| Feature area | State item | Key | Value | Lifetime / TTL | Consistency need | Local mechanism | External mechanism | Failure behavior to decide |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MCP sessions | Gateway session | `mcp:session:{gateway_session_id}` | session metadata, expiry, client capabilities | minutes to hours | Strong enough that requests in same session route correctly | local map + sticky affinity | Redis/Valkey hash/string with TTL | fail closed for protected sessions; maybe reinitialize on miss |
| MCP backend sessions | Backend session map | `mcp:session:{gateway_session_id}:backends` or hash field `{server_name}` | backend `MCP-Session-Id`, backend path/cluster, expiry | tied to gateway session | Must be correct for backend session reuse | local map | Redis/Valkey hash with TTL | reinitialize on miss; remove on backend 404 |
| MCP client capabilities | Elicitation support, negotiated protocol version | gateway session ID | booleans/version/capabilities | tied to gateway session | Needed for feature behavior | local map | Redis/Valkey key/hash | default false/lowest capability on miss |
| MCP tool catalog | Exposed tool registry | route/server/tool | original tool, server, annotations, prefix | config lifetime; refreshable | Eventually consistent is acceptable | config snapshot / local cache | control plane or Redis cache | stale catalog should be bounded and observable |
| MCP elicitation ID map | Gateway request ID to backend request ID | `mcp:elicitation:{gateway_id}` | backend ID, server, backend session, gateway session | short, e.g. 1 hour safety TTL | Must route client response correctly | local map | Redis/Valkey string JSON with TTL | fail closed with JSON-RPC error on miss |
| MCP SSE resume | Last event IDs per backend | gateway session ID + event ID | backend event IDs | tied to session or stream | Needed for reconnect semantics | encoded token or local map | Redis/Valkey hash/string | degrade to no resume if unsupported |
| A2A task ownership | Task to backend map | `a2a:task:{task_id}` | backend agent/cluster, context ID, route, expiry/status | until terminal state + TTL | Strong enough for follow-up routing | local map + sticky affinity | Redis/Valkey string/hash with TTL | fail closed or fallback routing policy on miss |
| A2A context ownership | Context to backend map | `a2a:context:{context_id}` | backend agent/cluster, latest task IDs | conversation/task lifetime | Strong enough for context follow-ups | local map | Redis/Valkey hash/list | fallback policy must be explicit |
| A2A streaming updates | Pending task updates from SSE response body | request-local queue | task/context mappings to write later | one request until async logging flush | Must not block sync body hook | request-local queue | flushed to Redis/Valkey in logging | retry/best-effort policy required |
| Token quotas | Tenant/user/model/provider buckets | descriptor key + window | consumed tokens, reset time | windowed | Global correctness across replicas | local only for dev | Redis/Valkey atomic counters or scripts | fail closed for paid/quota enforcement |
| Token usage events | Billing/showback event | idempotency key/request ID | usage dimensions and counts | durable export horizon | At-least-once acceptable with idempotency | local buffer not enough | event sink/database/Redis stream | retry with bounded buffer; never lose silently |
| Request descriptor limits | request admission bucket | descriptor key + window | count/remaining/reset | windowed | Global correctness desired | local token bucket | Redis/Valkey atomic bucket | fail closed/open configurable by filter class |
| Semantic cache | semantic key/vector ref | embedding hash/vector ID | cached response ref, metadata | TTL/eviction | Eventually consistent OK | local LRU | vector DB + Redis/Valkey metadata | miss safe; stale hit policy needed |
| Routing scorer inputs | endpoint/model scores | endpoint/model key | load, latency, health, cost, queue, KV-cache hints | seconds | Freshness more important than durability | local snapshots | metrics service/Redis/Valkey | stale data should expire fast |
| Orchestration checkpoints | multi-step workflow state | request ID/workflow ID | selected workers, completed steps, attempts | request/workflow lifetime | Idempotency-critical | local only unsafe for retry/restart | Redis/Valkey/DB with compare-and-set | fail closed or restart from checkpoint |
| Policy decision cache | auth/guardrail decision | subject + route + policy version | allow/deny/reason/expiry | short TTL | Must respect policy version | local LRU | Redis/Valkey | miss -> recompute |
| Provider credentials | upstream auth material | provider/backend ID | secret ref/token/cache metadata | rotation lifetime | Must be secure and current | memory cache of secret data | Kubernetes Secret/control plane + local cache | fail closed on missing/expired secret |
| Config/runtime state | active config version | config generation | routes, filters, state backend config | until reload | Atomic snapshot | Arc-swapped local config | controller/Kubernetes API | reject invalid config; keep old |

## Local Vs External State Mechanisms

The proposal should not choose one store for everything. The right model is per-state-class.

| Mechanism | Good for | Not good for | Pros | Risks / caveats |
| --- | --- | --- | --- | --- |
| Per-request `filter_metadata` | Body-derived facts used later in same request | Cross-request sessions, quotas, task ownership | Zero network hop, already in Praxis path, no wire exposure | Dies at request end; unbounded key/value use could become sloppy without conventions. |
| Local `HashMap`/`DashMap` | Unit tests, dev, single replica, fast local state | Multi-replica correctness, restart survival | Simple, fast, no external dependency | Requires sticky affinity for sessions; memory growth/eviction must be explicit. |
| Sharded local LRU | Caches, policy decisions, semantic local cache metadata | Durable sessions or quotas | Bounded memory, fast, can be combined with external miss path | Eviction can break workflows if used for required state. |
| Consistent-hash affinity | Keeping a session on same replica | Global correctness by itself | Cheap migration bridge for local stores | Replica changes break mapping; not enough for production multi-replica sessions. |
| Redis/Valkey | Hot-path shared state: sessions, task maps, counters, short TTL ID maps | Long-term billing/audit as only copy | Low latency, atomic operations, TTLs, hashes, scripts, widely deployed | Network dependency; failure mode must be explicit; key schema and cardinality matter. |
| Postgres/SQL | Durable business state, billing records, admin-visible objects | Per-request hot path decisions | Stronger durability and query model | Too slow/heavy for every filter decision unless cached. |
| Kubernetes API/CRDs | Declarative config, policies, resource specs | Request path lookups | Fits operator/controller model | Never do synchronous Kubernetes API calls in the hot path. |
| Object store | Large cached response bodies, audit blobs | low-latency routing/session state | Cheap durable storage | Not suitable for request routing decisions. |
| Event stream / queue | Usage events, audit, async exports | Immediate admission decisions | Decouples billing/export from hot path | Requires idempotency, retry, backpressure strategy. |
| Embedded SQLite/RocksDB | single-node durable local cache | multi-replica shared truth | Useful for edge deployments | Operational complexity; not first choice for cluster mode. |

## Comparable Project Research

This is the initial comparison map. The research phase should fill in exact code links, behavior tests, and gaps where needed.

### Project State Mechanism Summary

This table is the quick comparison view: what each comparable project uses for state today, and where that state lives.

| Project | Proxy / gateway type | Request-local state | Local process / node state | Shared hot-path state | Durable / control-plane state | Notes for Praxis |
| --- | --- | --- | --- | --- | --- | --- |
| Praxis today | Pingora-based Rust proxy | `HttpFilterContext`, `PingoraRequestCtx`, `filter_metadata`, `filter_results`, body counters | Local load-balancer state, local rate-limit buckets, circuit breakers, health snapshots | Not generally available yet | Static config files; future controller/xDS work | Starting point. Need typed state traits plus explicit local/shared modes. |
| Pingora | Rust proxy framework | `Session` and app-specific context | Connection pools, caches, LRU, health/load-balancing state, background services | None built in for product/application state | Runtime/config owned by embedding application | Provides mechanics, not MCP/A2A/MaaS state semantics. |
| Pingap | Pingora-based reverse proxy | Plugin request/response lifecycle context | Plugin-local rate/concurrency counters, memory cache, file cache, cache locks, hot-reload config | Not evident in public docs for rate limiting | TOML files and web-admin-managed config | Good local bounded state/cache reference; not a distributed-session reference. |
| River | Pingora-based reverse proxy | Request/path-control context | Per-service leaky buckets, ARC-bounded bucket cache, static service config, local LB state | None documented | KDL/TOML static config | Strong example of documenting `max-buckets`, eviction, and cardinality tradeoffs. |
| Sentinel / `sentinel-proxy` | Pingora-based security/AI reverse proxy | Request context, route match facts, agent call context | `DashMap`/atomic local rate limits, route cache, circuit breakers, cache, health state | Redis and Memcached for distributed rate limiting | Config, optional Kubernetes/discovery integrations | Closest feature-shape comparison; verify source before treating docs as implementation truth. |
| Envoy | General-purpose C++ proxy | `StreamInfo`, dynamic metadata, filter state | Local rate-limit buckets, cluster health, circuit breakers, xDS cache, connection pools | gRPC RLS, Redis-backed RLS, external auth/proc services | xDS management server, SDS, control plane | Clear split: request facts in metadata; shared enforcement delegated externally. |
| Envoy AI Gateway | Envoy Gateway extension for AI traffic | AI metadata, token usage metadata, MCP metadata | Local request context and route processing | Redis/global rate-limit path through Envoy Gateway/RLS | Kubernetes CRDs/controllers | Useful for token metadata -> quota policy flow. |
| Kuadrant MCP Gateway | Envoy ext_proc-based MCP gateway | Buffered MCP request/response context | In-memory `sync.Map` sessions and ID maps | Redis session cache and Redis ID map option | Kubernetes resources/secrets/operator config | Strong MCP-specific model for local-vs-Redis session state. |
| Limitador / Kuadrant rate limiting | External rate-limit service | Per-check descriptor request | Local service memory for processing | Redis or configured backend for counters | Kuadrant policy/control plane | Relevant for Praxis token/request quota replacement. |
| HAProxy | C proxy/load balancer | Transaction variables/fetches | Stick tables with typed keys, counters, rates, tags, expiry | Peer synchronization for stick tables | Static/runtime config | Best model for typed bounded state tables. |
| NGINX OSS | C web/proxy server | NGINX variables/request context | Worker-shared memory zones for rate/connection limits | None for cluster-wide OSS state | Static config | Good model for named/sized local state zones and behavior when full. |
| NGINX Plus | Commercial NGINX | Same as NGINX | Shared memory zones, keyval zones, sticky learn | `zone_sync` between cluster nodes | Static/API config depending deployment | Shows eventual-consistency peer sync tradeoffs. |
| OpenResty | NGINX + Lua platform | NGINX/Lua request context | `lua_shared_dict`, local Lua caches, shared memory zones | Redis/databases used by Lua code when needed | NGINX config and Lua code/config | Flexible but risky: raw shared dictionaries can become unstructured global state. |
| Kong Gateway | OpenResty/API gateway | Plugin request context and PDK data | Per-node plugin cache and local counters | Redis or database-backed plugin state for rate limiting | Kong database/control plane or DB-less config | Good pattern: plugins expose `local`, `cluster`, and `redis` strategies with documented tradeoffs. |
| Apache APISIX | OpenResty/API gateway | Plugin context | Local plugin state and standalone in-memory config | Redis/Redis Cluster for rate-limit plugins | etcd configuration center, or standalone file/API mode | Strong reminder to separate config state from hot-path counter/session state. |
| Traefik | Go reverse proxy / ingress | Middleware request context | Per-instance rate limiters, health state, sticky-cookie decisions | Redis/persistent KV for distributed rate limiting in distributed middleware | Dynamic providers/Kubernetes/file config | Local by default; distributed state is explicit and feature-specific. |
| Caddy | Go web/proxy server | Request context and placeholders | Local cert/cache/runtime state | Shared storage modules can coordinate certificates across instances | Persistent certificate/key/ACME storage | Useful background-state model: cert automation state is durable but not request-path state. |
| Linkerd proxy | Rust service-mesh sidecar | Per-request/connection telemetry context | Local connection/load/identity/metrics state | Control plane supplies destination/identity, not shared proxy KV | Linkerd control plane, destination API, identity service | Good scoping lesson: keep data plane narrow unless protocol semantics demand state. |
| Istio ztunnel | Rust L4 ambient mesh proxy | Per-connection identity/tunnel state | Local HBONE/mTLS/L4 telemetry state | Istiod xDS/CA provides config and certs | Istiod control plane | Another scoping example: purpose-built proxy keeps only the state it needs. |

### Project State Mechanisms By Use Case

This table compares what projects use for common state classes. It should guide the #99 recommendation toward per-feature storage decisions instead of one global state mechanism.

| State use case | Projects with local/node implementation | Projects with external/shared implementation | Common mechanism | Praxis implication |
| --- | --- | --- | --- | --- |
| Request-local metadata | Praxis, Envoy, Envoy AI Gateway, Pingora apps, Kong/APISIX plugins, Traefik middleware | Usually exported only through logs/traces/metrics | Request context, dynamic metadata, filter state, plugin context | Keep `filter_metadata` request-local. Use it to feed later filters, not as durable storage. |
| Local request rate limiting | Praxis, Envoy, NGINX, HAProxy, River, Pingap, Kong, APISIX, Traefik, Sentinel | Envoy RLS, Kong Redis/database, APISIX Redis, Traefik distributed rate limit, Sentinel Redis/Memcached, Limitador/Kuadrant | Token bucket, leaky bucket, sliding/fixed windows, stick tables, shared counters | Praxis should support local for dev/single-node and Redis/Valkey or service-backed mode for global enforcement. |
| Token/cost quotas | Envoy AI Gateway, Praxis planned, Sentinel docs claim token limits | Envoy Gateway/RLS/Redis path, Limitador-like service, future Praxis Redis/Valkey ledger | Per-request token facts plus external quota ledger | Token counting should write request facts; quota enforcement needs shared state. |
| Session affinity | Envoy stateful session, Traefik sticky cookies, HAProxy stick tables, Praxis consistent hash, Pingap session persistence | HAProxy peers, NGINX Plus sticky learn sync, Redis-backed custom stores | Cookie/header state, stick table, consistent hash, shared session map | Client-carried or local affinity is useful but not enough for required MCP/A2A state unless signed/encrypted or shared. |
| Protocol sessions | Kuadrant MCP Gateway, Envoy AI Gateway MCP, Praxis planned | Kuadrant Redis, possible encrypted client tokens, future Praxis Redis/Valkey | Gateway session ID -> backend session map, ID maps, TTLs | MCP/A2A support needs typed `McpSessionStore`/`A2aTaskStore`, not generic ad hoc maps. |
| Response/object cache | Pingap, NGINX, OpenResty, Caddy, Sentinel, Pingora cache crates | NGINX Plus sync/keyval, external object stores/vector DBs where needed | Memory LRU, file cache, object storage, cache locks | Cache state deserves separate APIs from quota/session state, especially for semantic cache. |
| Cache stampede / request coalescing | Pingap, NGINX/OpenResty patterns, Praxis planned #42 | Could use Redis locks but usually local first | Per-key in-flight lock/coalescing table | Treat in-flight coordination as ephemeral bounded state with timeout/cancellation rules. |
| Dynamic config | Envoy, APISIX, Kong, Traefik, Linkerd, Istio, Caddy, Praxis planned xDS | xDS, etcd, Kubernetes/control plane, admin API, config files | Config snapshots, versioned resources, watch streams | Keep config state separate from hot-path counter/session state. Store config generation with session/task mappings if needed. |
| Runtime KV / generic maps | OpenResty, NGINX Plus keyval, HAProxy stick tables, Praxis #130 | NGINX Plus sync, Redis if used by apps/plugins | Named key-value zones, dictionaries, stick tables | Useful but dangerous. Praxis should prefer typed domain stores and capability-scoped extension access. |
| Certificate/TLS automation | Caddy, NGINX, Envoy/Istio/Linkerd, Praxis planned | Shared cert storage, SDS, Kubernetes Secrets, CA services | File/shared storage, xDS/SDS, CA clients | TLS/cert state is durable background/runtime state, not request-path business state. |
| External processing/auth state | Envoy ext_proc/ext_authz, Kong/APISIX plugins, Praxis planned, AuthBridge | External auth/proc services own policy/session/cache state | gRPC/HTTP callouts plus local per-request result metadata | External services remain valid fallback owners for complex state, but add latency and failure modes. |
| ML/semantic routing state | Praxis planned, Sentinel docs, GIE/llm-d patterns | Probe services, metrics backends, vector DBs, Redis/Valkey snapshots | Score caches, embeddings, endpoint metrics, model registry | Routing scorers need fresh bounded state; vector/semantic data should not be forced into simple Redis KV. |

| Project | Stateful features observed | Storage model | What Praxis should learn | Concerns / follow-up research |
| --- | --- | --- | --- | --- |
| Kuadrant MCP Gateway | Gateway session to backend session mapping; client elicitation capability flags; elicitation request ID mapping; backend 404 session invalidation; JWT session IDs; optional Redis session store. | In-memory `sync.Map` by default; Redis optional via `CACHE_CONNECTION_STRING`; Redis hashes for sessions; Redis string+TTL for elicitation ID map. | Useful model for MCP local-vs-Redis state split. Their `SessionCache` interface is close to what Praxis needs for `McpSessionStore`. Elicitation mapping shows short-lived ID maps need TTL safety. | Need deeper analysis of TTLs for main sessions, crash cleanup, race behavior, and multi-replica deployment guidance. |
| Envoy AI Gateway MCP proxy | Composite/encrypted client-facing MCP session IDs that encode per-backend sessions; parallel backend initialization; progress token rewriting to encode backend route; aggregation across backends; per-backend event IDs. | More state is encoded into secure client-facing IDs instead of always using an external store; local request context builds sessions from decrypted IDs. Rate limit features use Envoy Gateway/global rate limit/Redis separately. | Stateless encrypted tokens can reduce external store dependence for some MCP session mappings. Progress-token encoding is an alternative to external ID maps for routing client follow-ups. | Need evaluate token size limits, secret rotation, revocation, privacy, and whether Praxis wants this model or Redis-backed opaque session IDs. |
| Envoy dynamic metadata / AI Gateway token usage | Token usage and request costs are captured into per-request dynamic metadata and consumed by rate-limit policy. | Per-request metadata for extraction; external/global rate limiter for quotas. | Mirrors Praxis `filter_metadata`: per-request facts are not the quota ledger. Good pattern: extract cost into metadata, then burn distributed budget elsewhere. | Need map to Praxis metrics/metadata APIs and avoid high-cardinality labels. |
| Envoy ext_proc / external auth patterns | External services can hold policy/session/cache state while Envoy stays mostly stateless. | State outside proxy; Envoy gets decisions/mutations over gRPC. | Good migration fallback for stateful logic before native Praxis state APIs mature. | Adds latency and operational complexity; not a long-term native state architecture. |
| Pingora | Per-request context, local caches, LRU, health/load-balancing state, background services. | Primarily local in-process state. | Useful runtime primitives and local cache patterns; keep transport/runtime state separate from protocol/business state. | Pingora does not solve distributed state for Praxis filters. |
| Limitador / Kuadrant rate limiting | Distributed rate-limit counters for policy enforcement. | External store such as Redis for global counters. | Token/request quotas need atomic distributed counters; local buckets are only dev/single-replica. | Need compare exact counter algorithms, headers, metrics, and migration expectations. |
| Gateway API Inference Extension / endpoint picker | Endpoint picker holds model/pod metrics and makes routing decisions. | External picker/scheduler has its own state; proxy receives selected endpoint. | Routing scorer state may live outside Praxis at first, or Praxis may need a scorer input cache. | Ext_proc-style decision point is insufficient for orchestration; see #28. |
| Linkerd/ztunnel/service mesh data planes | Data planes are intentionally low-state; control planes own durable config; some local metrics/connection state. | Mostly local ephemeral state plus control-plane config. | Confirms the default proxy posture: keep durable business state out unless the protocol requires it. | Less directly useful for MCP/A2A because those protocols require session/task semantics at gateway. |
| Agent Gateway / other MCP/A2A gateways | Needs review for MCP/A2A session/task handling, especially if they encode state in tokens or use stores. | Unknown until researched. | May offer patterns for A2A task ownership and agent card routing. | Need careful security/governance review; do not assume architecture is production-safe. |

## General Proxy State Management Research

This section broadens the research beyond the project-specific references. The point is not to copy another proxy directly; it is to identify repeatable patterns Praxis should adopt or avoid.

| Proxy / gateway | State pattern | Local mechanism | External / shared mechanism | Consistency model | Praxis takeaway |
| --- | --- | --- | --- | --- | --- |
| Envoy | Separates per-request facts from shared enforcement. Filters emit dynamic metadata/filter state; global quotas are delegated to external rate-limit services. | `StreamInfo` dynamic metadata/filter state, local rate-limit token buckets, local cluster/health state, local xDS resource cache. | gRPC Rate Limit Service, often backed by Redis; xDS management server; optional stateful-session cookie/header state. | Per-request metadata is local only; global rate limit consistency depends on RLS/Redis; xDS is eventually updated through config streams. | Praxis should keep `filter_metadata` as request-local facts and use typed external stores/services for cross-replica quotas, sessions, and scheduler decisions. Do not make request metadata a global ledger. |
| Envoy stateful session filter | Strong session affinity can override load balancing by storing selected upstream in a cookie/header-backed session state object. | Cookie/header session state parsed per request; selected upstream written back on response. | Extensible session-state implementations can be added, but built-in examples are client-carried cookie/header. | Stronger than hash affinity, but can imbalance load and has security implications. | Praxis sticky/session features need explicit security and reliability warnings. Client-carried state is useful, but it must be signed/encrypted or bounded to non-sensitive endpoint IDs. |
| HAProxy | Uses stick tables as fast typed in-memory tables for persistence, rate limiting, abuse detection, counters, and tags. Tables have explicit key type, size, expiry, and stored fields. | In-memory stick tables with counters/rates/tags; efficient read/write on request path. | Peer synchronization for stick tables; Enterprise has stronger active-active clustering features. | Local by default; peer sync is eventually replicated and scoped to configured peers/tables. | Praxis should copy the discipline, not the implementation: every state table needs a key type, max size, expiry, stored fields, and explicit replication story. |
| NGINX OSS | Uses shared memory zones across workers for request limits, connection limits, and related counters. Zones are explicitly named and sized. | Worker-shared memory zones such as `limit_req_zone` and `limit_conn_zone`; oldest entries evicted when full. | None in OSS for cluster-wide consistency. | Consistent across workers in one process group; not consistent across cluster nodes. | Praxis local state should be bounded and observable, with deterministic behavior on full tables. Local process state is not multi-replica state. |
| NGINX Plus | Extends shared-memory zone state across nodes with `zone_sync` for sticky learn, request limiting, and key-value zones. | Same shared-memory zones as NGINX, plus local key-value zones. | Cluster runtime state synchronization between NGINX Plus instances. | Eventually consistent; docs warn against stretching clusters over high-latency/unreliable networks. | If Praxis ever does peer replication, it should be explicit about eventual consistency and topology limits. Redis/Valkey is likely simpler first. |
| OpenResty | Exposes shared dictionaries (`lua_shared_dict`) to Lua code, commonly used for plugin state, rate limits, caches, and custom counters. | NGINX shared memory dictionaries available to Lua workers. | External Redis/databases are commonly used by Lua code when state must be cross-node. | Worker-shared locally; cross-node state requires explicit external backend. | Custom filter APIs need constrained state primitives. Unstructured shared dictionaries are flexible but can become hard to reason about. |
| Kong Gateway | Plugins often choose among local, database/cluster, and Redis strategies. Rate limiting documents the latency/consistency tradeoff between local counters and shared stores. | NGINX/OpenResty worker memory and per-node plugin cache. | Kong database/control plane for config; Redis or database-backed counters for shared rate limiting depending strategy. | Local is per-node; Redis/database improves cluster consistency at request-time cost. | Praxis should expose strategy choices per feature: `local` for dev/edge/single replica, `redis` or service-backed for production cross-replica enforcement. |
| Apache APISIX | Uses etcd as configuration center in traditional mode; can run standalone without etcd. Rate-limit plugins support local, Redis, and Redis Cluster policies. | Local plugin state and in-memory standalone config mode. | etcd for dynamic config; Redis/Redis Cluster for distributed rate-limit counters. | Config consistency through etcd watch/update model; plugin counter consistency depends on selected policy. | Keep config-state and hot-path counter/session-state separate. etcd/xDS-like config should not become the hot-path quota ledger. |
| Traefik | Middleware state is mostly local per instance; source criteria determine local rate-limit keys. Sticky sessions use client cookies. Distributed rate limiting uses persistent KV storage such as Redis in the distributed middleware. | Per-instance rate limiters, health state, sticky cookies. | Redis-backed distributed rate limit middleware; dynamic providers for config. | Local by default; distributed rate limits require explicit shared store. | Praxis can start with local middleware-like state, but must document that production global limits need shared backing. Sticky cookies are useful for affinity but not sufficient for required protocol session state. |
| Caddy | Treats certificate automation as durable background state. Certificates, keys, ACME accounts, locks, and coordination live in configurable storage. Instances sharing storage coordinate certificate management. | Local memory plus persistent filesystem storage by default. | Configurable storage modules, including community Redis/storage plugins; shared storage coordinates cert management. | Durable storage is used for background automation, not per-request routing decisions. | Praxis should separate background durable state, such as certificates and config artifacts, from request-path state. Storage abstractions are valuable, but not all state belongs in Redis. |
| Linkerd proxy | Keeps the Rust data plane intentionally narrow. Proxies receive control data and identity from the control plane, maintain local connection/load/telemetry state, and avoid becoming a general policy database. | Local sidecar state, service discovery cache, metrics, identity/cert material. | Linkerd control plane provides destination data, identity, profiles, and telemetry aggregation. | Data plane is local/ephemeral; control plane drives configuration and identity. | A useful caution: Praxis should only become stateful where proxy-path semantics require it. Durable business/config state should stay in a control plane. |
| Istio ztunnel | Purpose-built Rust L4 proxy with small feature scope: mTLS, authn/authz, L4 telemetry, HBONE transport. It uses xDS/CA clients and keeps L7 state in waypoint proxies. | Local connection identity, tunnel state, cert material, telemetry counters. | Istiod xDS and CA services. | Data plane local state is driven by control-plane config and identity services. | Strong reminder that stateful proxy design should be scoped. Do not overload Praxis core with unrelated L7 business state if a control-plane or waypoint component owns it better. |

### Cross-Proxy Lessons For Praxis

| Pattern | Seen in | What it means for #99 |
| --- | --- | --- |
| Explicit local-vs-shared strategy | Kong, APISIX, Envoy Gateway, Traefik | Every feature that enforces limits or sessions should declare whether it is local-only, shared, or externally delegated. |
| Typed bounded state tables | HAProxy stick tables, NGINX shared zones | State needs key type, max entries/size, TTL/expiry, stored fields, eviction behavior, and metrics. |
| Per-request metadata is not a ledger | Envoy dynamic metadata, Praxis `filter_metadata` | Body-derived facts should feed filters, logging, routing, and quota checks; they should not be used as durable state. |
| Global rate limits need external coordination | Envoy RLS, Kong Redis, APISIX Redis, Traefik distributed rate limit | Praxis token/request budgets need Redis/Valkey or an external service for multi-replica correctness. |
| Client-carried affinity is useful but risky | Envoy stateful sessions, Traefik sticky cookies, Caddy on-demand TLS ask flow | Cookie/header/session-token state must be signed/encrypted when it affects routing/security, and should include TTL/config generation. |
| Shared state replication is usually eventually consistent | HAProxy peers, NGINX Plus zone sync | Peer replication can work for abuse counters/affinity but is harder to reason about than Redis/Valkey for first implementation. |
| Config state and runtime enforcement state should stay separate | Envoy xDS, APISIX etcd, Linkerd/Istio control planes | xDS/etcd/Kubernetes/config controllers are good for desired state; Redis/Valkey/service calls are better for hot-path counters/sessions. |
| Background state deserves different APIs | Caddy certificate storage, Pingora background services | Certificate renewal, probes, health polling, and exports should not use the same API as synchronous request admission state. |
| Extension systems need constrained state access | OpenResty shared dict, Wasm/Go/dynamic filters | Give extensions capability-scoped state APIs rather than raw global mutable maps. |
| State observability is part of the feature | Envoy stats, HAProxy table introspection, NGINX zones, Kong/APISIX plugin metrics | Praxis state APIs should emit operation latency, errors, key counts, evictions, rejects, stale reads, and backend health. |

### Source Links For Proxy State Research

| Source | Relevant state topic |
| --- | --- |
| https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/well_known_dynamic_metadata.html | Envoy dynamic metadata as per-request filter-produced state. |
| https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/well_known_filter_state.html | Envoy filter state object keys. |
| https://www.envoyproxy.io/docs/envoy/latest/configuration/other_features/rate_limit.html | Envoy global rate-limit service model. |
| https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/other_features/global_rate_limiting.html | Envoy local/global rate-limit split and Redis-backed reference RLS. |
| https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/stateful_session_filter | Envoy strong stateful session filter behavior and warnings. |
| https://www.haproxy.com/documentation/haproxy-configuration-tutorials/proxying-essentials/custom-rules/stick-tables/ | HAProxy stick tables, counters, expiry, peer sync. |
| https://docs.nginx.com/nginx/admin-guide/security-controls/controlling-access-proxied-http/ | NGINX shared memory zones for request/connection limiting. |
| https://docs.nginx.com/nginx/admin-guide/high-availability/zone_sync/ | NGINX Plus runtime state sharing across cluster nodes. |
| https://blog.openresty.com/en/how-nginx-shm-consume-ram/ | OpenResty/NGINX shared memory and `lua_shared_dict` state usage. |
| https://developer.konghq.com/plugins/rate-limiting/ | Kong rate limiting strategies: local, cluster, Redis. |
| https://docs.konghq.com/gateway/latest/reference/rate-limiting/ | Kong rate-limiting library consistency and latency tradeoffs. |
| https://apisix.apache.org/docs/apisix/3.13/installation-guide/ | APISIX etcd configuration center. |
| https://apisix.apache.org/docs/apisix/3.12/deployment-modes/ | APISIX standalone mode without etcd. |
| https://apisix.apache.org/docs/apisix/3.10/plugins/limit-count/ | APISIX limit-count plugin local/Redis/Redis Cluster policies. |
| https://doc.traefik.io/traefik/v3.1/middlewares/http/ratelimit/ | Traefik local rate-limit source criteria. |
| https://doc.traefik.io/traefik/reference/routing-configuration/http/load-balancing/service/ | Traefik sticky session cookies and health state. |
| https://doc.traefik.io/traefik/master/reference/routing-configuration/http/middlewares/distributed-ratelimit/ | Traefik distributed rate-limit middleware with persistent KV/Redis. |
| https://caddyserver.com/docs/automatic-https | Caddy certificate automation storage and shared storage coordination. |
| https://linkerd.io/2.10/reference/architecture/ | Linkerd control plane/data plane split and Rust proxy state scope. |
| https://istio.io/latest/blog/2023/rust-based-ztunnel/ | Istio ztunnel purpose-built Rust proxy, xDS/CA client, scoped L4 state. |

## Initial Local Project Inspection Notes

### Kuadrant MCP Gateway

| Area | Observation | Praxis implication |
| --- | --- | --- |
| Session interface | `SessionCache` exposes `GetSession`, `AddSession`, `DeleteSessions`, `RemoveServerSession`, `KeyExists`, `SetClientElicitation`, and `GetClientElicitation`. | Praxis should model typed stores around domain operations, not expose raw Redis everywhere. |
| In-memory store | Uses `sync.Map` with `map[string]string` session maps for local default. | A local store is useful for tests/dev, but must be documented as not multi-replica correct. |
| Redis store | Uses Redis `HGETALL`, `HSET`, `HDEL`, `DEL` for session maps and string keys for client elicitation flags. | Redis hashes are a practical fit for gateway-session to backend-session maps. |
| Elicitation ID map | Has separate `idmap.Map` with in-memory and Redis implementations; Redis entries use a TTL safety net. | Short-lived correlation state should have TTLs even when cleanup is expected. |
| Backend 404 | Response header handling removes the backend session mapping on 404. | Praxis should include explicit invalidation behavior for backend session misses/stale sessions. |
| Backend lazy init | If backend session is missing, gateway initializes backend MCP session and stores returned backend session ID. | Praxis MCP gateway needs sub-request/lazy-init or an equivalent backend client abstraction. |
| Client session ID | Uses JWT session manager with expiration and delete-on-terminate. | Praxis must decide opaque random IDs + Redis vs signed/encrypted self-describing IDs. |

### Envoy AI Gateway MCP Proxy

| Area | Observation | Praxis implication |
| --- | --- | --- |
| Composite session ID | Creates a client-facing gateway session from per-backend session entries, then encrypts it. | Encoding backend session mapping into a secure token can reduce store dependency, but complicates rotation/revocation and token size. |
| Backend initialization | Initializes sessions to all configured backends in parallel and skips failed backends if at least one succeeds. | Praxis should decide eager multi-backend init vs lazy per-tool backend init. Kuadrant uses lazy init; Envoy AI Gateway uses a more composite gateway model. |
| Session parsing | Decrypts client session ID on later requests to reconstruct backend sessions. | This is a credible stateless option for MCP if Praxis can accept encrypted session tokens. |
| Progress token routing | Encodes backend information into progress tokens so later progress notifications route to the correct backend. | For some correlation state, encoded tokens may replace external store. Need security review because comments note signing/encryption may be needed. |
| Token/rate metadata | AI token costs are captured in per-request metadata, then rate-limit policy consumes those values. | Praxis should keep token facts in metadata and quota state in the shared ledger. |
| Redis rate limit | Installation docs include Redis for rate limiting when enabled. | Rate-limit state belongs in shared external store for production. |

### Pingora

| Area | Observation | Praxis implication |
| --- | --- | --- |
| Local caches | `pingora-cache`, `pingora-lru`, and sharded maps provide local state/cache primitives. | Use as implementation inspiration for local bounded maps, not as the distributed state story. |
| Background services | Pingora has background service patterns in load balancing and runtime crates. | Useful for cleanup, refresh, health polling, and async flush workers. |
| Request lifecycle | Praxis wraps Pingora hooks with `PingoraRequestCtx` and `HttpFilterContext`. | Response-body hooks are synchronous, so external state writes from response-body parsing need queuing and async flushing later. |

## State Architecture Questions For Research

The proposal should answer these explicitly. The table below records the research framing.

| Question | Why it matters | Candidate answers |
| --- | --- | --- |
| Should Praxis expose one generic state API or several typed stores? | Generic KV is flexible but unsafe/sloppy; typed stores are clearer but more code. | Recommend generic backend traits plus typed domain wrappers (`McpSessionStore`, `A2aTaskStore`, `RateLimitStore`). |
| What is the first external store? | We need a practical implementation path. | Redis/Valkey first, feature-gated. SQL/event sinks later for durable business records. |
| What state can be encoded into signed/encrypted client tokens? | Reduces external dependencies for sessions. | Consider for MCP gateway session and SSE event IDs; avoid for large or revocable state. |
| What state requires atomic operations? | Counters and checkpoints can break under races. | Rate limits, token ledgers, idempotency/checkpoints. Use Redis scripts/transactions or atomic primitives. |
| How do sync response-body hooks update external stores? | Pingora response-body filter is synchronous. | Parse and queue state updates in request context; flush from async logging hook or background worker. |
| What is the failure policy for each store? | A Redis outage can become auth bypass or total outage. | Fail closed for auth/quota/session correctness; fail open only for explicitly non-critical observability/cache. |
| How are TTLs assigned and refreshed? | Memory/key leaks and stale routing are likely without TTLs. | Every hot-path key class needs explicit TTL and cleanup story. |
| How do we prevent state cardinality explosions? | AI traffic can create many users/tasks/sessions/tools. | Bound key dimensions, cap lengths, hash unsafe IDs, metrics on key count/evictions. |
| How does config versioning interact with state? | A task/session may refer to a backend removed by reload. | Store route/config generation with mappings; define invalidation/migration behavior. |
| How do we test multi-replica correctness locally? | Single-process tests miss the main reason for external state. | Two Praxis instances sharing Redis, restart simulation, sticky-vs-nonsticky tests. |

## Candidate Architecture Hypothesis

This is a working hypothesis for the proposal, not the final decision.

```text
Filters
  -> typed state APIs
       McpSessionStore
       A2aTaskStore
       RateLimitStore
       TokenUsageStore
       CorrelationIdMap
       PolicyDecisionCache
  -> shared backend abstraction
       LocalStateBackend
       RedisStateBackend
       Future: SQL/Event/Vector-specific integrations
  -> protocol adapter
       per-request metadata
       queued async state updates
       logging/background flush
```

### Proposed Trait Split

| Layer | Responsibility | Example methods |
| --- | --- | --- |
| `StateBackend` | Low-level local/Redis primitives with timeouts and TTLs. | `get`, `set`, `delete`, `hgetall`, `hset`, `hdel`, `incr_by`, `compare_and_set` |
| `McpSessionStore` | MCP-specific session semantics. | `get_backend_sessions`, `put_backend_session`, `remove_backend_session`, `delete_gateway_session`, `set_client_capability` |
| `A2aTaskStore` | A2A task/context ownership semantics. | `put_task_owner`, `get_task_owner`, `put_context_owner`, `delete_task`, `mark_terminal` |
| `RateLimitStore` | Request/token admission counters. | `check_and_consume`, `refund`, `remaining`, `reset_at` |
| `UsageEventSink` | Asynchronous usage/billing export. | `emit_usage`, `flush`, `retry_pending` |
| `CorrelationMap` | Short-lived request ID / elicitation / progress maps. | `store_mapping`, `lookup_mapping`, `remove_mapping` |

Typed stores should own key schemas and validation. Filters should not construct raw Redis keys directly.

## Key Schema Research Starting Point

The final proposal should include exact key schemas. Initial candidates:

| State | Redis/Valkey key | Type | TTL |
| --- | --- | --- | --- |
| MCP gateway session metadata | `praxis:{instance_scope}:mcp:session:{gateway_session}` | hash | gateway session TTL |
| MCP backend session map | `praxis:{instance_scope}:mcp:session:{gateway_session}:backends` | hash field `server_name -> backend_session_id` | gateway session TTL |
| MCP client capability | `praxis:{instance_scope}:mcp:session:{gateway_session}:capabilities` | hash | gateway session TTL |
| MCP elicitation map | `praxis:{instance_scope}:mcp:elicitation:{gateway_id}` | string JSON | short TTL, e.g. 1h |
| A2A task owner | `praxis:{instance_scope}:a2a:task:{task_id_hash}` | string JSON/hash | task TTL or terminal cleanup TTL |
| A2A context owner | `praxis:{instance_scope}:a2a:context:{context_id_hash}` | hash/list | context TTL |
| Request descriptor bucket | `praxis:{instance_scope}:rl:req:{descriptor_hash}:{window}` | counter/string | window TTL |
| Token bucket | `praxis:{instance_scope}:rl:tok:{descriptor_hash}:{window}` | counter/string or script-managed bucket | window TTL |
| Orchestration checkpoint | `praxis:{instance_scope}:orch:{request_id}` | hash | workflow TTL |
| Policy decision cache | `praxis:{instance_scope}:policy:{policy_version}:{subject_hash}:{route_hash}` | string JSON | short TTL |

Rules to validate:

- Never put raw prompt text, tool arguments, secrets, API keys, or arbitrary user payloads in keys.
- Hash unbounded external IDs before using them as keys.
- Include tenant/workspace scope only when needed and with length/cardinality controls.
- Include config generation or route version when stale mappings could become dangerous.

## Lifecycle Flows To Research

### MCP Session Flow

| Step | State action | Store requirement |
| --- | --- | --- |
| Client initializes gateway session | create or capture gateway session metadata | create with TTL |
| Client calls `tools/list` | maybe read catalog, maybe read session capabilities | low-latency lookup |
| Client calls `tools/call` | lookup `(gateway_session, server)` backend session | hash lookup |
| Missing backend session | initialize backend via sub-request/client, store returned backend session ID | write with TTL |
| Backend returns 404 | remove backend session mapping | hash delete |
| Client sends `DELETE` | delete gateway session and backend maps | multi-key delete |
| Session expires | cleanup all associated state | TTL and/or explicit cleanup |

### A2A Task Ownership Flow

| Step | State action | Store requirement |
| --- | --- | --- |
| `SendMessage` routes to backend | remember selected backend in request metadata | per-request metadata |
| Backend returns task in JSON response | parse task/context ID | response parser |
| Backend streams task in SSE | parse completed SSE data lines; queue update | sync body hook queue |
| Logging hook runs | flush queued task mappings to store | async write |
| `GetTask`/`CancelTask` arrives | lookup task owner | low-latency lookup |
| Terminal task observed | mark terminal or delete after short TTL | update/delete |

### Token Quota Flow

| Step | State action | Store requirement |
| --- | --- | --- |
| Request arrives | check current quota/budget for descriptor | atomic read/check |
| Request proceeds | optionally reserve estimated tokens | atomic consume/reserve |
| Response returns usage | parse actual tokens | response parser |
| Usage known | reconcile budget and emit usage | atomic consume/refund + event |
| Over budget | reject future request with 429 | bounded-latency decision |

### Orchestration Checkpoint Flow

| Step | State action | Store requirement |
| --- | --- | --- |
| Request enters orchestration filter | create workflow ID and attempt counter | idempotent create |
| Sub-request selects worker | write selected worker checkpoint | compare-and-set |
| Sub-request completes | write completion checkpoint | compare-and-set |
| Retry/restart | resume from last checkpoint | read state machine |
| Client disconnects | cancel/expire workflow | cleanup |

## Failure Mode Research Matrix

| Failure | Affected state | Safe behavior | Research question |
| --- | --- | --- | --- |
| Redis/Valkey unavailable | sessions/tasks/quotas | fail closed for correctness-critical state; allow config override only for dev/non-critical caches | Which filters must be security-critical and impossible to fail open? |
| Store timeout | hot-path decisions | bounded timeout, metric, explicit reject/fallback | What default timeout is acceptable for proxy latency? |
| Process restart | local-only sessions/tasks | local mode loses state; Redis mode survives | Which features may claim production support with local mode only? |
| Replica switch | local-only state | fails unless sticky affinity keeps same replica | Should local mode auto-require consistent-hash/session affinity config? |
| Stale config | state points to removed backend | reject/reinitialize or migrate by config generation | Store config generation in mappings? |
| Duplicate request/retry | token/event/checkpoint state | idempotency key and attempt tracking | Which request IDs are reliable across retries? |
| Response-body parser sees partial SSE | A2A/MCP streaming state | buffer complete lines only; flush remainder safely | Where to store per-request line buffer? |
| Async flush fails after response | task map or usage event | metric + bounded retry/background queue | Can a request be considered successful if state write fails? |
| Key cardinality explosion | all external state | hash/cap IDs, TTLs, eviction metrics | What hard caps should config expose? |
| Clock skew | TTL/window state | Redis server TTL/window preferred | Are local windows acceptable for dev only? |

## Research Work Plan

### Phase 0: Frame The Spike

| Task | Output |
| --- | --- |
| Confirm active issue scope and related issues. | Issue map section in proposal. |
| Define state categories and vocabulary. | State terminology table. |
| Confirm MCP/A2A, MaaS, and llm-d requirements. | Required state inventory. |
| Identify non-goals. | Proposal boundaries. |

### Phase 1: Similar Project Deep Dive

| Project | Research questions | Expected artifact |
| --- | --- | --- |
| Kuadrant MCP Gateway | How are sessions, Redis, JWT session IDs, backend session maps, elicitation maps, and invalidation handled? What TTLs exist? What races are possible? | Detailed comparison table and extractable patterns. |
| Envoy AI Gateway MCP proxy | How much state is encoded in encrypted client tokens? How are backend sessions, progress tokens, event IDs, and multi-backend aggregation handled? | Stateless-token vs external-store tradeoff analysis. |
| Envoy AI Gateway / Envoy Gateway rate limiting | How are token costs stored in request metadata and consumed by global rate limit? What role does Redis play? | Token/state ledger pattern for MaaS. |
| Pingora | Which local cache/background primitives are reusable? What lifecycle constraints affect async state writes? | Runtime constraints and local cache design notes. |
| Limitador / Kuadrant rate limiting | How are distributed counters represented? What headers/metrics matter for migration? | Counter algorithm and compatibility notes. |
| Gateway API Inference Extension / llm-d | What state does the endpoint picker/scheduler own? What orchestration state does #28 imply? | Routing scorer and checkpoint state requirements. |
| Agent Gateway / other MCP/A2A gateways | How are A2A tasks or protocol sessions handled? | A2A-specific state patterns if any. |

### Phase 2: Praxis Code Audit

| Area | Questions |
| --- | --- |
| Filter lifecycle | Which phases can be async? Where can state reads/writes occur without blocking sync hooks? |
| `PingoraRequestCtx` | What request-local queues are needed for deferred state writes? |
| Pipeline ordering | Which filters produce state, consume state, or require dependencies? |
| Config model | How should state backend config be declared and injected into filters? |
| Tests | How can integration tests run local store and Redis store variants? |
| Metrics/tracing | What state operation metrics must exist before production? |

### Phase 3: Storage Option Analysis

| Option | Prototype need | Decision criteria |
| --- | --- | --- |
| Local in-memory | Implement bounded map/TTL wrapper or use existing local patterns. | Speed, memory bounds, dev ergonomics. |
| Redis/Valkey | Implement minimal state backend with timeout, TTL, hash ops, counters. | Latency, atomicity, operational fit, testability. |
| Encrypted client token | Prototype MCP session map encoded in token. | Token size, revocation, rotation, security, compatibility. |
| Event sink | Sketch usage event export path. | Billing reliability, idempotency, backpressure. |
| SQL/control plane | Document what should not be in hot path. | Operational boundaries. |

### Phase 4: Proposal Synthesis

| Deliverable | Required contents |
| --- | --- |
| Proposal discussion for #99 | State inventory, storage decision matrix, recommended architecture, risks, staged implementation plan. |
| Follow-up issue list | One issue per implementation slice: state traits, local store, Redis store, MCP sessions, A2A task routing, quota ledger, usage event sink. |
| Prototype notes | Any microbenchmarks or proof-of-concept findings. |
| Acceptance criteria | Clear definition of production-ready state support. |

## Research Questions To Answer Before Implementation

| Priority | Question | Why it blocks implementation |
| --- | --- | --- |
| P0 | What state classes are production-critical versus best-effort? | Determines fail-open/fail-closed defaults. |
| P0 | Should MCP session state be Redis-backed opaque ID or encrypted self-contained token? | Determines first MCP session architecture. |
| P0 | How should response-body-derived state be flushed asynchronously? | A2A task routing and streaming MCP features depend on this. |
| P0 | What is the first external store and feature flag shape? | Needed for code structure and dependency review. |
| P0 | What key schema and TTL rules prevent leaks/cardinality issues? | Required before Redis implementation. |
| P1 | Which state operations need atomic compare-and-set or scripts? | Affects rate limiting and orchestration checkpoint correctness. |
| P1 | How should config generation/version be stored with state? | Avoids routing to removed backends after reload. |
| P1 | What metrics and traces are mandatory for state operations? | Required for debugging production behavior. |
| P1 | Can local store mode be safely exposed in production with affinity warnings? | Impacts docs and config validation. |
| P2 | Which state can be carried in client-visible signed/encrypted tokens? | Could reduce Redis dependence for MCP. |
| P2 | How should semantic cache state relate to future vector stores? | Avoids overloading Redis with the wrong data type. |

## Candidate Follow-Up Implementation Slices

These are not implementation instructions. They are candidate follow-up issues to evaluate after the proposal is reviewed.

| Order | Slice | Scope | Issue refs |
| --- | --- | --- | --- |
| 1 | `state-traits-local` | Add state traits, local in-memory backend, TTL cleanup, state operation metrics. | #99, #27 |
| 2 | `mcp-sessions-local` | MCP gateway/backend session mapping on local store with explicit single-replica limitation. | #25, #27, #99 |
| 3 | `state-redis` | Redis/Valkey backend with timeouts, TTLs, key prefix, feature flag, integration tests. | #27, #99 |
| 4 | `a2a-task-store-local` | Task/context owner store with local backend and response parsing queue. | #26, #27, #99 |
| 5 | `a2a-task-store-redis` | Shared task/context routing across two replicas. | #26, #27, #99 |
| 6 | `token-ledger-redis` | Atomic token bucket/quota ledger for MaaS. | #20, #21, #99 |
| 7 | `usage-event-sink` | Structured token usage event export with idempotency. | #20, #21, #99 |
| 8 | `orchestration-checkpoints` | Checkpoint store for sub-request workflows. | #28, #99 |

## Research Completion Criteria

The research phase is complete when we have:

- A final state inventory table covering MCP, A2A, MaaS, inference routing, caching, policy, and orchestration.
- A recommendation for local store behavior and warnings.
- A recommendation for the first external store implementation.
- A key schema and TTL policy draft.
- A failure-mode policy by state class.
- A sequence of follow-up implementation issues.
- A consensus-ready proposal discussion for #99.
- At least one multi-replica validation plan for Redis/Valkey.
- A clear statement of what remains out of scope.

## Research Non-Goals

- Do not implement the state layer yet.
- Do not choose a database for billing-grade long-term records without product requirements.
- Do not make Kubernetes API calls from the data-plane hot path.
- Do not treat local in-memory state as production multi-replica support.
- Do not solve semantic cache/vector storage fully in this spike.
- Do not make MCP/A2A full implementation depend on a single global raw key-value API with no typed domain layer.

## Immediate Research Next Steps

1. Expand the Kuadrant MCP Gateway table with exact code-path notes for session creation, Redis configuration, invalidation, and elicitation mapping.
2. Expand the Envoy AI Gateway table with exact code-path notes for encrypted composite sessions, progress token routing, and token quota metadata.
3. Audit Praxis response-body and logging hooks to define the async flush pattern for response-derived state.
4. Draft the first `AgentStateStore` trait surface in pseudo-code, without implementing it.
5. Decide whether MCP should start with opaque Redis-backed session IDs, encrypted self-contained IDs, or support both modes.
6. Create a final proposal version for #99 with a narrowed recommendation and follow-up issue list.
