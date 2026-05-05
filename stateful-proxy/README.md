# Spike: Stateful Proxy Analysis For Praxis

[Skip to Proposed Architecture](#proposed-architecture) if you want to bypass the research/background sections.

## Summary

Praxis needs a deliberate state architecture before more features start adding their own storage patterns. The current codebase has request-local metadata, local counters, local load-balancer state, local health state, and static or hot-reloaded configuration. That is enough for a basic proxy, but not enough for the feature set represented by the current open issue backlog.

The problem is not simply that Praxis needs Redis. The problem is that Praxis needs a clear model for **which state belongs where**:

- Some state is request-local and should never leave memory.
- Some state is local runtime state and can be safely lost on restart.
- Some state is **hot-path state**: Praxis reads or writes it while a client request is waiting, so latency, timeout, and failure behavior directly affect the request.
- Some hot-path state must be shared across replicas to enforce correctness.
- Some state is durable business or audit state and should stay out of the request hot path.
- Some state is configuration or control-plane state and should be versioned separately from request execution.

This spike proposes a layered model:

1. Keep per-request facts in `filter_metadata` and other request context fields.
2. Add typed state APIs for state that outlives one request.
3. Provide bounded local stores for development, tests, and single-replica deployments.
4. Provide Redis/Valkey-backed stores for cross-replica hot-path state.
5. Keep durable business/config state in control-plane systems, databases, object stores, or event streams.
6. Require explicit key schemas, TTLs, cardinality limits, failure modes, and observability for every state class.

The recommended first implementation path is **not** a generic global key-value map. Start with typed state traits around concrete needs: rate-limit counters, token ledgers, protocol sessions, task ownership, policy decision cache, routing scorer snapshots, and usage event export.

## Issue Scope

Issue #99 asks for an analysis of the state management Praxis needs, and for a proposal discussion that includes:

- A table of all state and related features Praxis needs to support.
- Local mechanisms for storing that state.
- External mechanisms for storing that state.
- Enough detail to build consensus before implementation.

This document is intended to be that proposal draft. It does not implement the state layer.

## Problem Statement

Praxis is being used as an AI-native proxy framework, not just a stateless reverse proxy. Many planned features need decisions based on information that is produced over time. The first table names the components and signals that produce that information. It explains what each component is used for, why it creates state pressure, and the correct first posture for storing or carrying that state.

| Component or signal | What the component is | What it is used for | Why it creates state pressure | State examples | Correct first posture |
| --- | --- | --- | --- | --- | --- |
| Request bodies | The bytes sent by the downstream client before Praxis forwards the request upstream. In AI and JSON-RPC traffic, this is often where the important routing fields live. | Body-aware routing, model extraction, token estimation, policy checks, JSON-RPC method routing. | Important routing and policy facts are inside the body, not just headers. Later filters need those facts after body parsing finishes, and some facts may influence retries, logging, response mutation, or usage export. | extracted model, prompt size, JSON-RPC method, tool name, tenant field, input token estimate. | Parse only what is needed, store derived facts in request-local metadata, and avoid copying full bodies into shared state. Promote to external state only when the feature explicitly needs a cross-request record. |
| Response bodies | The bytes returned by the upstream backend before Praxis sends the response to the client. Streaming responses may expose facts incrementally. | Output token counting, usage accounting, task ID capture, guardrail checks, response rewriting. | Some important facts only exist after upstream responds, but later logging, billing, or session/task state still needs them. Streaming responses also require partial state while chunks are observed. | output tokens, total tokens, A2A task ID, terminal task status, guardrail findings, response usage object. | Keep parsed response facts request-local first. For usage or task/session updates, write through a typed sink/store with bounded buffering and explicit failure behavior. |
| Model names and provider selections | The requested model, resolved model alias, selected backend/provider, and reason Praxis selected that path. | AI routing, provider failover, model aliasing, cost controls, response transparency. | The selected backend may differ from the requested model and must be preserved for logs, policy, retries, and usage export. Retry/failover paths must know what was already attempted. | requested model, routed model, provider, route reason, failover chain position, model alias version. | Carry the decision in request metadata and access logs. Store only routing tables and model aliases as configuration state; store provider health/scores in bounded local snapshots. |
| Token counts and cost | Input, output, and total token usage plus cost attribution derived from model/provider pricing and caller identity. | MaaS quota enforcement, cost budgets, billing/showback, rate-limit headers. | Token budgets are ledgers over time, not one-request facts. They must be consistent across replicas for production enforcement and durable enough for billing/export. | input/output/total counters, reserved tokens, committed tokens, budget consumed, reset window, cost attribution. | Use request metadata for per-request counts, shared hot-path state for quota enforcement, and asynchronous durable export for billing/showback. |
| User, tenant, or subscription identity | The authenticated caller identity and the business entity the request should be charged, limited, or authorized against. | Authz, per-tenant quotas, tenant routing, audit, observability dimensions. | Identity is derived from auth and then reused by rate limits, policy, logging, routing, token ledgers, and usage events. It must be trusted before it drives enforcement. | subject, tenant, workspace, subscription ID, claims snapshot, API key validation result. | Store trusted identity facts in request metadata. Cache validation inputs/results only with explicit TTL, policy versioning, and fail-closed behavior for required auth. |
| Rate-limit counters | Moving counters or token buckets that decide whether another request can be admitted. | Request admission, abuse prevention, connection limits, token budgets. | Counters must remember previous traffic and often must be shared across replicas. Local-only counters are useful but do not enforce a global limit. | descriptor bucket, remaining requests, reset time, deny reason, last-seen timestamp. | Provide local mode for development/single-replica protection and Redis/Valkey or external-service mode for production multi-replica enforcement. |
| Endpoint health, load, and routing scores | Runtime facts about backend availability, pressure, latency, queue depth, or scheduler preference. | Intelligent routing, failover, overload protection, llm-d/GIE scheduling. | Routing decisions depend on fresh changing backend facts, not only static config. Stale scores can cause bad routing or overload. | endpoint health, latency score, queue depth, pressure, KV-cache hint, scheduler score. | Keep local snapshots with freshness TTLs and stale fallback. Use external scheduler/control-plane inputs when needed, but request processing should read local validated snapshots where possible. |
| Cache keys and in-flight fills | Cache lookup keys, response references, semantic/vector references, and records of cache fills currently in progress. | Response caching, semantic caching, request coalescing, cache stampede protection. | Cache correctness requires shared or bounded local knowledge about stored entries and in-progress fills. Incorrect ownership can create stale responses or duplicate expensive upstream work. | cache key, response reference, vector key, fill lock, waiter list, stale marker. | Use a cache-specific API with TTL, purge, fill-lock, privacy, and eviction semantics. Do not reuse quota/session stores as a generic cache. |
| Task or session ownership | A mapping between a client-visible session/task/context and the backend instance that owns the continuation. | MCP sessions, A2A task follow-up routing, sticky sessions. | Later requests may arrive on another proxy replica but must route to the backend that owns the session/task. Consistent hashing helps affinity but does not remember ownership. | gateway session, backend session map, task owner, context owner, terminal cleanup marker. | Add typed protocol/session stores. Local mode is acceptable for development or explicit affinity-only deployments; shared mode is required for correctness across replicas. |
| Retry, hedge, and failover attempts | Per-request record of the upstream attempts Praxis has made and the budget remaining for additional attempts. | Resilience, provider failover, amplification control. | A retry path must remember what was attempted and why to avoid loops, retry storms, duplicate side effects, or confusing usage logs. | attempted endpoints, per-try timeout, hedge budget, failover reason, retry cancellation flag. | Keep attempt state request-local first. Add shared fleet-level budgets only if retry amplification needs cross-replica enforcement. |
| Policy and guardrail decisions | Results from authz, RBAC, WAF, PII detection, guardrail checks, or external policy providers. | Auth, RBAC, WAF/PII/guardrails, dry-run policy, audit. | Some decisions are expensive or externally computed and may need short-lived caching or audit export. Security decisions must not silently fail open. | allow/deny result, policy version, finding summary, provider decision, audit event reference. | Store decision facts request-local. Add bounded caches only with policy-version keys and fail-closed defaults where enforcement is required. Export audit events asynchronously. |
| Dynamic configuration versions | The active generation of routes, clusters, model aliases, policies, endpoints, and backend resources. | Hot reload, xDS/Gateway API integration, model and route updates. | State created under one config version can become stale after reload. Sessions, cached scores, and ownership maps may point at removed routes or backends. | config generation, route version, backend generation, invalidation marker, policy generation. | Treat config as a separate validated snapshot. Include generation/version fields in state keys or values where stale runtime state can affect correctness. |

The second table explains what goes wrong if each feature creates its own state model. These are not hypothetical style concerns; they become operational risks once Praxis runs multiple replicas, reloads configuration, or adds token/session enforcement.

| Failure mode | What causes it | Why it matters | State examples | Correct first posture |
| --- | --- | --- | --- | --- |
| Inconsistent timeout and failure semantics | Each filter implements backend calls differently. | Operators cannot predict whether a Redis/auth/scheduler outage fails open, fails closed, or stalls traffic. This makes the proxy difficult to reason about during incidents. | auth timeout, Redis timeout, scheduler timeout, guardrail provider timeout. | Define shared state errors, operation timeouts, retry rules, and per-feature failure-mode defaults. Security and quota enforcement should fail closed unless explicitly configured otherwise. |
| Unbounded maps and memory leaks | Local state tables grow on user/session/task/request-controlled keys. | A proxy can be exhausted by normal high-cardinality AI traffic or by abuse. AI workloads naturally produce many tenant, model, task, and session dimensions. | per-user buckets, task maps, session maps, in-flight cache fills, policy-decision cache entries. | Require max entries, TTLs, eviction policy, and cardinality metrics for every local store. Refuse or warn on configs that omit bounds for untrusted keys. |
| Inconsistent key formats | Filters hand-roll Redis keys and local map keys. | Collisions, oversized keys, PII leakage, and hard-to-debug stale state become likely when multiple filters build keys differently. | `tenant:model`, raw API key labels, session IDs embedded directly in metrics, mixed route/provider key order. | Provide typed key constructors with namespace, version, normalized dimensions, maximum length, and explicit handling for sensitive values. |
| Duplicate Redis clients or incompatible backends | Each filter adds its own backend config and client lifecycle. | Wasted connections, inconsistent TLS/auth/timeouts, duplicate health checks, and difficult operations follow quickly. | one Redis client per filter, inconsistent pool sizes, different TLS settings, different command timeouts. | Centralize Redis/Valkey-compatible backend config, connection lifecycle, health reporting, metrics, and timeout defaults. |
| Unclear local-only vs. multi-replica behavior | A local map works in tests but is deployed with multiple replicas. | Quotas, sessions, and task routing become incorrect in production because each replica has a different view of the world. | local quota bucket per pod, local MCP session map, local A2A task owner, local policy cache. | Make `local` versus `shared` mode explicit in config and docs. Validate or warn when correctness-critical features run in local mode. |
| Hidden fail-open security bugs | Security or quota state errors are treated like cache misses. | Auth, RBAC, paid quota enforcement, or guardrail enforcement can be bypassed during backend errors. | missing auth response, Redis unavailable for paid quota, policy cache error, guardrail timeout. | Fail closed by default for security/quota state. Allow fail-open only as an explicit config choice with metrics, logs, and documentation. |
| Hot-reload state loss | Pipeline reload recreates filter instances and their maps. | Local counters/sessions disappear even while the proxy keeps serving, which can reset enforcement or break follow-up protocol calls. | local descriptor buckets, in-memory session maps, local task owners, in-flight cache locks. | Correctness-critical state must live outside filter instance lifecycle. Local state must document reset behavior and expose reload/reset metrics where practical. |
| High-cardinality metrics and logs | Raw user/session/task/request IDs become labels or unbounded dimensions. | Observability systems become unstable or expensive, and sensitive identifiers may leak. | raw subject labels, raw session ID labels, task ID labels, prompt hash labels, API key fragments. | Use bounded label sets and structured logs. Keep raw identifiers out of metric labels; hash or sample only where explicitly required and safe. |
| No multi-replica test strategy | Only unit tests exercise local state. | Shared state correctness breaks after deployment because race conditions and replica divergence are not tested. | two replicas consuming one quota, session follow-up hitting a different replica, task owner update from response body. | Add validation with two Praxis instances plus Redis/Valkey for shared stores, including timeout, reload, restart, and stale-key behavior. |

The state architecture must be explicit before these patterns harden.

## Non-Goals

This spike does not propose making Praxis a database.

This spike does not require every stateful feature to use Redis.

This spike does not propose synchronous Kubernetes API, SQL, object-store, or vector-database calls directly from every request path.

This spike does not replace existing control-plane systems such as Kubernetes, xDS, Gateway API controllers, MaaS APIs, or external auth systems.

This spike does not implement MCP, A2A, token accounting, semantic cache, or routing scorers. It defines the state architecture those features should use.

## Terminology

This section defines terms used throughout the spike. The goal is to avoid overloading the word "state". A request-local fact, a Redis quota counter, an ACME certificate, and a Kubernetes route object are all state, but they need different storage, latency, failure, and operational rules.

Useful definitions before reading the tables:

- **Hot path**: code that runs while a client request is waiting for Praxis to make a forwarding, rejection, mutation, or routing decision. Hot-path work directly adds request latency.
- **Shared hot-path state**: state read or written on the request hot path that must be consistent across multiple Praxis replicas. Examples include production quota counters, token ledgers, session ownership, and task ownership.
- **Request-local metadata**: facts derived during a single request and carried across filters and Pingora phases. This is not durable storage.
- **Local runtime state**: in-memory process state that can be useful and fast, but is lost on restart and not automatically correct across replicas.
- **Durable business state**: records that should survive failures for business, audit, billing, or administrative reasons. This generally belongs outside the synchronous request path.
- **Configuration state**: desired state from config files, xDS, Gateway API, Kubernetes, or a control plane. It should be cached locally before use in the request path.
- **Externalized decision state**: state owned by another service, such as an auth service, scheduler, external processor, or guardrail provider. Praxis should make the timeout and failure behavior explicit when delegating to these services.

| State class | Lifetime | State examples | Correct first posture |
| --- | --- | --- | --- |
| Request-local metadata | One request. It starts when Praxis accepts the request and ends after response/logging finalization. | Extracted model name, JSON-RPC method, auth subject, tenant ID, selected route, token estimate, routing reason, guardrail finding summary. | Keep this in `HttpFilterContext` / `PingoraRequestCtx`. Do not write externally just because a fact exists. Use it to feed later filters, logs, metrics, and response headers. |
| Connection-local state | One downstream connection, stream, or tunnel. It may span multiple HTTP requests depending on protocol. | client address, TLS version, client certificate fields, PROXY protocol source IP, HTTP/3 migration details, CONNECT tunnel state. | Keep in Pingora/Praxis connection or request context. Use it as input to filters, but do not treat it as a cross-request ledger unless explicitly promoted. |
| Local runtime state | Process lifetime or until config reload. It is fast but disposable. | local rate buckets, local circuit breakers, local health status, local cache entries, local DNS cache, local overload level, local probe readings. | Store in bounded in-memory structures with TTLs, max sizes, eviction metrics, and clear reload/restart behavior. Document that it is not multi-replica correct. |
| Shared hot-path state | Cross-replica and latency-sensitive. It is accessed while a request is waiting. | production quota counters, token ledgers, protocol session maps, task ownership maps, global connection counters, short-lived policy decision cache. | Use Redis/Valkey or an external service with strict timeouts, typed keys, TTLs, bounded cardinality, and explicit fail-open/fail-closed behavior. |
| Durable business state | Long-lived and audit-sensitive. It may outlive proxy pods and deployments. | billing events, usage history, tenant subscriptions, audit logs, compliance records, admin-visible business objects. | Keep out of synchronous filter logic. Export asynchronously to a database, event stream, object store, or control plane with idempotency and retry rules. |
| Configuration state | Until reload or control-plane update. It describes desired behavior, not live counters. | routes, clusters, policies, model aliases, provider mappings, certificates, xDS resources, Gateway API resources. | Cache locally as a validated snapshot. Track config generation where stale runtime state could point at removed routes or backends. |
| Background/runtime service state | Process or deployment lifetime, usually maintained outside direct request handling. | ACME renewal progress, DNS refresh timers, probe snapshots, certificate rotation state, health polling state, exporter queues. | Manage through background services with bounded queues, readiness/health signals, metrics, and clear interaction with the hot path. |
| Externalized decision state | Owned by another service and observed by Praxis as a decision or mutation result. | ext_authz result, ext_proc mutation, MaaS API key validation, scheduler-selected backend, external guardrail provider response. | Treat the external service as the state owner. Praxis should store only request-local results unless a typed cache/store is explicitly configured. |

## Current Praxis Baseline

This table is the current code-grounded baseline: what Praxis already has, what kind of state it represents, and how that should be treated before adding new shared state mechanisms. It separates useful existing mechanisms from the missing foundation work.

| Existing mechanism | Current behavior | State examples | Limitation | Correct first posture |
| --- | --- | --- | --- | --- |
| `filter_metadata` | Request-scoped `HashMap<String, String>` that survives Praxis/Pingora request and response phases. | extracted model, auth subject, JSON-RPC method, route reason, token estimate, selected provider. | Not cross-request. Not typed. Not a ledger. Values are strings and disappear after the request. | Continue using it for per-request facts that later filters/logging need. Do not use it for quotas, sessions, billing, or task ownership. |
| `filter_results` | Temporary branch-evaluation state used while the pipeline evaluates conditional filters. | filter pass/fail result, branch predicate output, temporary match result. | Cleared as pipeline evaluates; not durable and not intended for later phases. | Keep it scoped to branch decisions. Use `filter_metadata` or typed stores when facts must survive. |
| Local rate-limit buckets | In-process token buckets for request admission. | descriptor key, remaining requests, reset time, local deny reason. | Not shared across replicas; reset on restart/reload; not a production global quota ledger. | Keep as local/dev/single-replica protection. Add a typed shared `RateLimitStore` for multi-replica enforcement. |
| Load-balancer state | Local counters and selection state used by built-in load-balancing policies. | round-robin index, least-connection count, consistent-hash selection input. | Helps choose endpoints but does not remember protocol ownership or survive topology changes. | Keep as routing runtime state. Add separate session/task ownership stores where strict follow-up routing is required. |
| Circuit breaker state | Local cluster state machine where circuit breaking is present. | open/half-open/closed state, failure count, recovery timestamp. | Local only; reset on reload/restart; each replica has an independent view. | Use for local protection. Do not treat it as shared fleet health without a separate aggregation/control-plane mechanism. |
| Health state | Local cluster health snapshots from probes or runtime observations. | endpoint healthy/unhealthy, last probe time, probe failure count. | Local view only unless fed by external health/control-plane state. | Keep local snapshots bounded and fresh. Use as routing input with stale fallback. |
| Static/hot-reloaded config | Atomic local config snapshot used by request processing. | route table, cluster table, filter config, policy config, active generation. | Stateful filters reset unless state is externalized; old state can become stale after reload. | Track config generation for state that references routes/backends. Externalize correctness-critical runtime state. |
| External state backend | None as a general Praxis facility. | no shared Redis/Valkey client, no `StateBackend`, no typed session/quota store. | Every feature would otherwise invent its own backend, key format, timeout, and failure behavior. | Add typed state traits and shared backend plumbing before building multiple independent stateful filters. |


## Code Audit Findings To Carry Into Implementation

The research should be grounded in the current Praxis code shape. These details matter because they constrain the first implementation slices.

| Finding | Current detail | Implementation impact |
| --- | --- | --- |
| `filter_metadata` is string-only | The durable request metadata bag is `HashMap<String, String>`. | Good for protocol facts and descriptors, but not enough for typed values, counters, or durable ledgers. Typed stores should not depend on serializing all values through this map. |
| `filter_metadata` is request scoped | It survives request, request-body, response, response-body, and logging phases, then disappears. | Correct place for body-derived facts such as model, method, tenant, token counts, and routing reason. Incorrect place for sessions, quotas, or billing records. |
| Hot reload resets local filter state | Rebuilding pipelines recreates stateful filter instances and their in-memory maps/counters. | Local state must be documented as resettable. Correctness-critical state must live outside the filter instance lifecycle. |
| Circuit breaker state is local | Circuit breaker state is a local state machine per cluster where present. | Good local protection pattern, but not a shared fleet state model. |
| No Redis/Valkey backend exists today | There is no general Redis/Valkey client, `StateBackend`, or shared state trait. | The first state PRs need foundation work, not just filter integration. |
| Filters own their state directly | Existing stateful filters keep their own data structures. | Add typed stores to prevent each filter from inventing different map, TTL, eviction, and error semantics. |
| Rate limiter has bounded local behavior | The descriptor/local rate limiter prototype uses local token buckets, a 100K entry cap, and scan-based eviction. | Preserve this bounded local posture; make the limit configurable and observable before production use. |
| Consistent hash is not a session store | Consistent hash gives deterministic selection but does not remember ownership; topology changes can remap keys. | Useful affinity helper, but not sufficient for protocol sessions, task ownership, or strict sticky sessions. |
| Pingora cache/LRU exists outside Praxis | Pingora provides cache/LRU primitives, but Praxis does not yet expose them as a state architecture. | Use as implementation reference, not as the state backend answer. |

## Redis / Valkey Backend Research

Redis/Valkey is the recommended first shared hot-path backend because it fits short-lived counters, TTL-backed session maps, task ownership, policy decision caches, and correlation maps. It is not the recommended storage for long-term billing records, large cached response bodies, object storage, or vector search.

| Topic | Recommendation | Rationale |
| --- | --- | --- |
| First Rust client to evaluate | `redis-rs` (the `redis` crate) | Mature ecosystem choice with async Tokio support, Redis-compatible command coverage, and enough usage history to be a reasonable first candidate for Praxis. Validate pooling, TLS, reconnect, and cluster ergonomics before committing. |
| Alternate Rust client | `rustis` for RESP3-oriented deployments | Focused on RESP3 protocol and async usage. Worth evaluating for performance and ergonomics, but it should not be selected until deployment requirements and compatibility constraints are clearer. |
| Config naming | `redis` or `redis_compatible` | Valkey compatibility matters; avoid tying docs to one server brand where possible. |
| First deployment mode | Single endpoint Redis-compatible backend | Keep first PR reviewable. Add cluster/sentinel later if needed. |
| Required operation timeout | Default around 20ms, configurable | State calls are on the hot path. A hung backend must not hang request processing. |
| Expected local-network latency target | Design for sub-millisecond median and low single-digit millisecond P99 in-cluster | The state layer should be budgeted as a hot-path dependency, not a slow control-plane call. |
| Atomic counter strategy | Use atomic Redis operations or scripts where multi-step correctness matters | Token reserve/commit/refund and sliding windows must not race under concurrency. |
| Caching pattern | Consider local read-through caches only for soft state | Similar to Limitador-style cached Redis patterns: useful for reducing backend load, not for correctness-critical decrements unless carefully designed. |
| Key TTLs | Required for all hot-path session/counter/correlation keys | Prevents stale mappings and unbounded memory growth. |
| Metrics | Required from first backend PR | Track operation latency, errors, timeouts, connection status, key evictions, and fail-open/fail-closed decisions. |

Comparable Redis usage patterns:

| Project / pattern | Redis usage | Praxis takeaway |
| --- | --- | --- |
| Kuadrant MCP Gateway | Uses Redis hashes for gateway-session to backend-session maps and Redis strings with TTL for short-lived correlation IDs. | Good fit for `ProtocolSessionStore` and `CorrelationMap`: hashes for session maps, strings with TTL for ID translation. |
| Envoy global rate limiting | Envoy delegates global rate-limit checks to an external Rate Limit Service, commonly backed by Redis. | Praxis can implement native stores, but should preserve the same separation: proxy request facts are local, global counters live in shared state/service. |
| Envoy AI Gateway | Does not directly make Redis the proxy's internal store; token/rate policies flow through Envoy Gateway/global rate-limit mechanisms. | Do not assume AI metadata and quota ledger are the same layer. Metadata is request-local; quota state is external/shared. |
| Kong / APISIX / Traefik | Expose local and Redis-backed rate-limit modes with documented consistency tradeoffs. | Praxis should be explicit in config and docs: `local` is not the same as `redis` correctness. |

## Initial Performance And Capacity Targets

These are starting targets for implementation review, not final SLOs.

| Target | Starting value | Reason |
| --- | --- | --- |
| State lookup P99 budget | `< 5ms` for hot-path shared state calls | Keeps stateful features from dominating proxy latency. |
| Local operation budget | effectively sub-millisecond | Local maps/caches should not be a visible bottleneck. |
| Redis operation timeout | default `20ms`, configurable | Bounds tail latency during backend issues. |
| Local session memory estimate | `10K sessions * 1KB ~= 10MB` before map overhead | Useful baseline for local dev/single-replica mode. |
| Correlation ID TTL | around `1h` safety TTL | Matches short-lived ID-map patterns without leaking forever. |
| Protocol session TTL | route/protocol configurable, minutes to hours | Session semantics vary; must be explicit. |
| Local map default max entries | start around `100K`, configurable | Keeps accidental high-cardinality state bounded. |
| Metrics cardinality | no raw user/session/task/request IDs as labels | Prevents observability backend failure. |

## State Drivers By Feature Area

This table connects major Praxis feature areas to the specific kind of state they create. It is intended to make the state requirement concrete: what needs to be remembered, why it needs to be remembered, and where the first implementation should place it.

| Area | Why state is needed | State examples | Correct first posture |
| --- | --- | --- | --- |
| Request rate limiting | Admission decisions depend on previous requests from the same identity, IP, route, model, or descriptor. A single request cannot decide whether the caller has exceeded a time window. | Descriptor bucket key, request count, remaining budget, reset timestamp, last-seen timestamp, deny reason. | Keep local mode for tests, demos, and single-replica protection. Add Redis/Valkey-backed enforcement for production multi-replica quotas. |
| Token rate limiting | Token budgets are usage ledgers over time. They depend on input estimates before forwarding and final output usage after the response. | Input token estimate, output token count, total token count, tenant/model/provider window, reserved tokens, committed tokens, reset timestamp. | Use shared Redis/Valkey for hot-path budget checks. Export final usage to a durable sink for billing/showback; do not rely on request metadata as the ledger. |
| MaaS / cost controls | MaaS must enforce subscriptions and cost budgets by identity, workspace, model, provider, and time window. Those decisions must be consistent across gateway replicas. | Subscription descriptor, tenant/workspace, model, provider, request cost, monthly/daily budget consumed, billing event ID. | Use shared hot-path counters for enforcement and async durable usage events for accounting. Keep product/business ownership in MaaS/control-plane systems. |
| Intelligent routing | Routing decisions depend on backend conditions and business policy that change independently from the incoming request. | Endpoint latency, pressure score, queue depth, cost class, capability score, KV-cache hint, selected route, route reason. | Start with local scorer snapshots fed by probes, metrics, or control-plane data. Expire stale data quickly and fall back to deterministic safe routing. |
| llm-d / GIE | Inference scheduling depends on model-to-pool mappings, endpoint readiness, and scheduler decisions that come from outside the request itself. | InferencePool, InferenceModel, endpoint readiness, selected endpoint, scheduler score, P/D orchestration decision, KV-cache placement hint. | Consume scheduler/control-plane state through local snapshots or APIs. Preserve per-request decision metadata for logs, retries, and response transparency. |
| Response / semantic caching | Cache behavior needs knowledge of existing entries and in-flight fills. Semantic cache adds vector or embedding-derived lookup state. | Cache key, body hash, Vary dimensions, cached response reference, in-flight fill lock, vector ID, TTL, stale marker, purge marker. | Use a cache-specific API with eviction, purge, fill-lock, and stale semantics. Do not force cache state into the same API as counters or sessions. |
| MCP protocol | A client-facing MCP session can fan out to multiple backend MCP sessions. Follow-up requests must reuse the correct backend session and preserve protocol semantics. | Gateway session ID, backend session map, backend server ID, client capability flags, tool catalog, elicitation correlation ID, session expiry. | Add a typed protocol session store. Support local dev/single-replica mode first, but require Redis/Valkey or equivalent for multi-replica correctness. |
| A2A protocol | A backend that creates a task or context owns later follow-up operations. Those follow-ups may arrive through a different Praxis replica. | Task ID, context ID, owner backend/cluster, route generation, terminal state, cleanup TTL, streaming update-derived state. | Add a typed task ownership store. Queue response-body-derived writes and flush asynchronously where needed. |
| Security / auth / RBAC | Auth and policy decisions derive identity, validate keys, and may depend on external services or policy versions. Later filters need the resulting identity and decision facts. | JWT claims, API key validation result, JWKS keyset, subject, tenant, principal, policy version, allow/deny reason. | Store identity facts in request metadata. Use bounded local/shared caches only for short-lived validation or policy decisions. Fail closed by default. |
| Guardrails / WAF / PII | Inspection may produce findings that affect routing, rejection, masking, audit, or metrics. Some providers are external and stateful. | Matched rule ID, PII type, mask action, guardrail provider response, scan decision, policy version, audit event reference. | Keep findings request-local by default. Add explicit audit/event sinks only when retention is required, with privacy controls. |
| Retry / hedging / failover | Safe retry and hedge behavior must remember attempts and enforce amplification limits. Provider failover also needs to preserve why a route changed. | Attempt count, tried endpoints, retry budget, hedge budget, per-try timeout, failover trigger, fallback provider, cancellation state. | Keep attempt state request-local first. Add optional shared fleet budgets later if retry amplification needs global control. |
| Overload protection | Praxis must react to local resource pressure while continuing to serve or shed load predictably. | CPU pressure, memory pressure, active connection count, overload level, selected overload action, keep-alive disable flag. | Start with local runtime monitors and state machine. Export metrics and consider cluster aggregation only after local behavior is correct. |
| Observability | Metrics, traces, and logs are stateful because they aggregate, buffer, sample, and export data over time. Bad labels can become unbounded state. | Active request gauge, counters, histograms, trace span buffer, sampling decision, access log fields, exporter queue. | Keep exporter state local and bounded. Send long-term retention to Prometheus, OTLP, or log sinks. Never label on raw request/session/user IDs. |
| TLS / certificates | Certificate issuance, ticket resumption, and key rotation are runtime state that must often survive restart and coordinate across replicas. | ACME account, challenge token, certificate chain, private key reference, session ticket key, rotation generation. | Use secret/certificate storage and background services. Do not put certificate state in the generic hot-path store. |
| Extension runtimes | Wasm, Go, dynamic libraries, or external filters may need state, but unrestricted global mutable state is unsafe. | Module registry, ABI version, sandbox limits, fuel/memory counters, extension-local cache, permitted state capabilities. | Expose capability-scoped state APIs. Do not hand extensions raw access to shared backend clients by default. |
| Runtime KV | Operators may need updatable lookup maps for routing, aliases, allowlists, or transformations. | Model alias map, allowlist entry, routing override, header rewrite map, feature flag, operator-provided lookup table. | Useful as a controlled feature, but it must not replace typed stores for correctness-critical quotas, sessions, or token ledgers. |

## State Inventory And Recommended Mechanisms

This table translates the feature drivers into concrete state objects. It answers: what object are we storing, what class of state is it, what can be done locally, what needs shared storage, and what controls must exist before the state is safe to operate.

| State item | State class | State examples | Local mechanism | External/shared mechanism | Required controls | Correct first posture |
| --- | --- | --- | --- | --- | --- | --- |
| Extracted request facts | Request-local metadata | model name, method, tenant, route reason, token estimate, guardrail summary | `filter_metadata` and request context fields. | none by default. | naming convention, optional size limits, no raw secrets unless explicitly allowed. | Use the existing metadata bag for request facts only. Do not promote this into durable storage. |
| Auth identity and claims | Request-local metadata / short-lived cache | subject, tenant, groups, claims, API key validation result, JWKS keyset | request context for identity facts; bounded local JWKS or decision cache. | JWKS/auth service; optional shared policy decision cache. | TTL, key rotation, policy version, fail-closed behavior, privacy controls. | Keep identity facts local to the request; cache validation inputs/results only with explicit TTL and failure rules. |
| Request rate-limit counters | Shared hot-path state | descriptor bucket, count, remaining, reset time, deny reason | local token bucket for dev/single replica. | Redis/Valkey or external RLS for production multi-replica enforcement. | TTL, atomic increment, bounded descriptors, timeout, fail mode, metrics. | Add typed `RateLimitStore` with local and shared implementations. |
| Token quota ledger | Shared hot-path state | reserved tokens, committed tokens, remaining budget, window reset, tenant/model/provider dimensions | local implementation only for tests/dev. | Redis/Valkey atomic counters/scripts. | windowing, descriptors, idempotency, reserve/commit/refund semantics, fail closed. | Add typed `TokenLedger`; do not model token budgets as request metadata. |
| Usage/billing events | Durable business state | request ID, subject, model, provider, token counts, cost, response status, idempotency key | bounded local queue only. | event stream, database writer, Redis stream, or other async sink. | idempotency key, retry policy, backpressure, drop policy, privacy controls. | Add `UsageEventSink`; avoid synchronous database writes from filters. |
| Protocol session maps | Shared hot-path state | gateway session, backend session ID, backend server, protocol capability flags, expiry | local map with explicit single-replica/affinity warning. | Redis/Valkey hash/string with TTL. | session TTL, cleanup, stale invalidation, config generation, fail behavior. | Add `ProtocolSessionStore`; local mode is only safe for dev or explicit affinity-limited deployments. |
| Task/context ownership | Shared hot-path state | task ID, context ID, owner backend, route, terminal status, cleanup TTL | local map with explicit affinity warning. | Redis/Valkey hash/string with TTL. | terminal cleanup, config generation, stale owner behavior, async update handling. | Add `TaskOwnerStore` and queue response-derived writes safely. |
| Cache entries | Cache state | cache key, response metadata, response body reference, vector reference, stale marker | local LRU or file cache depending feature. | object store, Redis metadata, vector DB depending cache type. | TTL, max size, purge, stale policy, privacy, cache-key normalization. | Build a cache-specific API separate from counters/sessions. |
| Cache coalescing locks | Local runtime state | in-flight fill key, waiter count, cancellation flag, fill timeout | local per-key lock table. | optional Redis lock later only if cross-replica coalescing is required. | timeout, cancellation, waiter bounds, panic/error cleanup. | Start local only; correctness should degrade to duplicate upstream fetches, not broken responses. |
| Routing scorer snapshots | Derived telemetry state | endpoint score, latency, pressure, queue depth, cost, KV-cache hint, last update time | local snapshot cache. | probe/metrics service, Redis/Valkey snapshots, scheduler API. | freshness TTL, stale fallback, bounded dimensions, update metrics. | Start with local snapshots fed by probes/control-plane data and explicit stale behavior. |
| Policy decision cache | Local/shared cache | subject/route/policy-version allow/deny result, reason, expiry | local LRU. | optional Redis/Valkey if cross-replica cache is valuable. | policy version, TTL, fail-closed behavior, invalidation. | Start local; never use cache miss/error to bypass required policy. |
| DNS cache | Background runtime state | hostname, resolved addresses, TTL, negative result, resolver health | async local resolver cache. | none initially. | TTL, negative cache, max entries, refresh behavior, stale bounds. | Add local background resolver cache; avoid synchronous DNS in request path. |
| TLS certificate state | Durable runtime state | certificate chain, private key reference, ACME account, ticket key, rotation generation | local files/cache where appropriate. | Kubernetes Secrets, shared storage, ACME CA, SDS/control plane. | rotation, locking, renewal status, key protection. | Keep separate from request state layer and manage through TLS/control-plane mechanisms. |
| xDS/config resources | Configuration state | listener, route, cluster, endpoint, secret, policy, config generation | local resource cache and active snapshot. | xDS, Kubernetes, Gateway API controller, other control plane. | generation, ACK/NACK, validation, atomic swap, stale-state invalidation. | Keep separate from hot-path state stores; request path reads local snapshots only. |
| Admin/runtime stats | Local runtime state | active connections, endpoint health, state entries, config dump, profiler status, exporter status | in-process snapshots. | Prometheus, OTLP, log sinks for retention. | cardinality, privacy controls, read-only defaults, auth for admin endpoints. | Expose read-only by default; avoid making admin API an accidental state mutation surface. |
| Extension-owned state | Extension runtime state | Wasm memory, Go runtime data, dynamic module registry, extension-local cache, sandbox counters | extension-local memory with limits. | explicit capability-scoped APIs only. | sandbox policy, quotas, access control, resource accounting. | Give extensions constrained state access, not raw global backend clients. |

## Local Vs External State Mechanisms

This table compares storage mechanisms, not features. The goal is to prevent choosing one backend for every problem. Some state should stay local, some should be shared in Redis/Valkey, some should be asynchronous durable output, and some belongs in a control plane.

| Mechanism | Good fit | Bad fit | Required rules |
| --- | --- | --- | --- |
| Request context / `filter_metadata` | Request facts used by later filters, logs, metrics, routing. | Sessions, quotas, usage ledgers, cross-request cache. | Namespacing, no secrets unless explicitly allowed, no unbounded data. |
| Local `HashMap` / `DashMap` | Tests, dev, single replica, local protection, fast caches. | Multi-replica correctness, durable records. | max entries, TTL, eviction, metrics, hot-reload behavior. |
| Local LRU / bounded cache | Policy cache, response cache metadata, scorer snapshots. | Required session/task state where eviction breaks correctness. | explicit stale/miss behavior. |
| Consistent hash / sticky routing | Improving local-store hit rate. | Guaranteeing global correctness. | document replica-change behavior. |
| Redis/Valkey | Shared counters, short-lived sessions, task ownership, quota ledgers. | Long-term billing/audit as only copy; large response bodies; vector search. | timeouts, connection pooling, failure mode, key schema, TTL, metrics. |
| External service | Auth, ext_proc, scheduler, guardrails, model routing. | Low-latency inner-loop state if service is slow/unreliable. | timeout, retry policy, circuit breaker, fail mode. |
| SQL/database | Durable business records, admin-visible objects. | Every request-path decision. | async/batched writes, caching, idempotency. |
| Event stream / queue | Usage export, audit events, async processing. | Immediate admission decisions. | bounded buffer, idempotency, backpressure. |
| Object store | Large cached objects, audit blobs. | session maps, counters, route decisions. | references in hot path, async writes. |
| Vector database | semantic cache and similarity lookup. | generic key-value state. | separate API and latency budget. |
| Kubernetes API / xDS | desired config state, policies, certificates, service discovery. | synchronous hot-path lookups. | local cache, watch/reconcile, generation tracking. |
| Peer replication | local-state sync between proxies. | first implementation for correctness-critical state. | topology limits, eventual consistency warnings. |

## Comparable Proxy Patterns

This table summarizes how other proxies and gateways divide local state, shared state, and control-plane state. These are design inputs, not implementation requirements. The useful pattern across projects is explicit scoping: local state is bounded, shared enforcement is deliberate, and control-plane state is not confused with request-path counters.

| Project | What state they keep locally | What state they externalize | Pattern worth copying | Caution for Praxis |
| --- | --- | --- | --- | --- |
| Envoy | dynamic metadata, filter state, local rate limits, xDS cache, cluster health | global rate limit service, external auth/proc, xDS management server | request facts stay local; global enforcement is delegated. | Extensibility path can push too much logic into external processors. |
| HAProxy | stick tables with typed keys, expiry, counters, rates | peer synchronization for stick tables | typed bounded state tables with explicit size/expiry. | Peer sync is eventually consistent and topology-sensitive. |
| NGINX OSS | shared memory zones for worker-shared limits | none for cluster-wide OSS state | named/sized local state zones. | local node correctness is not fleet correctness. |
| NGINX Plus | shared memory zones and keyval zones | zone sync across cluster nodes | explicit runtime state sync feature. | eventual consistency and network topology caveats. |
| OpenResty | `lua_shared_dict`, local plugin state | Redis/databases from Lua code | flexible extension state. | untyped shared dicts become hard to govern. |
| Kong Gateway | plugin cache, local counters | database, Redis, control plane | per-plugin strategy choices: local, cluster, Redis. | users must understand consistency/latency tradeoffs. |
| Apache APISIX | plugin-local state and standalone config | etcd for config, Redis for distributed counters | separate config store from rate-limit store. | etcd should not become a request-path quota ledger. |
| Traefik | middleware-local rate limits, sticky cookies, health | Redis/persistent KV for distributed rate limits | distributed state is explicit per middleware. | sticky cookies do not solve required backend protocol sessions. |
| Caddy | local certificate/runtime state | shared storage modules for cert automation | durable background state uses separate storage abstraction. | cert state is not the same as request-path state. |
| Linkerd / ztunnel | scoped local connection, identity, and telemetry state | control plane for config/identity | data plane stays narrow and purpose-built. | Praxis should not absorb business state that belongs in a control plane. |

## Proposed Architecture

### Layer 1: Request Context

Request context remains the only place for facts that exist for one request:

```text
body parser / auth / router / token counter
    -> filter_metadata
    -> later filters, logging, metrics, response headers
```

Rules:

- Values are in-memory only.
- Values are not sent upstream unless a filter explicitly maps them to headers/body.
- Values are not billing records or quota ledgers.
- Keys should be namespaced by feature, for example `auth.subject`, `ai.model`, `mcp.method`, `route.reason`.

### Layer 2: Typed State APIs

Add domain-specific traits instead of one global mutable key-value API.

| Trait | Purpose | Example operations |
| --- | --- | --- |
| `RateLimitStore` | request/descriptor counters | `check_and_increment`, `remaining`, `reset_at` |
| `TokenLedger` | token and cost budgets | `reserve`, `commit`, `refund`, `get_budget` |
| `ProtocolSessionStore` | protocol session maps | `get_session`, `put_session`, `delete_session`, `refresh_ttl` |
| `TaskOwnerStore` | task/context ownership | `put_task_owner`, `get_task_owner`, `mark_terminal` |
| `PolicyDecisionCache` | short-lived auth/guardrail decisions | `get`, `put`, `invalidate_policy_version` |
| `RoutingStateStore` | scorer/probe snapshots | `get_score`, `put_snapshot`, `expire_stale` |
| `UsageEventSink` | billing/showback/audit events | `enqueue`, `flush`, `ack`, `retry` |
| `CacheIndex` | response/semantic cache metadata | `lookup`, `store_ref`, `purge`, `lock_fill` |

### Layer 3: Backend Implementations

Each typed trait should have controlled backend implementations.

| Backend | Scope | Use cases | Must-have behavior |
| --- | --- | --- | --- |
| `local` | process-local | tests, dev, single replica, local protection | max entries, TTL, eviction metrics. |
| `redis` / `valkey` | shared hot-path | quotas, counters, sessions, task ownership | timeouts, pool limits, atomic ops, key prefix, fail mode. |
| `external_service` | delegated decisions | auth, scheduling, guardrails, external processing | request timeout, failure mode, circuit breaker. |
| `event_sink` | durable async output | billing, audit, usage export | idempotency, retry, backpressure. |
| `control_plane` | desired state | config, route/model registry, certs | local cache, generation/versioning. |

### Layer 4: Config Model

State backend config should be centralized enough to avoid duplicate Redis clients, but scoped enough that each feature can choose local or shared behavior.

Example shape:

```yaml
state:
  backends:
    local-dev:
      type: local
      max_entries: 100000
    shared-hot-path:
      type: redis
      url: ${REDIS_URL}
      key_prefix: praxis:{namespace}
      timeout_ms: 20
      pool_size: 16
      tls:
        enabled: true

filters:
  - name: rate_limit
    config:
      store: shared-hot-path
      failure_mode: closed
```

Feature-specific filters should not each define their own incompatible Redis configuration unless there is a strong reason.

## Key Schema Rules

| Rule | Reason |
| --- | --- |
| Include a global key prefix. | Avoid collisions between deployments. |
| Include namespace/tenant only when bounded and intentional. | Prevent cardinality explosions. |
| Hash unbounded or user-controlled identifiers. | Avoid oversized keys and leaking sensitive data. |
| Include config generation where stale mappings are dangerous. | Avoid routing to removed clusters after reload. |
| Set TTL on every hot-path key unless explicitly durable. | Prevent leaks. |
| Never put raw prompt, API key, token, tool arguments, or PII in keys. | Security and privacy. |
| Use typed key constructors, not string concatenation spread across filters. | Prevent collisions and inconsistent encoding. |

Example key classes:

| State | Example key shape |
| --- | --- |
| request limit | `praxis:{scope}:rl:req:{descriptor_hash}:{window}` |
| token quota | `praxis:{scope}:rl:tok:{descriptor_hash}:{window}` |
| protocol session | `praxis:{scope}:session:{protocol}:{session_hash}` |
| backend session map | `praxis:{scope}:session:{protocol}:{session_hash}:backends` |
| task owner | `praxis:{scope}:task:{protocol}:{task_hash}` |
| policy cache | `praxis:{scope}:policy:{policy_version}:{subject_hash}:{route_hash}` |
| routing score | `praxis:{scope}:route_score:{cluster}:{endpoint_hash}` |
| usage idempotency | `praxis:{scope}:usage:{request_id_hash}` |

## Failure Mode Policy

| State class | Default failure behavior | Why |
| --- | --- | --- |
| Auth identity / policy | fail closed | Avoid bypass. |
| Token quota / budget | fail closed | Avoid unpaid or uncontrolled usage. |
| Request rate limit | configurable, default closed for protected routes | Depends on deployment tolerance. |
| Protocol session ownership | fail closed or reinitialize only when protocol allows | Avoid sending follow-up traffic to wrong backend. |
| Task ownership | fail closed unless route has explicit fallback | Avoid corrupting task lifecycle. |
| Usage event export | do not block forever; buffer and retry | Avoid total outage from billing sink failure, but never lose silently. |
| Cache lookup | fail open as miss | Cache must not be required for correctness. |
| Semantic cache | fail open as miss | Correctness should not depend on cache. |
| Routing scorer state | fall back to deterministic safe routing | Stale scorer input should not block all traffic. |
| Probe readings | expire stale and fall back | Better no signal than stale signal. |
| DNS cache | stale-while-revalidate only within configured bound | Avoid hard dependency on resolver for every request. |
| Admin/stats | degrade visibility | Do not fail traffic because dashboard state is unavailable. |

## Observability Requirements

Every state backend and typed store should expose:

| Signal | Purpose |
| --- | --- |
| operation count by store and operation | usage visibility |
| operation latency histogram | request-path budget tracking |
| error count by error type | troubleshooting |
| timeout count | backend health and fail-mode validation |
| key count / approximate entry count | leak/cardinality detection |
| eviction count | local capacity tuning |
| stale read count | routing/cache correctness |
| fail-open / fail-closed decisions | security and reliability audit |
| backend connection pool stats | Redis/Valkey capacity tuning |

Metrics labels must be bounded. Do not label on raw user IDs, request IDs, task IDs, session IDs, prompt text, or full paths.

## Lifecycle Flows

### Request Rate Limit Flow

```text
request enters
  -> auth/model/body filters derive descriptor facts
  -> descriptor builder creates bounded descriptor key
  -> RateLimitStore.check_and_increment()
  -> allow: continue pipeline and attach remaining/reset metadata
  -> deny: return 429 with rate-limit headers
  -> error: apply configured failure mode
```

### Token Quota Flow

```text
request body inspected
  -> input token estimate produced in filter_metadata
  -> TokenLedger.reserve() checks budget before upstream
  -> upstream response inspected for output/total tokens
  -> TokenLedger.commit() updates final usage
  -> UsageEventSink emits durable billing/showback event
  -> on partial/error response: refund or commit partial according to policy
```

### Protocol Session Flow

```text
request body/header identifies protocol session
  -> ProtocolSessionStore.get_session()
  -> if found: route to stored backend/session
  -> if missing and protocol allows: initialize backend session
  -> store backend mapping with TTL
  -> response phase refreshes/deletes session as needed
  -> backend 404/session invalidation removes stale mapping
```

### Task Ownership Flow

```text
request creates task or references context
  -> response body parser extracts task_id/context_id/terminal state
  -> sync response-body phase queues state update in request context
  -> async logging/finalization phase writes to TaskOwnerStore
  -> later task requests read owner mapping before routing
  -> terminal state deletes or expires mapping
```

### Routing Scorer Flow

```text
probe/metrics/control-plane source updates endpoint facts
  -> RoutingStateStore keeps fresh snapshot with TTL
  -> request builds candidate backend set
  -> scorer reads bounded fresh facts
  -> selected route and reason stored in filter_metadata
  -> stale/missing facts fall back to configured safe route policy
```

### Usage Event Flow

```text
request completes
  -> usage dimensions and token facts are collected
  -> idempotency key is built from request id / upstream id
  -> event is enqueued to sink
  -> sink retries with backpressure bounds
  -> failure is observable and never silently dropped
```

## Architecture Questions To Resolve

| Question | Proposed default | Why it matters |
| --- | --- | --- |
| Generic KV or typed stores? | typed stores over shared backend clients | Prevents feature-specific stringly state and unsafe extension access. |
| First shared backend? | Redis/Valkey | Best fit for TTLs, counters, hashes, low-latency hot-path state. |
| Is local mode production supported? | yes, but only for explicitly local-safe features | Avoid pretending local counters/sessions are multi-replica correct. |
| Should protocol sessions support encrypted client tokens? | investigate as optional mode | Could reduce shared store dependence but complicates revocation and rotation. |
| Should peer replication be first? | no | More complex consistency story than Redis/Valkey. |
| Should SQL be in hot path? | no by default | Too much latency/operational risk for per-request admission. |
| Should Kubernetes API be in hot path? | no | Use watches/controllers/local cache instead. |
| How are response-body-derived writes handled? | queue in request context, flush asynchronously at finalization | Avoid blocking sync body hooks. |
| How does hot reload affect local state? | local state may reset; shared state survives | Must be documented and observable. |
| How are state schemas evolved? | version keys/values where needed | Prevent stale mappings after config reload or feature changes. |

## Recommended Implementation Slices

| Order | Slice | Scope | Depends on |
| --- | --- | --- | --- |
| 1 | State guidelines and key conventions | Document state classes, key rules, local-vs-shared semantics. | #99 consensus |
| 2 | Local bounded state utilities | TTL map, bounded LRU, eviction metrics, typed key helper. | guidelines |
| 3 | `RateLimitStore` local + Redis/Valkey | Request descriptor rate limiting with shared backend. | local utilities |
| 4 | `TokenLedger` local + Redis/Valkey | Token quota reserve/commit/refund path. | token counting |
| 5 | `UsageEventSink` | Durable-ish async usage export with idempotency. | token ledger |
| 6 | `ProtocolSessionStore` | Session map with local and Redis/Valkey modes. | state backend |
| 7 | `TaskOwnerStore` | Task/context ownership and async response-derived flush. | protocol session patterns |
| 8 | `PolicyDecisionCache` | Local cache, optional shared cache, policy-version invalidation. | auth/security work |
| 9 | `RoutingStateStore` | Fresh endpoint/model facts for routing scorers and probes. | probes/routing scorers |
| 10 | Cache-specific state APIs | Response cache index, fill locks, semantic cache references. | traffic shaping/cache work |

## Follow-Up Issues To Create Or Refine

| Follow-up | Purpose |
| --- | --- |
| Add state architecture docs | Capture accepted state taxonomy and backend rules. |
| Add bounded local state utilities | Shared TTL/eviction primitives for filters. |
| Add Redis/Valkey state backend | Shared client/pool/config, timeout handling, metrics. |
| Add typed rate-limit store | Replace ad hoc per-filter buckets where shared enforcement is needed. |
| Add token ledger | Support MaaS token quotas and budgets. |
| Add usage event sink | Support billing/showback events outside request path. |
| Add protocol session store | Support MCP/A2A/sticky session ownership. |
| Add task owner store | Support follow-up task routing. |
| Add state operation metrics | Standardize observability across all stores. |
| Add state config validation | Prevent unsafe local mode or fail-open config on protected features. |

## Acceptance Criteria For This Spike

The spike is complete when maintainers agree on:

- The state taxonomy.
- Which state categories may stay request-local.
- Which state categories may use local process memory.
- Which state categories require Redis/Valkey or another shared backend.
- Which state categories must remain outside the request hot path.
- The first backend implementation target.
- The first typed state traits to implement.
- Required TTL/key/cardinality/failure-mode rules.
- A follow-up issue list with staged implementation slices.

## Recommendation

Adopt a typed, layered state architecture.

The first shared backend should be Redis/Valkey because it covers the most urgent hot-path needs: request counters, token ledgers, protocol sessions, task ownership, and short-lived policy/cache entries. Local in-memory backends should exist for tests, demos, development, and explicitly single-replica deployments, but local mode must not be documented as multi-replica correct.

Do not build one unscoped global key-value store and let every filter write arbitrary keys. That would make correctness, observability, security, and operations worse over time. Use shared backend clients underneath typed stores, with strict config validation and common metrics.

This approach lets Praxis become stateful where AI gateway and proxy semantics require it, while still preserving the default proxy discipline: keep the hot path fast, bounded, observable, and explicit about failure behavior.

## References

- [Spike issue: Stateful Proxy Analysis](https://github.com/praxis-proxy/praxis/issues/99)
- [Research notes](research-notes.md)
- [Implementation plan](implementation-plan.md)
