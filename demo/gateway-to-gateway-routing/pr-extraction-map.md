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
