# Gateway-to-gateway E2E extraction map

The E2E may be implemented as a single validation branch first. After the demo
passes, split the work into upstream PR-sized changes using this map.

## Candidate upstream PR stack

| Target | Purpose | E2E evidence to extract | Production prompt status |
| --- | --- | --- | --- |
| G2G-01 peer identity | Expose verified downstream mTLS peer identity to HTTP filters. | `TlsPeerIdentity` populated from `SslDigest` in `request_filter/mod.rs`; `grid_ingress_trust` reads `ctx.peer_identity` to accept/reject. E2E assertions 15-18 prove trusted/untrusted org matching. | **Validated by G2G-E2E-02.** Production prompt drafted in `claude-code-prompts.md`. Files: `filter/src/context.rs`, `protocol/src/http/pingora/context.rs`, `protocol/src/http/pingora/handler/request_filter/mod.rs`. |
| G2G-02 ingress trust | Validate trusted peer identity on grid ingress; reject missing or untrusted peers. | `grid_ingress_trust` filter rejects CA-valid cert with wrong org (403). Unknown-CA cert is rejected by mTLS. Trusted org accepted. Config rejects empty trusted_peers and empty match fields at parse time. E2E assertions 17-20. | **Validated by G2G-E2E-02.** Production prompt drafted in `claude-code-prompts.md`. Files: `filter/src/builtins/http/security/grid_ingress_trust.rs`, `filter/src/registry.rs`. 10 unit tests. |
| G2G-03 site descriptor model | Add typed local site/capability/freshness route state. | Static candidate config with model/site/cluster validated at parse time. Empty/blank fields, duplicate models, oversized names, and reserved model_header prefixes are rejected. E2E assertions 22-25 prove local, remote-b, remote-c, and unknown model routing. | **Validated by G2G-E2E-03.** Production prompt drafted in `claude-code-prompts.md`. Files: `filter/src/builtins/http/ai/grid/route.rs` (config types). 9 config validation tests. |
| G2G-04 route filter | Select local or remote gateway cluster from request facts and descriptors. | `grid_route` reads X-Model header, sets `ctx.cluster` to selected cluster, rejects invalid/oversized model header values without unbounded metadata, and never uses reserved internal headers as route authority. Router preserves prior cluster selection. 17 unit tests + router preservation test. | **Validated by G2G-E2E-03.** Production prompt drafted in `claude-code-prompts.md`. Files: `filter/src/builtins/http/ai/grid/route.rs`, `filter/src/builtins/http/traffic_management/router/mod.rs`. |
| G2G-05 remote forwarding metadata | Add bounded internal metadata for gateway-to-gateway hops. | Route decision metadata written to `ctx.filter_metadata` with bounded keys/values. No request-header-based forwarding metadata in this POC. | **Partially validated by G2G-E2E-03** (metadata only; header forwarding deferred). Design-sensitive production prompt drafted in `claude-code-prompts.md`. |
| G2G-06 scoring/freshness | Prefer fresh/local/higher-score candidates deterministically. | `CapabilityKind` enum controls matching. Fresh candidates score 0, stale -100. Local preference +10. E2E assertion 27 proves fresh remote beats stale remote independent of local preference; assertion 28 proves local preference when otherwise equal. 21 unit tests including scoring. | **Validated by G2G-E2E-04.** Production prompt drafted in `claude-code-prompts.md`. File: `filter/src/builtins/http/ai/grid/route.rs`. |
| G2G-07 MCP/A2A routing | Extend route candidate extraction to existing MCP/A2A metadata. | MCP `tools/call` routes cross gateway boundary via `mcp.name` filter metadata. E2E assertion 29 proves tool routes to site-c through mTLS. A2A deferred (1 SKIP). | **MCP validated by G2G-E2E-04.** Production prompt drafted in `claude-code-prompts.md`. A2A deferred. File: `filter/src/builtins/http/ai/grid/route.rs`. |
| G2G-08 examples and docs | Add public examples, generated docs, and integration tests. | Demo configs become minimal upstream examples after POC-only code is removed. | **Planned by G2G-E2E-05.** Production prompt drafted in `claude-code-prompts.md`. |

