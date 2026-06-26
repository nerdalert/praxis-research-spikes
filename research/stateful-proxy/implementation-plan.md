# Praxis Stateful Proxy Initial Implementation Plan

## Purpose

This document turns the stateful-proxy spike research into an initial implementation sequence. It is intentionally narrower than the research notes. The goal is to define the first practical code slices that can land incrementally without committing Praxis to one oversized state subsystem.

The implementation should start with common foundations and one or two concrete users. Avoid a generic global key-value store as the first PR. The useful first step is a small set of shared primitives that make later stateful features consistent.

## Goals

| Goal | Description |
| --- | --- |
| Establish state conventions | Define state classes, key naming, TTL expectations, local-vs-shared semantics, and failure-mode rules. |
| Add reusable local state primitives | Provide bounded in-memory TTL/eviction utilities that filters can reuse instead of each creating custom maps. |
| Add typed state traits | Create explicit APIs for rate limits, token ledgers, sessions, task ownership, and caches over time. |
| Add one shared backend first | Implement Redis/Valkey as the first shared hot-path backend once the trait boundary is clear. |
| Keep request metadata separate | Preserve `filter_metadata` as request-local fact storage, not a durable ledger. |
| Make state observable | Add metrics/logging around state operations from the start. |
| Keep rollout incremental | Land small PRs that are each reviewable and testable. |

## Non-Goals For Initial Implementation

| Non-goal | Reason |
| --- | --- |
| Do not implement every stateful feature immediately. | The spike covers many features; this plan only starts the foundation. |
| Do not add a raw global KV API as the main abstraction. | It would encourage untyped, unbounded, stringly state. |
| Do not put SQL/Kubernetes/object-store calls directly in request filters. | Those belong behind control-plane caches, event sinks, or background services. |
| Do not make local mode appear multi-replica correct. | Local state is useful but must be documented honestly. |
| Do not block MCP/A2A/MaaS work on the entire state architecture. | The first slices should unblock those features without requiring everything. |

## Design Principles

| Principle | Implementation impact |
| --- | --- |
| Typed before generic | Add domain traits such as `RateLimitStore` rather than exposing arbitrary get/set everywhere. |
| Local first, shared second | Implement and test local bounded behavior before adding Redis/Valkey. |
| Bound everything | Every local map/cache needs max entries, TTL, eviction policy, and metrics. |
| Explicit failure modes | Every shared state operation needs timeout and fail-open/fail-closed behavior. |
| State is not config | Runtime counters/sessions should not be stored in xDS/Kubernetes APIs. |
| Config is not a ledger | Config resources define policy; request-path stores enforce dynamic counters/session state. |
| Request facts stay request-local | `filter_metadata` feeds filters and logs; it should not become persistence. |
| Hot reload must be documented | Local filter state resets on reload; external state should survive. |
| Observability is required | State operations need metrics from the first implementation. |

## Proposed Module Layout

This is a starting shape, not a final API contract.

| Area | Candidate path | Purpose |
| --- | --- | --- |
| State crate/module | `core/src/state/` or new `state/` crate | Shared state traits, errors, config, key utilities. |
| Local backend | `core/src/state/local/` | Bounded TTL maps, LRU helpers, local counters. |
| Redis backend | `core/src/state/redis/` behind feature flag | Shared hot-path backend. |
| State config | `core/src/config/state.rs` | Parse `state.backends` config and feature-level store references. |
| Metrics | existing metrics integration | State operation metrics. |
| Filter integration | filter-specific modules | Rate limit, token ledger, sessions, etc. consume typed traits. |

Recommendation: prefer a dedicated internal module first. Split into a separate crate only when multiple top-level crates need the API cleanly.

## Configuration Shape

Target eventual shape:

```yaml
state:
  backends:
    local-default:
      type: local
      max_entries: 100000
      default_ttl_secs: 3600

    shared-hot-path:
      type: redis
      url: ${REDIS_URL}
      key_prefix: praxis
      timeout_ms: 20
      pool_size: 16
      tls:
        enabled: true
```

Feature usage example:

```yaml
filters:
  - name: rate_limit
    config:
      mode: descriptor
      store: shared-hot-path
      failure_mode: closed
```

Initial PRs do not need to implement the full config shape. The first config PR should define the minimal schema and validation rules.

