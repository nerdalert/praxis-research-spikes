# Grid #136 — Shared Session Affinity: Implementation Review and Plan

**Reviewed:** 22 October 2026  
**Issue:** [praxis-proxy/grid#136](https://github.com/praxis-proxy/grid/issues/136)  
**Reference Grid revision:** [`33cb906be2bb0ebdbaf253bd307939a44f41b37b`](https://github.com/praxis-proxy/grid/tree/33cb906be2bb0ebdbaf253bd307939a44f41b37b) (`main` at review)  
**Reference Praxis AI revision:** [`5059043e43ad52aaf5d00a996cb5f6fa83d0943c`](https://github.com/praxis-proxy/ai/tree/5059043e43ad52aaf5d00a996cb5f6fa83d0943c) (`main` at review)  
**Status:** Implementation proposal and code-review findings, **not an implementation or executed qualification**. No repository changes were pushed.

## 1. Assessment

**Recommendation: implement #136 as an optional, request-time, shared session-binding capability, not as another routing policy or a Grid signal.** The session binding names a stable, logical candidate; the current serving snapshot determines whether that candidate may serve the request. Scores, weights, ranking, locality preferences and measured load can influence **new** placements without moving an already bound session. Hard policy, capability, authorization, admission and availability constraints always take precedence over a binding.

This is a **cross-replica consistency feature**. A Redis/Valkey value alone will not satisfy it: the implementation also needs atomic first-writer-wins creation, atomic invalidation/replacement, scope isolation, safe handling of different concurrently served revisions, explicit outage semantics, and an actual multi-replica Kind qualification.

The issue is substantially aligned with today's design, including signals-based selection. The implementation needs to account for changes that have landed since the original work was conceived:

- **Grid publishes stable destination identities and admission states.** Reuse these instead of binding to an address, a pod, a list offset, a selection group, or a metric score.
- **Praxis AI already has in-memory session affinity** in `intelligent_route`, but it is process-local, stores the raw session string as an in-process map key, does not atomically coordinate competing replicas, and currently applies a fixed TTL from insertion rather than sliding expiry on reuse. This is the primary implementation seam for deployments using that path.
- **Grid also has a newer Grid-owned gateway with live signal snapshots and `grid_site_route`.** It has deterministic candidate IDs, admission, capacity/pressure state, prefixed-prompt locality and stored-response pinning, but its request path does **not** yet implement the explicit header/cookie session-binding contract of #136. The new capability must not silently be claimed for this path until integrated and qualified.
- **Signal publication is not itself permission to move sessions.** Live-load reordering, measured capacity, freshness of *load samples*, and soft preference changes are distinct from an authoritative provider withdrawal, access-policy change, or admission transition.
- **Authoritative empty/no-route revisions and accepted-versus-serving revisions are already part of the routing contract.** Affinity must respect them rather than resurrecting a previously selected target.
- **The test tooling now has both multi-consumer and real signal-propagation qualifications.** Build a dedicated qualification by reusing their provisioning and evidence patterns, not a unit-test-only validator or a manually provisioned demonstration.

**Critical design condition:** do not promise strict, simultaneous cross-replica policy decisions while replicas serve different accepted revisions. A content-addressed revision digest is an identity, **not** a monotonic generation number. Specify a revision-convergence or monotonic hard-eligibility fencing mechanism; otherwise one stale gateway can rebind a session back to a target another gateway just invalidated.

## 2. Review findings and decisions

| Priority | Finding | Required response |
|---|---|---|
| **P0** | First requests racing on different replicas can choose different backends if selection is performed before a non-atomic binding write. | An atomic **get-or-create** must return the winning destination, and every racing caller must route using that winner after validating it. No return of a losing local choice. |
| **P0** | `existing_only` and hard policy changes must not be confused with score or load changes. | Shared, routing-mode-independent eligibility predicate: existing bindings permitted for `existing_only`; new bindings prohibited. Excluded/removed/unauthorized candidates cannot be reused. |
| **P0** | A stale gateway may incorrectly undo a newer hard rebind. Semantic SHA-256 digests alone cannot order revisions. | Define hard-eligibility revision fencing or a safe **retry/refuse while behind** rule. Qualify mixed-revision operation explicitly. |
| **P0** | Shared-store outage can devolve into two independently sticky local maps without detection. | Explicit outage mode; never advertise global affinity during fallback. Recommend **bounded stateless selection** by default, with an opt-in fail-closed choice for workloads requiring affinity consistency. |
| **P0** | A raw session ID or an insufficiently scoped key could correlate tenants or routes across services. | Keyed digest of canonical scope + session ID, secret rotation plan, identity from trusted authentication context, no secrets or raw IDs in instrumentation/evidence. |
| **P1** | Existing Praxis AI session affinity is not reusable as-is for shared operation. | Introduce a store abstraction with a local compatibility adapter and a dedicated async shared adapter, preserving current default behavior exactly. |
| **P1** | The Grid-owned gateway's prompt-prefix index and stored-state tags are **not** session bindings. | Keep them separate; define priority and interactions without extending SWIM/CRDT or sharing prefix-cache indexes. |
| **P1** | Rebinding due to an invalid target must remain race-safe and cannot bypass the currently served snapshot. | Compare-and-replace with stored generation, bounded retries, revalidation of the returned winner, explicit unavailable/no-route result. |
| **P1** | No current Kind qualification proves shared affinity survives consumer hops and restarts. | Add a **dedicated xtask** with run-owned Kind topology, two real consumer processes, two real destinations, Valkey, changing signals and revision evidence. |
| **P1** | `docs/releases.md` does not currently exist; the release checklist is `docs/release.md`. | Update **`docs/release.md`** as the canonical matrix; additionally add a short `docs/releases.md` pointer if the literal requested path must be present. Avoid diverging release lists. |
| **P2** | The configured TTL and capacity bounds lack shared-backend semantics. | Document insertion, read refresh, expiry, key/version format, store capacity protection, and behavior under retries/timeouts. |
| **P2** | Store reliability and privacy must be measurable without per-session labels. | Closed-cardinality counters, duration histograms, bounded trace annotations, sanitized per-request qualification correlation. |

## 3. Verified current architecture and changes since issue creation

### 3.1 Operator / overlay path

Grid's operator reconciles providers, policy and signals into a versioned routing state. An overlay candidate already conveys a stable ID and an admission state (`new_and_existing`, `existing_only`, or exclusion by omission / `none` where supported). Selection configuration, ranking and other score-related fields can change without changing the logical candidate. Grid's overlay semantic revision is content-addressed; its lifecycle distinguishes **rendered → distributed → accepted → serving**. An empty *valid* revision means **no route**, including for previously bound sessions.

Sources: [routing overlay architecture](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/routing.md), [routing guide](https://github.com/praxis-proxy/grid/blob/main/docs/routing.md), [administrative draining](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/provider-draining.md), [operator ID derivation](https://github.com/praxis-proxy/grid/blob/main/crates/operator/src/resources/geography.rs).

**Important identity detail:** the operator's overlay ID currently uses a deterministic FNV-1a hash of `{kind}/{name}/{site}/{cluster}`. The Grid-owned gateway can also derive a readable fallback ID from those fields for old/static configurations, whereas Praxis AI validates explicit overlay `stable_id` uniqueness. **Prefer the explicit Grid-published ID whenever present.** Treat changes to any identity-defining field as a new candidate unless Grid explicitly supplies a durable independent identity. Do not assume that a backend endpoint/IP change changes candidate identity; do not assume a renamed cluster is the same identity. Avoid storing FNV-derived IDs as secrets or interpreting them as cryptographic authentication.

### 3.2 Current Praxis AI implementation

At the reviewed AI code, [`filters/src/routing/intelligent_route.rs`](https://github.com/praxis-proxy/ai/blob/main/filters/src/routing/intelligent_route.rs):

- `SessionAffinityConfig` supports `enabled`, `header`, `cookie`, `ttl_secs` (default 3,600; maximum 86,400).
- `SessionAffinity` is a process-local `DashMap<String, Binding>` with a 10,000-entry bound.
- The `Binding` stores capability kind, name, stable candidate ID and a monotonic-time expiration.
- `select_and_route` checks affinity before falling back to the existing candidate picker; an `existing_only` candidate may be reused, but excluded candidates fail over.
- Lookup does not slide expiration on a successful reuse. Concurrent inserts are not a distributed first-writer-wins operation.
- Hot reload is accepted atomically for valid overlays and retains last-known-good on invalid updates. New routing eligibility must continue to use the active accepted/serving snapshot.

The AI repository also has an established Valkey/Redis transport, including standalone/Sentinel handling and bounded async operations, under [`filters/src/token_rate_limit/valkey/`](https://github.com/praxis-proxy/ai/tree/main/filters/src/token_rate_limit/valkey). Reuse compatible transport/credential and timeout patterns **where appropriate**, but do **not** couple affinity keys or mutable policy to the token-quota ledger. The shared affinity adapter should stand on its own and not require the optional token-rate-limit filter feature.

### 3.3 Current signal-driven serving path

The Grid-owned gateway resolves `RouteSnapshot` from asynchronously polled metrics, already computes usable candidate ordering and pressure state **off the request path**, and swaps snapshots atomically. The request filter sees a single immutable snapshot for its decision. Its `grid_site_route` selection accounts for measured load, optional shedding, prefix locality and stored response/conversation IDs. The latter two are **separate mechanisms**: prefix affinity is a per-process approximation of KV locality; stored-state IDs are authenticated locator tags, not arbitrary caller session bindings.

Sources: [`snapshot.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/snapshot.rs), [`route.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/route.rs), [`descriptor.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/descriptor.rs), [`serving.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/serving.rs), [`signals.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/signals.rs), [prefix/stored-state contract](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/prefix-affinity.md).

Recent developments to retain in the design include measured availability, learned ceilings, missing/stale-signal handling, optional capacity shedding and real peer-signal qualification: see [#319](https://github.com/praxis-proxy/grid/pull/319), [#385](https://github.com/praxis-proxy/grid/pull/385), [signal propagation](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/signals.md), and the linked ingest-diagnostics work [#371](https://github.com/praxis-proxy/grid/pull/371) / [#372](https://github.com/praxis-proxy/grid/pull/372). These are contextual evolution, not additional selection modes to implement for #136.

**Design consequence:** a pinned request must be checked against the *same* current candidate/snapshot authorization, routing reachability, admission and availability rules as an unbound request. It must not run the soft ranking algorithm again merely because a score moved. If the current system uses an authoritative shedding/pressure rejection that applies to **all** requests, that hard gate must also apply to pinned requests; do not silently bypass it. Specify this distinction in code rather than assuming all signal-derived state is soft.

### 3.4 Qualification/tooling changes

Grid currently exposes a multi-consumer Kind harness at [`single_cluster_multi_gateway_qualification.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env/single_cluster_multi_gateway_qualification.rs), a Valkey-backed quota topology and runner at [`token_rate_limit_qualification.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env/token_rate_limit_qualification.rs), and live multi-cluster signal qualification at [`llmd_pool_metrics_demo.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env/llmd_pool_metrics_demo.rs). The triggered workflow currently enumerates `glb`, `static-weighted`, `combined-site`, and `llmd-pool-metrics`; adding a new qualification requires updating its choices **and** all selection-dependent setup, run, verification, diagnostics and artifact branches—not just the dropdown. Existing qualifications do not jointly prove the #136 acceptance contract.

Sources: [`xtask env` CLI](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env.rs), [triggered workflow](https://github.com/praxis-proxy/grid/blob/main/.github/workflows/triggered-integration-test.yaml), [release checklist](https://github.com/praxis-proxy/grid/blob/main/docs/release.md).

## 4. Proposed architecture and ownership

```text
Authenticated client request
    |
    v
Gateway request-time routing adapter (each replica)
    |-- Resolve trusted logical scope + optional session header/cookie
    |-- Load ONE accepted/serving routing snapshot
    |-- Enforce request auth / capability / global hard constraints
    |-- If shared enabled: atomic store read / get-or-create / conditional rebind
    |      |   (keyed opaque session digest; candidate ID + generation + TTL)
    |      +--> Shared Valkey / Redis primary
    |-- Validate winning candidate against the loaded snapshot
    |-- If unbound: invoke EXISTING eligible-candidate selector once
    |-- Attach selected stable ID and serving revision to trusted routing context
    v
Existing provider gateway / selected destination

Grid operator + signal plane ---> versioned topology and signal-derived state
                                    (never a session-value store)
```

**Responsibility boundaries:**

1. **Grid control plane** owns candidate membership, stable ID, advertised capability, administrative admission, eligibility-relevant signal/policy state, and versioned publication. It never reads a session ID and never puts bindings into CRDT/SWIM.
2. **Gateway request-time adapter** owns trusted session extraction, scope determination, shared store operations, revision handling, validation and route attribution. Every gateway implementation that claims this feature must implement the same state machine.
3. **Existing selection engine** remains the sole authority for selecting *new* placements among currently eligible candidates. No #136-specific score, priority or routing-mode behavior.
4. **Valkey/Redis** is a small, bounded, TTL-backed coordination store, not a policy engine or a provider health oracle.
5. **Provider gateway / EPP** continues enforcing its independent authentication, backend eligibility and serving behavior. Edge affinity is not proof of successful backend request admission.

### 4.1 Shared configuration (proposed schema, not currently supported)

Preserve the existing `session_affinity` block and its defaults. Add a mutually understood, optional backend configuration; the exact repository/schema placement can differ between the two serving adapters, but field semantics must agree.

```yaml
# Proposed gateway-filter configuration fragment — not yet executable.
session_affinity:
  enabled: true
  header: X-Session-Id                 # OR cookie, preserving existing precedence
  ttl_secs: 3600                     # idle TTL, refreshed on validated reuse
  backend:
    type: valkey                      # omitted => existing local behavior
    url_secret_ref: session-store-url # resolve via deployment Secret, not overlay
    key_secret_ref: session-hmac-key  # 32+ bytes; shared across replicas
    namespace: production-gateway   # logical routing scope, not replica name
    operation_timeout_ms: 250        # example bounded setting, not a current default
    outage_policy: stateless         # alternative: reject
```

Use standard secret/key-file patterns already supported by the deployment. Do not accept raw Valkey passwords or HMAC keys inside Grid's `ConfigMap` routing overlay. Validate TLS, ACL, timeouts and optional Redis topology at startup. The `backend` block is an opt-in **deployment policy**, not an operator-generated candidate field.

**Backward compatibility:** absent `session_affinity`, disabled affinity, and enabled affinity with **no `backend`** must preserve existing local behavior, including the current fixed TTL in that compatibility mode unless explicitly changed in a documented separate migration. `backend.type=valkey` opts into the new sliding-idle shared contract. If scope/auth/key material cannot be resolved securely, reject configuration rather than falling back silently to unscoped keys.

### 4.2 Namespace and stable identity

Define the binding namespace from trusted, canonical inputs:

```text
protocol/version
logical grid ID and logical gateway/routing scope
verified tenant / subject isolation boundary (where available)
capability kind and requested capability/model identifier
session identifier from configured header OR cookie
```

The scope must **not** include the gateway replica name or an ephemeral Pod/Service address, because traffic must share bindings across replicas. It must **not** collapse distinct tenants or different models/capabilities that happen to reuse an `X-Session-Id`. Derive a verified tenant identity *after* auth; in deployments with no tenant identity, explicitly use a configured operator-owned isolation namespace and document the weaker trust boundary. Do not accept arbitrary caller-supplied tenant/scope headers as verified identity.

Suggested storage key:

```text
grid:affinity:v1:<base64url(HMAC-SHA256(secret, canonical_length_delimited_scope_and_session))>
```

Length-prefix or unambiguously encode each field before HMAC; raw string concatenation can produce ambiguous tuples. Avoid raw session values, cookies, model names and credentials in keys, Redis command logs, debug traces or evidence. Use a per-deployment HMAC secret independent of provider credential and stored-response tag secrets. Plan dual-key reads and a bounded migration window when rotating the HMAC key (or intentionally expire old bindings and document the rotation-induced rebind).

Stored value (versioned, bounded, with strict parser):

```json
{
  "schema": 1,
  "stable_id": "<opaque validated candidate identity>",
  "version": 12,
  "eligibility_epoch": 74,
  "created_at_ms": 0
}
```

Illustrative only: omit timestamps if not needed; never log the actual value. The `version` is a CAS generation. `eligibility_epoch` is a **proposed** monotonic hard-eligibility fence, not an existing field: either implement/derive a provably comparable epoch for the routing scope or substitute an explicit safe stale-revision rule as described below. Set an **actual Redis/Valkey TTL**, not merely a timestamp inside a permanent value. Put hard caps on key/value size, timeouts and backend memory policy; document eviction-induced rebind behavior.

### 4.3 Eligibility and signal compatibility

For a particular request and the single loaded serving snapshot, distinguish *hard eligibility* from *soft preference*. Store operations must never interpret a score as authorization.

| Change / observed state | Existing valid session | New session / new binding | Explanation |
|---|---|---|---|
| Score, rank, relative weight, locality preference, load ordering changes | **Retain** candidate | Selector sees new preference | Soft selection changes are not invalidation. |
| Sample missing/stale, provider unmeasured but still eligible under current policy | **Retain**, subject to current hard gates | Follow normal candidate eligibility/selection rules | Do not fabricate a health failure solely from absence of a *soft* signal. |
| Administrative `existing_only` drain / policy's equivalent | **Retain** if otherwise eligible | **Exclude** | Already-bound is an explicit exception to *new-session admission*, not to health/authorization. |
| `new_and_existing` reappears | **Retain** still-valid binding | Candidate may again receive new bindings | No automatic failback for established sessions. |
| Health failure or explicit exclusion | **Rebind or refuse** | **Exclude** | Hard availability gate. |
| Removed candidate or changed stable identity | **Rebind or refuse** | Only current candidate set | No dangling destination. |
| Tenant authorization revoked, capability/model no longer authorized, sovereignty/isolation/other hard policy restriction | **Rebind to authorized target or refuse** | Enforce policy first | Neither an old binding nor a healthy target overrides authorization. |
| Authoritative empty/no-route revision | **Refuse**; do not use cached target | **Refuse** | Must preserve Grid's fail-closed withdrawal contract. |
| Global admission/shedding gate applying to the request | **Honor the gate** | **Honor the gate** | Do not turn a shared pin into an overload bypass. |
| Store unavailable | Follow explicit outage policy, **no claim of shared stickiness** | Same | Never silently run independent local shared-mode maps. |

**Implementation rule:** expose a common predicate, conceptually `can_serve_existing(request, candidate, snapshot, policy)` and `can_accept_new(...)`, using **the actual current gateway policy contract**. A reused session may keep `existing_only`, but *not* a merely recognizable candidate that violates current policy. Do not build a second, weaker routing-policy evaluator into the session store.

**Ordering:** authorization/capability and hard gating → shared lookup → snapshot validation → either reuse or new-candidate selection → atomic commit/replace → revalidate returned winner → route. Local prefix/cache-locality optimization may participate in **new-candidate selection only**; it must not displace a valid explicit session pin. Stored-response/conversation IDs are higher-priority explicit locators to state that may not be movable: obey their existing pin semantics and do not overwrite them with an arbitrary session binding.

### 4.4 Mixed serving revisions (must not omit)

The Grid overlay revision is a content digest; `A < B` is **not** a meaningful interpretation. Signal updates can also produce new in-memory snapshot orderings independently of topology publication. Two replicas may temporarily disagree on hard eligibility after a drain, removal, policy update or reload. If replica 1 rebinds from A to B and replica 2, still on an old snapshot, decides B is missing, it must **not** blindly swap B back to A.

Preferred production-grade contract:

1. Add or reuse a **monotonic, per-logical-scope hard-eligibility generation** emitted with serving policy, increasing on hard membership/admission/authorization changes (not merely a soft score movement). Validate it in the overlay and keep it tied to the serving snapshot.
2. Store the generation used by the writer alongside the bound candidate. A reader behind the stored generation **must not mutate** the binding. It can wait briefly for a new local snapshot, retry once or return a clearly identified transient error.
3. At an equal or newer hard generation, validate the candidate against the local serving snapshot. For invalid bindings, perform a generation-fenced CAS to a new eligible candidate. Only newer/equal state may replace it.
4. Retain content digest/revision for *evidence and correlation*, but never use the digest as a numerical generation.

If introducing that generation is unacceptable for the first release, explicitly reduce the guarantee: after inconsistent snapshots are detected, **refuse/retry** rather than trying to guess which overlay is newer; gate a hard rebind until the candidate/snapshot relation is demonstrably current. A globally strong assertion of “no stale-policy repinning” cannot be made from unordered revision digests alone. Qualify this migration window instead of hiding it with eventual convergence assumptions.

### 4.5 Atomic store semantics and state machine

Use Redis-native atomic operations (one Lua script per key, or a proven equivalent transaction). Do **not** implement read → arbitrary application selection → unconditional `SET`, nor separate `DEL` and `SET` for invalidation. Keep scripts small, bounded and self-contained. `SET NX PX` suffices for simple creation only if the loser *always reads and routes the winner*; full CAS/version checks require more.

**Proposed store operations:**

- `lookup(key)`: return bounded/decode-validated value and TTL. A hit is *advisory* until current snapshot validation. A corrupt value is handled as a store error (observable), not trusted or sent upstream.
- `get_or_create(key, desired_id, hard_epoch, ttl)`: when missing, atomically insert with TTL and generation; when present, return the existing record and **do not overwrite**. Caller validates the returned ID and retries boundedly if it is now disallowed.
- `touch_if_match(key, stable_id, version, hard_epoch, ttl)`: refresh expiry only after the binding is confirmed valid **and** still matches. Do not let a stale read extend a replaced record. Default shared-mode idle semantics: **successful validated reuse refreshes TTL**, as does first placement after the store accepts it. Invalid, unserved, or rejected requests do not refresh.
- `compare_replace(key, old_id, old_version, old_epoch, new_id, current_hard_epoch, ttl)`: atomically replace only the observed binding/version if current generation is not older; return the actual winner on conflict. A replacement must meet **new-session eligibility**, never target `existing_only`. If there is no eligible replacement, do not delete/re-create blindly; return an explicit routing failure and allow a later request to re-evaluate.
- `compare_delete` if operationally necessary: delete only a specific observed version, never a newer winner.

Suggested gateway pseudocode (policy and transport names are conceptual):

```rust
async fn resolve_session_route(request: &Request, snapshot: &ServingSnapshot) -> RouteResult {
    enforce_auth_capability_and_global_gates(request, snapshot)?;
    if snapshot.is_authoritative_no_route() { return Err(NoRoute); }
    let Some(scope_key) = trusted_scoped_session_key(request)? else {
        return select_new_eligible(request, snapshot);
    };

    for _ in 0..MAX_CAS_ATTEMPTS {
        let observed = store.lookup(&scope_key).await?;
        if let Some(binding) = observed {
            if snapshot.hard_epoch() < binding.hard_epoch() {
                return Err(ServingRevisionBehind); // no downgrade/re-pin
            }
            if let Some(candidate) = snapshot.by_stable_id(&binding.stable_id)
                .filter(|c| can_serve_existing(request, c, snapshot))
            {
                if store.touch_if_match(&scope_key, &binding).await? {
                    return Ok(route_with_revision(candidate, snapshot));
                }
                continue; // another replica replaced it
            }
        }

        let candidate = select_new_eligible(request, snapshot)?;
        let winner = match observed {
            Some(old) => store.compare_replace(&scope_key, &old, candidate, snapshot.hard_epoch()).await?,
            None => store.get_or_create(&scope_key, candidate, snapshot.hard_epoch()).await?,
        };
        if let Some(current) = snapshot.by_stable_id(&winner.stable_id)
            .filter(|c| can_serve_existing(request, c, snapshot))
        {
            return Ok(route_with_revision(current, snapshot));
        }
    }
    Err(BoundedConflictOrRevisionLag)
}
```

In actual code use owned/borrow-safe types, one consistent async deadline, typed errors and the existing request-context/filter APIs. Handle a race between final validation and an overlay swap by tying the decision to the **loaded snapshot** and recording that snapshot's serving revision. A request already in flight cannot retroactively migrate, but the next request must see the new constraints. Do not make a synchronous Redis call from the request worker.

### 4.6 Outage, timeout, restart and recovery

Recommended shared-mode outage choices:

- **`stateless` (default for general traffic):** after a bounded timeout, continue normal authorized *new-request* selection, **without writing a local pseudo-shared binding**, and emit `shared_store_unavailable`. This preserves availability but offers **no affinity guarantee** for requests in the outage. Existing-only candidates do not receive new placement when shared state cannot be verified. No stale local cache is treated as authoritative.
- **`reject` (opt-in for workloads requiring strict stickiness):** return an explicit retryable service failure rather than risk moving a session (a bounded `503`/`Retry-After`, following gateway conventions). Never bypass authorization or invent route provenance.

On recovery, resume reading the persistent winner. A request routed statelessly during an outage may have gone elsewhere; do not pretend the old binding was honored during that interval. Record the distinction as a documented, observable interruption of affinity. A restarted gateway must reacquire its binding from the store. A restarted shared store with no persistence resembles expired bindings and must be observable; availability/replication durability is an operator-controlled deployment choice.

Set bounded connection/request budgets and fail-fast circuit/backoff behavior. Use auth/TLS secrets, scoped ACLs, and explicit primary semantics for atomic scripts. A configured “shared” backend must be reachable from *both* replicas and must not be silently replaced by independent primary instances during failover.

## 5. Concrete work plan by repository/component

### Workstream A — Contract and API (Grid + Praxis AI)

1. Add `docs/architecture/shared-session-affinity.md` describing this feature as cross-cutting routing behavior, not a selection mode; link from `docs/routing.md` and from the signals, draining, prefix-affinity and overlay docs where relevant.
2. Define versioned store wire/key schema, canonical namespace, ID/scope limits, HMAC rotation, TTL, outages, hard/soft policy matrix, revision consistency and metric vocabulary.
3. Agree how the logical scope and hard-eligibility epoch (if adopted) are produced and carried without allowing request headers to spoof them. A schema/CRD change should be additive and generated artifacts regenerated when required.
4. Add strict validation for stable IDs, uniqueness, resolved scope, secret material, and any new backend config. Continue accepting historical overlays and valid empty revisions.

### Workstream B — Praxis AI request path (primary existing session implementation)

1. Refactor local `SessionAffinity` behind a trait/enum providing local and async shared storage, **without changing the default local semantics**. Keep binding orchestration around `select_and_route`; do not reproduce group/picker selection logic in the store.
2. Add Valkey-backed atomic get-or-create, CAS replace, conditional sliding TTL touch, bounded retries, outage policy, metrics, scrubbed logging and config validation.
3. Resolve scope from authenticated request identity and logical gateway namespace. Add credential mount/Secret wiring, TLS/ACL configuration and HMAC key handling.
4. Ensure a session only claims `reused` when shared validation really succeeded; add distinct `new`, `rebound`, `stateless_fallback` and `store_unavailable` outcomes in metadata without changing legacy status semantics unexpectedly.
5. Preserve provider-hop request provenance and serving revision for each decision. Validate that overlay reload and empty no-route cannot be overridden by a stored binding.

Source seam: [`filters/src/routing/intelligent_route.rs`](https://github.com/praxis-proxy/ai/blob/main/filters/src/routing/intelligent_route.rs), [`filters/src/routing/overlay.rs`](https://github.com/praxis-proxy/ai/blob/main/filters/src/routing/overlay.rs), [`filters/src/routing/metrics.rs`](https://github.com/praxis-proxy/ai/blob/main/filters/src/routing/metrics.rs), [`docs/filters/intelligent_route.md`](https://github.com/praxis-proxy/ai/blob/main/docs/filters/intelligent_route.md).

### Workstream C — Grid-owned gateway integration (needed for a global feature claim)

1. Wire the same contract to the Grid-owned `grid_site_route` request path, using its existing immutable `RouteSnapshot`, published `stable_id`, `AdmissionState` and hard route checks. **Do not** treat `prefix_affinity` or `pin.rs` as an existing implementation of explicit shared session binding.
2. Avoid changing the signal reader or selector merely to support affinity. On a valid hit, bypass the *soft* select/spread decision; on a miss/invalidation, invoke the existing selector on eligible candidates, then commit the winner atomically.
3. Ensure request-body and stored-state-tag behavior preserves existing priority; never make an unrelated session pin override a tagged state owner.
4. Expose/retain the existing response attribution (`x-grid-site`/`x-grid-backend` where applicable) and serving revision/candidate metadata for qualification.
5. Integrate with chart/deployment config in [`charts/praxis-gateway`](https://github.com/praxis-proxy/grid/tree/main/charts/praxis-gateway) and the current operator-managed serving configuration without storing secrets in the routing overlay. Document supported versions/feature availability for both serving paths.

Source seam: [`route.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/route.rs), [`snapshot.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/snapshot.rs), [`serving.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/serving.rs), [`descriptor.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/descriptor.rs).

**Delivery sequencing:** a staged implementation may land the Praxis AI adapter first, but it must be described as support for that serving path, not blanket “Grid shared session affinity,” until the other supported gateway path implements and qualifies the same semantics. Do not force a large common crate if that would create a brittle cross-repository dependency; a small versioned contract and conformance fixtures may be safer.

### Workstream D — Deployment and operations

1. Provide a documented shared Valkey endpoint/Secret binding and mTLS/ACL options; restrict NetworkPolicy to consumer gateways.
2. Define a logical namespace identical across replicas but isolated across tenants/environments. Verify HMAC key distribution and safe rotation.
3. Validate that rollout/restart leaves store state available, and that changing candidate IDs intentionally triggers safe rebinds.
4. Publish dashboard/runbook guidance for backend error rate, latency, affinity hit/rebind, stateless fallback, store occupancy/eviction, and revision lag. No session-value labels.
5. State Redis/Valkey compatibility/version expectations, primary/replica consistency requirement, persistence tradeoffs and how to disable shared mode safely.

## 6. Required automated validation

### 6.1 Deterministic unit and integration tests

| Area | Tests that must exist |
|---|---|
| Scoping & privacy | Same session across gateway replicas in the same logical scope yields same digest; different verified tenants, models/capabilities, gateways or grids do not. Keys/logs/metrics contain no raw IDs. Key rotation behavior. |
| Atomic first request | Hundreds of concurrent first requests targeting different replicas; exactly one value wins; **every successful request** uses the winner. Repeat across redis-rs connection recreation. |
| CAS invalidation | Multiple concurrent hard-invalidating readers; only one replacement generation wins. Losers follow the returned winner; a delayed old write cannot overwrite it. |
| TTL | Fake clock for local compatibility; real Valkey TTL integration for insertion, validated-reuse refresh, expiry, failed-validation no-refresh, and conditional-touch-after-replace. |
| Eligibility | Bound `existing_only` reused; unbound never placed there; `none`, removal, model/capability mismatch, unauthorized, no route, hard shedding and global gates cannot be bypassed. |
| Signals | Ordering/score/weight/pressure as soft preference does not move an eligible binding; unbound traffic sees updated selection. Missing/aged metrics obey underlying policy, not a new affinity-only exclusion. |
| Overlay versions | Valid changed/empty revision, invalid reload LKG, new stable IDs, provider withdrawal/restoration, replica with older hard epoch never re-pins backward. |
| Store failures | Timeout, refused connection, auth/TLS failure, malformed value, pool exhaustion, store restart; both outage policies and recovery observable. |
| Compatibility | Shared backend absent/disabled => unchanged prior single-process behavior and configuration. |
| Stored state | Tagged Responses/conversation routing remains authoritative and separate from session binding; prefix index stays local. |

Integration tests must exercise actual atomic commands against a real Valkey/Redis-compatible instance; a mocked `Mutex<HashMap<...>>` is not proof of cross-process coordination.

### 6.2 Dedicated Kind routing xtask — required deliverable

**Proposed command (does not exist yet):**

```console
cargo xtask env run-grid-shared-session-affinity-qualification \
  --forge-config tests/e2e/topologies/grid-shared-session-affinity/forge.yaml \
  --full --teardown --evidence-dir "$EVIDENCE_DIR"
```

Create `crates/xtask/src/env/shared_session_affinity_qualification.rs` (or equivalent), register it in [`crates/xtask/src/env.rs`](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env.rs), and check in `tests/e2e/topologies/grid-shared-session-affinity/{forge.yaml,README.md,configs/,resources/,verify...}` as appropriate. Reuse established Forge/Kind and cross-cluster helpers rather than copying a large qualification runner. **The xtask must create the cluster(s) itself**; calling `select_candidate` directly or querying a manually installed Valkey is not an E2E qualification.

**Minimum runtime topology:**

- At least **two independent running consumer gateway processes/replicas**, explicitly addressable for alternating calls; a shared front-door Service alone is insufficient to prove both served the same session.
- At least **two simultaneously eligible destinations** with distinguishable, trusted provider attribution and stable IDs.
- A real **shared Valkey/Redis-compatible store**, mounted credentials, per-run ACL/TLS configuration as applicable, and two gateway consumers using precisely the same logical binding namespace.
- A Grid operator and versioned routing/serving config; deterministic signal-producing backend(s) or test controllers so the test can change *observed serving signals* through the deployed collection path.
- A real test client issuing requests through HTTP gateway endpoints, verified from response attribution and provider-side counters/logs. No untrusted client-provided upstream-attribution headers count as evidence.
- Provision and tear down only **run-owned** Kind clusters, Docker network, namespaces, secrets, deployments and store data. Use a validated unique run ID and an inventory, following the safer run-identity ideas in the existing token-quota qualification. Never invoke a blanket teardown of unrelated Kind clusters.

Recommended fixtures: start from [single-cluster multi-gateway](https://github.com/praxis-proxy/grid/tree/main/tests/e2e/topologies/grid-single-cluster-multi-gateway) for two consumer processes, reuse the [token-quota topology](https://github.com/praxis-proxy/grid/tree/main/tests/e2e/topologies/grid-token-rate-limit) for Valkey/NetworkPolicy, and borrow live signal-convergence methods from [llm-d metrics](https://github.com/praxis-proxy/grid/tree/main/tests/e2e/topologies/grid-llmd-pool-metrics). Keep this a **new, coherent, routing-agnostic qualification**, not an extension that only exercises one selection policy.

**Scenario matrix (full mode mandatory for release):**

| Phase | Runtime action | Required assertion |
|---|---|---|
| 0. Bootstrap | Deploy Kind, gateways, destinations, Valkey; wait for published/accepted/serving revision agreement. | All components ready, candidate IDs unique, store reachable from both gateways. |
| 1. Create | Send first request for session S to gateway A. | Store has one opaque binding; response attributes the selected stable destination and serving revision. |
| 2. Alternate | Repeat S in A→B→A→B order. | Same stable ID while eligible; record actual serving gateway for each call. |
| 3. Restart | Delete/recreate gateway A process; send S to restarted A and B. | Same stable ID; no reuse of local memory needed. |
| 4. New sessions | Send several distinct unbound sessions through both gateways. | They remain eligible for normal selector distribution; no all-session pinning to S. No fixed ratio assertion unless separately configured and justified. |
| 5. Signals change | Drive measurable load/ranking change and observe new signal generation/snapshot. | S stays bound, while new sessions can see changed preference; no claim that score change alone invalidates binding. |
| 6. Drain | Make S's destination `existing_only`, wait for both serving snapshots to agree. | S continues on it; unbound sessions never create a binding there. |
| 7. Hard removal | Make S's destination excluded, unhealthy or absent; converge hard eligibility. | Exactly one bounded CAS rebind to another eligible destination, or explicit failure if none; both replicas agree on winner. |
| 8. Policy/no-route | Exclude all candidates with authoritative empty revision. | Both fresh and previously bound sessions fail; no stale forwarding. Restore valid revision and verify recovery. |
| 9. TTL | Use a short test TTL; make verified touches, then wait beyond expiry without touches. | TTL slides only on valid reuse; after expiry a new normal selection is permitted. |
| 10. First-request race | Coordinate a barrier that launches simultaneous first requests for a fresh S2 to A and B. | Atomic first-writer-wins and **each successful request** reaches that winning destination; do not accept just final key equality. |
| 11. Invalidating race | Concurrently invalidate/rebind an established session on both replicas. | No conflicting active binding / stale-revision rollback; bounded retries and final agreement. |
| 12. Store outage | Block/stop Valkey; repeat S on both gateways under configured outage policies. | `stateless` routes as new/unbound and declares degraded guarantee; `reject` fails explicitly. No independent local “shared” success claim. |
| 13. Recovery | Restore Valkey; issue S from both gateways, including after a rolling gateway restart. | Recovered persistent winner is read and validated; stale/mismatched winner is safely rebound. |
| 14. Security | Test cross-tenant same session, forged internal headers, Redis auth/NetworkPolicy and secret redaction. | Strict scope separation and negative controls; evidence contains no session values or credentials. |
| 15. Cleanup | Restore injected faults, delete only owned resources. | Teardown report and resource-inventory comparison; unrelated clusters untouched. |

**Mixed-revision test is mandatory:** stall one gateway on an older hard-eligibility revision, remove/rebind on the other, then resume the stale one. It must refuse/retry until current, **not reverse the rebind**. Confirm its evidence records both replicas' serving revisions. Distinguish this from a soft signal-only update, which is allowed to produce different rankings without forcing a session move.

Quick mode may run bootstrap, creation, alternation, restart, and an atomic race for developer feedback, but **must not be labeled release qualification**. Full mode must run all applicable phases. An omitted prerequisite is `BLOCKED` or `FAIL`, not a skipped phase silently counted as a pass.

### 6.3 Evidence contract

Generate `summary.json`, `SUMMARY.md`, `scenarios.jsonl` (or equivalent structured records), environment/image manifest, revision timeline, raw-but-sanitized command results, provider-attribution counters, Valkey health/failure events and teardown inventory.

Each request record should identify **phase, generated test correlation ID, serving consumer replica, opaque session alias (e.g. `session-1`, not its actual value), stable destination ID or its keyed digest, serving routing revision, binding outcome, store status, HTTP status and expected outcome**. For live signals, record observed signal/snapshot or policy generation, not merely the injected configuration. The xtask may hold random session values in process memory to send test traffic; they must never be printed, persisted in a file, captured by `curl --verbose`, included in failed command lines or written into a ConfigMap. Scrub HTTP dumps (`Cookie`, `Authorization`, `X-Session-Id`) and store snapshots before writing evidence. A check that scans evidence for generated secret canary values should be a **required assertion**.

Return nonzero if any required assertion or cleanup precondition fails. Preserve the first failure and non-2xx response rather than masking them through indefinite retries. Record image digests / IDs from running pods and their matching source commits; enforce source-matched Grid Operator / Grid-owned Gateway and appropriately feature-enabled Praxis AI builds for each qualified serving path.

### 6.4 CI integration and the `docs/releases.md` request

The live repository has [`docs/release.md`](https://github.com/praxis-proxy/grid/blob/main/docs/release.md) **(singular)**, not `docs/releases.md`. Make the following changes:

1. Add a dedicated **Shared session affinity — multi-replica** row to the canonical `docs/release.md` **Integration qualification checklist**, including the command above, topology path, release qualification classification, triggers (“session affinity, shared-store, admission, overlay, live signals, identity, gateway rollout”), and topology README.
2. Add that command to the canonical one-line release qualification command stack and a details row describing images, evidence, runtime and run-owned cleanup.
3. Update the coverage-gaps section to distinguish this **new proof** from the current local-affinity demos and from any serving path not yet qualified.
4. Because the requested path is specifically **`/docs/releases.md`**, create that file as a very short **pointer to `docs/release.md#integration-qualification-checklist`** (or change the canonical name in a separate, repo-wide link migration). **Do not maintain duplicated release tables**.
5. Update the [`triggered-integration-test.yaml`](https://github.com/praxis-proxy/grid/blob/main/.github/workflows/triggered-integration-test.yaml) manual qualification choices and every qualifying setup/image/runner, diagnostics, success/summary and artifact branch if this qualification will be runnable from that workflow. Add immutable, source-matched image inputs and bounded runtime/teardown.
6. Document prerequisites and isolation in the topology README and link it from [`docs/architecture/ci-kind-e2e.md`](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/ci-kind-e2e.md). Ensure locally invoked release command actually provisions its own Kind topology.

**Suggested canonical checklist row to add (proposal, not an existing command):**

```markdown
| Shared session affinity across gateway replicas | `cargo xtask env run-grid-shared-session-affinity-qualification --forge-config tests/e2e/topologies/grid-shared-session-affinity/forge.yaml --full --teardown --evidence-dir "$EVIDENCE_DIR"` | `tests/e2e/topologies/grid-shared-session-affinity/forge.yaml` | Release qualification | Session affinity, shared-store, candidate identity, admission, overlay, signals, rollout or consumer routing changes | [README](../tests/e2e/topologies/grid-shared-session-affinity/README.md) |
```

## 7. Suggested implementation sequence and review gates

| Stage | Outputs | Gate before next stage |
|---|---|---|
| **1. Contract** | Written eligibility matrix, keying/scope rules, hard-revision fencing decision, outage behavior, backwards-compatibility semantics, conformance vectors. | Security and both serving-path maintainers agree; no ambiguous “signal changed, therefore fail over” rule. |
| **2. Store primitive** | Small async Valkey adapter, atomic scripts/CAS, conditional TTL, typed errors, integration tests with real store. | Concurrent cross-process creation and replacement, restart, expiry, timeout, ACL and privacy tests pass. |
| **3. Gateway adapters** | Existing AI routing integration; Grid-owned gateway integration if claimed; deployment configuration; metadata/metrics. | Same conformance suite passes for both; stable IDs and serving revisions attributed correctly; valid empty revision respected. |
| **4. Operator/serving contract** | Any necessary hard-eligibility generation, overlay parser, chart and secret mounting updates; schema docs. | Mixed-revision old/new replica tests fail safely; no accidental provider-hop/header trust regression. |
| **5. Kind qualification** | New end-to-end topology, xtask, failure injection, sanitized evidence and run-owned cleanup. | All full-mode phases pass from a clean checkout with source-matched images, not a manually prepared cluster. |
| **6. Release integration** | `docs/release.md`, `docs/releases.md` pointer, topology README, CI workflow, metrics/runbook. | Release matrix includes the xtask; CI/manual invocations produce verifiable evidence and no leaked secrets. |

### Definition of done

- [ ] Same eligible, bound session is routed to one **stable destination** across two real gateway replicas and a replica restart.
- [ ] Distinct new sessions continue to use the **existing routing selector**, independent of its score/weight/strategy.
- [ ] Changes to soft signals or relative rankings do **not** disturb an eligible binding.
- [ ] `existing_only` preserves already-bound sessions but never admits a newly bound one.
- [ ] Removal, health failure, hard authorization/policy changes, no-route revisions and applicable global admission gates are respected.
- [ ] First placement and invalidation are **atomic**, with a defined mixed-revision fence and bounded retries.
- [ ] TTL, scope isolation, HMAC rotation, store outage/recovery and no-backend compatibility are documented and tested.
- [ ] No raw session/cookie/credential in keys, logs, metrics or evidence; Redis/Valkey uses scoped auth and TLS as configured.
- [ ] A new **self-provisioning Kind routing xtask** exercises the full matrix and returns meaningful evidence and cleanup status.
- [ ] The qualification is in **`docs/release.md`**, with a `docs/releases.md` pointer satisfying the requested path; optional triggered-workflow support is fully wired.
- [ ] If only one serving gateway implements the feature initially, product/docs/test claims state that limitation plainly until parity lands.

## 8. Explicit non-goals and remaining decisions

**Non-goals:** replicating session values via SWIM/CRDT; sharing per-process prefix-cache indexes; storing prompts/responses/KV caches; reimplementing the scoring/selection engine; providing authorization via knowledge of a session key; pinning stored Responses/conversation resources to the wrong owner; enforcing cross-request ordering or exactly-once inference execution.

**Decisions that should be made before code changes:**

1. **Hard-revision safety:** introduce a monotonic, per-scope eligibility epoch, or use a demonstrably safe stale-revision retry/refusal rule. The former provides a stronger, easier-to-test contract and is recommended.
2. **Outage policy:** this proposal recommends configurable `stateless`/`reject`, with stateless as the general-availability default; security-sensitive workloads can opt into rejection. Never substitute local affinity while reporting a shared hit.
3. **TTL migration:** preserve fixed-TTL behavior for existing local deployments; use sliding-idle TTL in shared mode. Document this explicitly to avoid a silent behavior change.
4. **Feature breadth:** deliver the AI existing-affinity adapter first if expedient, but qualify the Grid-owned live-signal gateway separately before making globally scoped product claims.
5. **Identity and tenancy:** use verified identity/context, not an unauthenticated `X-Tenant-*` header; configure an explicit namespace where no verified tenant is available.
6. **Backend guarantees:** choose supported Redis/Valkey deployment topology (primary consistency, TLS, credentials, persistence) and enforce bounded request latency; the store cannot be eventually consistent for writes.

## 9. Review reference index

**Primary request:** [Grid issue #136](https://github.com/praxis-proxy/grid/issues/136).

**Grid policy/routing:** [routing guide](https://github.com/praxis-proxy/grid/blob/main/docs/routing.md) · [overlay & revision contract](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/routing.md) · [draining](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/provider-draining.md) · [signals](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/signals.md) · [prefix/stored-state distinction](https://github.com/praxis-proxy/grid/blob/main/docs/architecture/prefix-affinity.md).

**Grid runtime:** [Grid gateway route](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/route.rs) · [snapshot](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/snapshot.rs) · [descriptor](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/descriptor.rs) · [serving reload](https://github.com/praxis-proxy/grid/blob/main/crates/gateway/crates/ai-grid-filters/src/serving.rs) · [operator overlay](https://github.com/praxis-proxy/grid/blob/main/crates/operator/src/resources/routing_overlay.rs).

**Praxis AI runtime:** [session affinity & selector integration](https://github.com/praxis-proxy/ai/blob/main/filters/src/routing/intelligent_route.rs) · [overlay semantics](https://github.com/praxis-proxy/ai/blob/main/filters/src/routing/overlay.rs) · [filter docs](https://github.com/praxis-proxy/ai/blob/main/docs/filters/intelligent_route.md) · [Valkey connection patterns](https://github.com/praxis-proxy/ai/blob/main/filters/src/token_rate_limit/valkey/connection.rs).

**Qualification:** [xtask command registration](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env.rs) · [multi-gateway Kind runner](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env/single_cluster_multi_gateway_qualification.rs) · [Valkey Kind runner](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env/token_rate_limit_qualification.rs) · [live signal Kind runner](https://github.com/praxis-proxy/grid/blob/main/crates/xtask/src/env/llmd_pool_metrics_demo.rs) · [triggered workflow](https://github.com/praxis-proxy/grid/blob/main/.github/workflows/triggered-integration-test.yaml) · [canonical release checklist](https://github.com/praxis-proxy/grid/blob/main/docs/release.md).

---

**Bottom line:** Treat #136 as a **global session-binding invariant over the currently authorized candidate set**. The route/signal selector may change; the bound identity stays while hard policy allows it. The hardest work is coordinating first-use and invalidation across replicas—and proving that behavior with mixed revisions, realistic signal changes, real requests and a self-contained Kind xtask.