## Extraction note template

Every meaningful E2E implementation area should include this note in the demo
handoff:

```text
Extraction target:
Validated behavior:
Files touched in E2E:
Likely upstream files:
POC-only shortcuts:
Required tests:
Config/docs impact:
Security or correctness pitfalls:
Open questions:
```

## Production prompt template

After each E2E step validates, add a production prompt to
`claude-code-prompts.md` using this shape:

```text
## UP-G2G-XX — short upstreamable title

Validated by:
- E2E task:
- Demo assertion(s):
- POC commit / diff reference:

Goal:
Implement exactly one upstreamable behavior.

Scope:
- Files/modules likely involved:
- Public config/API changes:
- Docs/examples required:

Non-goals:
- POC-only shortcuts not allowed:
- Later G2G targets not included:

Implementation notes learned from E2E:
- Pitfalls:
- Security boundaries:
- Compatibility constraints:

Required tests:
- Unit:
- Integration:
- Example config/test:
- Negative/adversarial:

Validation commands:
- make lint
- focused cargo tests
- affected integration tests
- make test when practical

Handoff requirements:
- changed files and why
- commands run and results
- open questions
- extraction link back to E2E evidence
```

## Split rules

- Do not upstream the E2E branch wholesale.
- Do not include demo scripts, mock servers, or generated cert artifacts in
  upstream PRs unless they are converted into normal examples or integration
  tests.
- Keep trust-boundary work separate from scoring work.
- Keep mTLS peer identity separate from route selection.
- Keep MCP/A2A extension separate from first inference route selection.
- Every upstream PR must follow `praxis/docs/developing/conventions.md`.

## PR breakout notes

Each upstream target with copy/paste-friendly extraction guidance.

### UP-G2G-01: peer identity

- **Upstream target name:** Downstream TLS peer identity exposure
- **Purpose:** Expose verified mTLS peer identity to HTTP filters
- **Validated demo behavior:** `ctx.peer_identity` populated from `SslDigest`, used by `grid_ingress_trust`
- **Demo assertion numbers:** 15-18 (trusted/untrusted peer org matching)
- **POC files involved:** `filter/src/context.rs`, `protocol/src/http/pingora/context.rs`, `protocol/src/http/pingora/handler/request_filter/mod.rs`
- **Likely upstream files:** Same as POC files
- **Code that should move upstream:** `TlsPeerIdentity` struct, `peer_identity` field, `peer_identity_from_ssl_digest()` helper
- **Code that is POC-only:** None — this layer is production-ready
- **Required unit tests:** Identity creation, hex digest, field validation
- **Required integration/example tests:** Filter context populated during mTLS requests
- **Security pitfalls found during E2E:** Must require non-empty cert digest before creating identity
- **Docs/config examples needed:** Generated filter docs for `TlsPeerIdentity`
- **Dependencies on previous PRs:** None
- **Explicit non-goals:** Trust policy, route selection, SAN/SPIFFE parsing

**Breakout sentence:** Break this out as the minimal protocol/filter-context plumbing PR; do not include trust policy or routing.

### UP-G2G-02: ingress trust

- **Upstream target name:** Grid ingress trust filter
- **Purpose:** Validate trusted peer identity on grid ingress; reject missing/untrusted peers
- **Validated demo behavior:** `grid_ingress_trust` accepts trusted org, rejects wrong org (403), config validation
- **Demo assertion numbers:** 17-20 (peer trust acceptance/rejection)
- **POC files involved:** `filter/src/builtins/http/security/grid_ingress_trust.rs`, registry updates
- **Likely upstream files:** Same as POC files
- **Code that should move upstream:** Full filter implementation, config validation, registry entries
- **Code that is POC-only:** None — production quality
- **Required unit tests:** Config validation (empty peers, no match fields), trust decisions (10 tests)
- **Required integration/example tests:** mTLS listener + trust filter accepting/rejecting
- **Security pitfalls found during E2E:** Empty trusted peer lists must fail at parse time
- **Docs/config examples needed:** Generated filter docs, security example config
- **Dependencies on previous PRs:** UP-G2G-01 (requires `peer_identity`)
- **Explicit non-goals:** Route selection, dynamic peer discovery