## Implementation Phases

### Phase 0: State Rules Documentation

| Item | Detail |
| --- | --- |
| Scope | Add architecture docs for state taxonomy, storage classes, key rules, TTL expectations, and failure modes. |
| Code changes | Documentation only. |
| Tests | None required beyond doc lint if applicable. |
| Output | Maintainers agree on vocabulary before APIs land. |
| Risk | Low. |

Acceptance criteria:

- Documents distinguish request-local, local runtime, shared hot-path, durable business, config, and background state.
- Documents state that local mode is not multi-replica correct unless explicitly paired with affinity and accepted risk.
- Documents that Redis/Valkey is the first proposed shared hot-path backend, not the universal state store.

### Phase 1: Local Bounded State Utilities

| Item | Detail |
| --- | --- |
| Scope | Add local bounded TTL map and optional LRU helper for future stateful filters. |
| Code changes | `BoundedTtlMap<K, V>`, eviction behavior, time abstraction for tests, metrics hooks if metrics crate is already available. |
| Tests | TTL expiry, max-entry eviction, update refresh, remove, concurrent access if shared wrapper is included. |
| Output | Filters stop reinventing ad hoc `DashMap`/`HashMap` logic. |
| Risk | Medium if concurrency model is overbuilt too early. |

Suggested API sketch:

```rust
pub struct BoundedTtlMap<K, V> { /* internal */ }

impl<K, V> BoundedTtlMap<K, V>
where
    K: Eq + Hash + Clone,
{
    pub fn insert(&self, key: K, value: V, ttl: Duration) -> InsertOutcome;
    pub fn get(&self, key: &K) -> Option<V>;
    pub fn remove(&self, key: &K) -> Option<V>;
    pub fn len(&self) -> usize;
    pub fn evict_expired(&self, now: Instant) -> usize;
}
```

Keep this utility intentionally boring. Do not add Redis or feature-specific concepts yet.

### Phase 2: State Error And Failure Mode Types

| Item | Detail |
| --- | --- |
| Scope | Add common state operation errors and timeout/failure behavior helpers. |
| Code changes | `StateError`, `StateTimeout`, `StateUnavailable`, `StateCorrupt`, helper for fail-open/fail-closed decisions. |
| Tests | Error display/source tests, failure-mode decision tests. |
| Output | Future stateful filters use consistent error handling. |
| Risk | Low. |

Suggested types:

```rust
pub enum StateError {
    Timeout,
    Unavailable(String),
    InvalidValue(String),
    Serialization(String),
    Backend(String),
}

pub enum StateFailureMode {
    Open,
    Closed,
}
```

This can reuse existing per-filter `failure_mode` concepts if present in the target branch.

### Phase 3: `RateLimitStore` Foundation

| Item | Detail |
| --- | --- |
| Scope | Introduce the first typed state trait using request rate limiting as the concrete consumer. |
| Code changes | `RateLimitStore` trait, local implementation using bounded map, descriptor key helper, integration with existing rate-limit filter if branch state allows. |
| Tests | local allow/deny, TTL reset, descriptor isolation, bounded eviction behavior. |
| Output | Concrete proof that typed state traits fit Praxis filters. |
| Risk | Medium; must avoid breaking existing local rate-limit behavior. |

Suggested trait:

```rust
#[async_trait]
pub trait RateLimitStore: Send + Sync {
    async fn check_and_increment(&self, key: &RateLimitKey, policy: &RateLimitPolicy) -> Result<RateLimitDecision, StateError>;
}
```

Initial implementation may be synchronous under the hood, but the trait should probably be async if Redis/Valkey follows soon.

### Phase 4: State Operation Metrics

| Item | Detail |
| --- | --- |
| Scope | Add common metrics for state operations. |
| Metrics | `praxis_state_operations_total`, `praxis_state_operation_duration_seconds`, `praxis_state_errors_total`, `praxis_state_entries`, `praxis_state_evictions_total`. |
| Labels | `store`, `backend`, `operation`, `result`, bounded `error_type`. |
| Tests | Metrics emitted for success/error paths if metrics test harness exists. |
| Output | State is observable before Redis lands. |
| Risk | Cardinality. Do not label on raw keys, users, sessions, request IDs. |