**Breakout sentence:** Break this out as the destination-gateway trust enforcement PR; it may consume peer identity but must not select routes.

### UP-G2G-03: site descriptors

- **Upstream target name:** Static site descriptor model
- **Purpose:** Define typed local site/capability/freshness route state
- **Validated demo behavior:** Config types, validation rules, local routing snapshot
- **Demo assertion numbers:** 22-25 (local/remote-b/remote-c/unknown model routing)
- **POC files involved:** `filter/src/builtins/http/ai/grid/route.rs` (config types and validation)
- **Likely upstream files:** Same route.rs file, possibly split into separate config module
- **Code that should move upstream:** Config structs, validation functions, bounded field checks
- **Code that is POC-only:** Static hardcoded snapshots should become configurable
- **Required unit tests:** Config validation (9 tests: empty fields, duplicates, oversized names)
- **Required integration/example tests:** Valid config loaded without errors
- **Security pitfalls found during E2E:** Reserved header prefixes must be blocked
- **Docs/config examples needed:** Site descriptor schema, example YAML
- **Dependencies on previous PRs:** None (pure data types)
- **Explicit non-goals:** Dynamic updates, Operator integration, SWIM distribution

**Breakout sentence:** Break this out as the static, typed routing-record model PR; it should validate records but not make route decisions.

### UP-G2G-04: grid route

- **Upstream target name:** Grid route filter
- **Purpose:** Select local or remote gateway cluster from request facts and descriptors
- **Validated demo behavior:** `grid_route` reads model header, sets `ctx.cluster`, preserves router behavior
- **Demo assertion numbers:** 22-25 (route selection), plus router preservation test
- **POC files involved:** `filter/src/builtins/http/ai/grid/route.rs`, router mod preservation
- **Likely upstream files:** Same files
- **Code that should move upstream:** Route selection logic, cluster assignment, header validation
- **Code that is POC-only:** Hardcoded capability lookup should use configurable descriptors
- **Required unit tests:** Route selection (17 tests), router preservation
- **Required integration/example tests:** Full request path with cluster selection
- **Security pitfalls found during E2E:** Model header size limits, reserved header rejection
- **Docs/config examples needed:** Generated filter docs, routing example
- **Dependencies on previous PRs:** UP-G2G-03 (requires site descriptors)
- **Explicit non-goals:** Dynamic scoring, freshness updates, A2A routing

**Breakout sentence:** Break this out as the first route-decision PR; it may select `ctx.cluster` from validated records but should not add dynamic Operator/SWIM updates.

### UP-G2G-05: forwarding metadata

- **Upstream target name:** Remote forwarding metadata
- **Purpose:** Add bounded internal metadata for gateway-to-gateway hops
- **Validated demo behavior:** Route decision metadata in `ctx.filter_metadata` (bounded keys/values only)
- **Demo assertion numbers:** Metadata logging only (no specific assertions)
- **POC files involved:** `filter/src/builtins/http/ai/grid/route.rs` (metadata writing)
- **Likely upstream files:** Same route.rs, possibly metadata validation helpers
- **Code that should move upstream:** Bounded metadata keys, safe value constraints
- **Code that is POC-only:** Static metadata — should support configurable decision context
- **Required unit tests:** Bounded key/value validation, metadata size limits
- **Required integration/example tests:** Metadata appears in logs without secrets
- **Security pitfalls found during E2E:** Must never include request bodies or client secrets
- **Docs/config examples needed:** Metadata schema, logging format docs
- **Dependencies on previous PRs:** UP-G2G-04 (requires route decisions)
- **Explicit non-goals:** Request header forwarding, client-controlled metadata

**Breakout sentence:** Break this out only after the metadata contract is accepted; it must define bounded gateway-owned context and reject client spoofing.

### UP-G2G-06: scoring/freshness

- **Upstream target name:** Deterministic candidate scoring
- **Purpose:** Prefer fresh/local/higher-score candidates deterministically
- **Validated demo behavior:** Fresh beats stale, local beats remote when scores equal
- **Demo assertion numbers:** 27 (fresh remote beats stale remote), 28 (local preference)
- **POC files involved:** `filter/src/builtins/http/ai/grid/route.rs` (scoring functions)
- **Likely upstream files:** Same route.rs file
- **Code that should move upstream:** Scoring algorithm, freshness comparison, local preference logic
- **Code that is POC-only:** Static boolean freshness should use timestamped/generation-based scoring
- **Required unit tests:** Scoring combinations (21 tests including tie-breaking)
- **Required integration/example tests:** End-to-end scoring decisions with varied freshness
- **Security pitfalls found during E2E:** Stale data must not override security boundaries
- **Docs/config examples needed:** Scoring rules documentation, freshness format
- **Dependencies on previous PRs:** UP-G2G-04 (requires route selection), UP-G2G-03 (requires descriptors)
- **Explicit non-goals:** Real-time metric collection, background discovery

**Breakout sentence:** Break this out as deterministic candidate scoring over already-validated descriptors; it must not add background discovery.

### UP-G2G-07: MCP routing

- **Upstream target name:** MCP tool routing
- **Purpose:** Extend route candidate extraction to MCP metadata
- **Validated demo behavior:** MCP `tools/call` routes via `mcp.name` filter metadata
- **Demo assertion numbers:** 29 (tool routes to site-c through mTLS)
- **POC files involved:** `filter/src/builtins/http/ai/grid/route.rs` (MCP extraction)
- **Likely upstream files:** Same route.rs, possibly MCP-specific helper
- **Code that should move upstream:** MCP metadata extraction, tool name routing
- **Code that is POC-only:** Static tool capabilities should use descriptor model
- **Required unit tests:** MCP metadata extraction, tool routing decisions
- **Required integration/example tests:** MCP tool call crossing gateway boundary
- **Security pitfalls found during E2E:** Tool names must be validated and bounded
- **Docs/config examples needed:** MCP routing config, tool capability examples
- **Dependencies on previous PRs:** UP-G2G-04 (requires route filter), existing MCP filter support
- **Explicit non-goals:** A2A routing, MCP server discovery

**Breakout sentence:** Break this out as MCP-specific route extraction using existing MCP/JSON-RPC metadata; do not claim A2A support.

### UP-G2G-08: examples/docs/tests

- **Upstream target name:** Gateway-to-gateway examples and documentation
- **Purpose:** Make gateway-to-gateway usable and maintainable
- **Validated demo behavior:** Demo configs provide examples for user-facing documentation
- **Demo assertion numbers:** All 29 assertions provide integration test patterns
- **POC files involved:** `configs/`, generated docs, integration patterns from demo
- **Likely upstream files:** `examples/configs/`, `docs/`, `tests/integration/`
- **Code that should move upstream:** Clean config examples, integration test patterns
- **Code that is POC-only:** Demo scripts, mock servers, cert generation should become normal examples
- **Required unit tests:** Example config validation
- **Required integration/example tests:** Full gateway-to-gateway example with real listeners
- **Security pitfalls found during E2E:** Examples must not include private keys or hardcoded secrets
- **Docs/config examples needed:** User guide, deployment examples, troubleshooting
- **Dependencies on previous PRs:** UP-G2G-01 through UP-G2G-07 (requires stable behavior)
- **Explicit non-goals:** Demo-specific tooling, temporary validation scripts

**Breakout sentence:** Break this out after behavior stabilizes; it should add user-facing examples and integration coverage without changing core behavior.

## Future commit workflow

When upstreaming starts, commit one PR target at a time in dependency order. Each commit/PR must include:

- Only the files for that target
- Its focused tests
- Generated docs if applicable
- One example or integration test when behavior crosses the full proxy path
- No unrelated cleanup
- No POC demo scripts/mocks/certs unless converted into normal upstream tests/examples

**Dependency order:** UP-G2G-01 → UP-G2G-02 → UP-G2G-03 → UP-G2G-04 → UP-G2G-05 → UP-G2G-06 → UP-G2G-07 → UP-G2G-08