### Phase 5: Redis/Valkey Backend Foundation

| Item | Detail |
| --- | --- |
| Scope | Add Redis/Valkey shared backend client and first implementation for `RateLimitStore`. |
| Code changes | feature-gated dependency, config parser, connection manager/pool, timeout wrapper, key prefixing, health check. |
| Tests | unit tests for key construction; integration tests with Redis container if test infra permits; fallback mocked backend otherwise. |
| Output | First production-oriented shared hot-path state backend. |
| Risk | Dependency, TLS, async runtime, connection pooling, test stability. |

Backend requirements:

- All operations must have bounded timeouts.
- Keys must go through typed constructors.
- Values should have TTLs unless explicitly permanent.
- Backend errors must map into `StateError` consistently.
- No raw prompt/API-key/user-controlled full value in keys.

### Phase 6: Token Ledger Trait

| Item | Detail |
| --- | --- |
| Scope | Add state API for token budgets and MaaS cost controls. |
| Code changes | `TokenLedger` trait with reserve/commit/refund or check/commit model. |
| Tests | reserve success, over-limit, commit final usage, refund on upstream failure, idempotency. |
| Output | Foundation for token rate limiting and MaaS budget enforcement. |
| Risk | Semantics are product-sensitive; may need input from MaaS requirements before finalizing. |

Open design choice:

- `reserve -> commit/refund` is safer for pre-request admission but needs idempotency.
- `check -> commit` is simpler but can overrun budgets for high concurrency.

### Phase 7: Protocol Session And Task Stores

| Item | Detail |
| --- | --- |
| Scope | Add typed stores needed by MCP/A2A, sticky sessions, and follow-up routing. |
| Code changes | `ProtocolSessionStore`, `TaskOwnerStore`, local implementation, Redis implementation later. |
| Tests | create/get/delete, TTL refresh, stale backend invalidation, terminal task cleanup. |
| Output | Session/task state becomes reusable and not embedded inside one protocol filter. |
| Risk | Protocol-specific semantics can leak into generic traits. Keep traits narrow. |

Suggested split:

| Trait | Use |
| --- | --- |
| `ProtocolSessionStore` | session ID -> backend/session metadata maps. |
| `TaskOwnerStore` | task/context ID -> owner backend/route. |
| `CorrelationMap` | short-lived ID translation maps for protocols and async flows. |

### Phase 8: Usage Event Sink

| Item | Detail |
| --- | --- |
| Scope | Add async sink abstraction for billing/showback/audit events. |
| Code changes | bounded queue, idempotency key, retry policy, sink trait. |
| Tests | enqueue, backpressure, retry, duplicate idempotency behavior. |
| Output | Usage accounting does not block request path on durable storage. |
| Risk | Dropped events and backpressure semantics need explicit product decision. |

## First Three PRs Recommendation

| PR | Title | Scope | Why first |
| --- | --- | --- | --- |
| 1 | Document Praxis state model | Docs only: taxonomy, local/shared semantics, key rules, failure modes. | Low-risk consensus builder. |
| 2 | Add bounded local state utilities | Local TTL/eviction primitives and tests. | Enables safe local state without choosing Redis yet. |
| 3 | Add `RateLimitStore` local implementation | First typed store with real filter consumer. | Proves the abstraction against an existing stateful feature. |

Redis/Valkey should be PR 4 or later, after the trait and local behavior are reviewed.


## Concrete Validation Plan

| Validation | Setup | Success criteria |
| --- | --- | --- |
| Local bounded map tests | Unit tests with fake clock. | TTL expiry, max-entry eviction, refresh behavior, remove behavior, and metrics all work deterministically. |
| Hot-reload behavior | Start Praxis with local stateful filter, create state, reload config. | Local state reset is either expected and logged or preserved only if explicitly designed. |
| Redis shared rate limit | Two Praxis instances using one Redis/Valkey backend. | Requests through both instances consume the same descriptor bucket. |
| Redis outage fail closed | Kill or block Redis during protected rate-limit/token route. | Requests fail according to configured closed mode and metrics show backend errors/timeouts. |
| Redis outage fail open | Same as above with explicitly open mode. | Requests continue and metrics/logs show fail-open decisions. |
| Redis latency budget | Inject latency or use a slow test proxy around Redis. | Request latency remains bounded by configured state timeout. |
| Key cardinality guard | Generate many descriptors/sessions. | Local maps evict or reject according to limits; Redis keys have TTLs and bounded prefixes. |
| Multi-replica protocol ownership | Two instances share session/task store. | Follow-up request can route correctly through either instance. |
| Usage event backpressure | Sink is unavailable or slow. | Queue/backpressure behavior is explicit; events are not silently dropped. |

## Redis Client Evaluation Checklist

| Criterion | Why it matters |
| --- | --- |
| Async Tokio compatibility | Praxis request path is async. |
| Connection pooling / multiplexing | Avoid one connection per filter or request. |
| TLS support | Required for production deployments. |
| Auth support | Redis/Valkey deployments often require AUTH/ACL. |
| Cluster / Sentinel support | May be required later even if not in v1. |
| Timeout controls | Every request-path operation must be bounded. |
| Reconnect behavior | Backend restarts should not require proxy restart. |
| Script support | Token ledgers and sliding windows may need atomic Lua/scripts. |
| Metrics hooks | Need operation latency/error visibility. |
| Maintenance health | Avoid adding a critical unmaintained dependency. |

Initial recommendation: evaluate `fred` first, with `redis-rs` as the fallback comparison.

## Validation Strategy

| Test type | What to prove |
| --- | --- |
| Unit tests | key construction, TTL expiry, eviction, error mapping, failure-mode decision. |
| Filter tests | stateful filter behavior uses typed store without regressions. |
| Integration tests | local rate limiting and session/task store behavior through actual proxy request path. |
| Multi-replica tests | two Praxis instances sharing Redis/Valkey produce correct shared enforcement. |
| Restart/reload tests | local state resets are documented; Redis/Valkey state survives reload/restart. |
| Failure tests | Redis timeout/down behavior follows configured failure mode. |
| Metrics tests | state operation metrics appear with bounded labels. |

## Risks And Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Generic KV becomes a dumping ground | Hard-to-debug, unsafe state semantics. | Prefer typed domain stores. |
| Redis latency hurts hot path | Request latency and tail spikes. | strict timeouts, pools, metrics, local fallback only where safe. |
| Local mode misused in production | Incorrect quotas/sessions across replicas. | config warnings/errors and docs. |
| Unbounded keys/maps | memory leaks and cardinality explosions. | max entries, TTL, hashed unbounded identifiers. |
| State writes from sync body hooks block | response streaming latency or runtime issues. | queue state updates and flush in async finalization. |
| Security-critical features fail open | auth/quota bypass. | default closed for security/quota; require explicit opt-in to open. |
| Hot reload resets state unexpectedly | local rate limits/circuits/session maps disappear. | document clearly; externalize correctness-critical state. |
| Metrics cardinality explosion | Prometheus/OTel instability. | bounded labels only; never raw keys/session IDs. |

## Open Questions Before Coding Redis/Valkey

| Question | Needed decision |
| --- | --- |
| Which Rust Redis client? | Choose based on async runtime fit, TLS support, cluster support, maintenance. |
| Valkey naming? | Decide whether config says `redis`, `valkey`, or neutral `redis_compatible`. |
| Cluster support in v1? | Single endpoint first or cluster/sentinel support immediately. |
| TLS and auth requirements? | Required for production-ready backend config. |
| Lua/scripts or optimistic transactions? | Needed for token ledger correctness. |
| Connection pool ownership? | One shared pool per backend, not per filter. |
| Failure-mode defaults? | Closed for quota/security, configurable for softer features. |
| Test environment? | Containerized Redis integration tests or mock-only first pass. |

## Implementation Handoff Checklist

Before starting each PR:

- Confirm target branch and current state of related code.
- Confirm no overlapping upstream PR already implements the same slice.
- Keep changes scoped to one layer or one typed store.
- Add tests before integrating with multiple filters.
- Document local-vs-shared semantics in the PR body.
- Include failure behavior and metrics impact in the PR body.
- Avoid local filesystem paths in docs or PR text.

## Summary

Start with the state model and local bounded primitives. Then prove the typed-store approach through rate limiting. Only after that should Redis/Valkey be added as a shared backend. This keeps the implementation reviewable and prevents the state layer from becoming an untyped global storage mechanism.
