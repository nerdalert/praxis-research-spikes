# Claude Code prompts: gateway-to-gateway E2E

## Global instructions for every Claude task

You are validating
[praxis-proxy/praxis#664](https://github.com/praxis-proxy/praxis/issues/664):
gateway-to-gateway connectivity, metadata, and routing.

Do not frame this as a broader platform implementation. Gateway-to-gateway
routing is a prerequisite data-plane capability named by the epic.

Repository locations:

- Spike repo:
  `/home/ubuntu/praxxis/ai-grid/praxis-research-spikes`
- E2E demo directory:
  `/home/ubuntu/praxxis/ai-grid/praxis-research-spikes/demo/gateway-to-gateway-routing`
- Existing proposal worktree:
  `/home/ubuntu/praxxis/ai-grid/prs/1-proposal/praxis`
- Preferred E2E Praxis worktree:
  `/home/ubuntu/praxxis/ai-grid/prs/gateway-to-gateway-e2e/praxis`

Before changing Praxis code, read:

- `/home/ubuntu/praxxis/ai-grid/prs/gateway-to-gateway-e2e/praxis/docs/developing/conventions.md`
- `praxis/docs/developing/type-design.md`
- `praxis/docs/operating/tls.md`
- `praxis/docs/architecture/overview.md`
- `praxis/docs/architecture/connection-lifecycle.md`
- `praxis/docs/architecture/agentic-protocols.md`
- `praxis/docs/architecture/ai-inference.md`
- `docs/proposals/00664_gateway-to-gateway-connectivity.md` if present
- `demo/gateway-to-gateway-routing/pr-stack-documentation-plan.md`

Quality rules:

- No shortcuts around trust boundaries.
- Do not accept client-supplied internal gateway headers as authority.
- Do not log prompts, API keys, cert private keys, or full request bodies.
- Do not commit, push, or open upstream PRs unless explicitly instructed.
- Current workflow priority: finish and validate the spike demo repo, including
  `demo-narrative.md`, before any upstream PR extraction work.
- Keep demo artifacts in the spike repo; keep Praxis code changes in the E2E
  Praxis worktree.
- The E2E can be monolithic while validating, but every implemented area must
  include extraction notes for later PR splitting.
- After every passing E2E task, update this file with production-ready prompts
  for the upstream PRs that the validated behavior maps to. These prompts must
  be narrow enough for one PR and must include the real pitfalls found in the
  E2E.
- After every E2E task, update the documentation artifacts required by
  `pr-stack-documentation-plan.md`. Do not hand off with only code changes.
- Run focused tests for changed Praxis crates. If a command cannot run, report
  the exact command, failure, and environmental reason.
- Before handoff, self-review your diff using the strict review standard in
  `demo/gateway-to-gateway-routing/pr-stack-documentation-plan.md`. Fix
  in-scope issues yourself and do not make unrelated refactors.
- Before handoff, run the tests required by the "Test expectations for Claude"
  section in `pr-stack-documentation-plan.md`. Do not skip focused tests for
  Praxis code changes. If a test cannot run, include the exact command, output,
  and evidence-backed reason.

## G2G-E2E-00 — prepare the E2E workspace and exact implementation plan

You are implementing the first gateway-to-gateway E2E validation task.

Goal:
Create or verify the E2E Praxis worktree and produce a concrete implementation
plan for a three-gateway local demo before writing production code.

Scope:

1. Inspect the spike docs:
   - `demo/gateway-to-gateway-routing/README.md`
   - `demo/gateway-to-gateway-routing/architecture.md`
   - `demo/gateway-to-gateway-routing/pr-extraction-map.md`
2. Inspect the proposal:
   - `/home/ubuntu/praxxis/ai-grid/prs/1-proposal/praxis/docs/proposals/00664_gateway-to-gateway-connectivity.md`
3. Verify or create the E2E Praxis worktree:
   - target path: `/home/ubuntu/praxxis/ai-grid/prs/gateway-to-gateway-e2e/praxis`
   - branch name: `dev/gateway-to-gateway-e2e`
   - base: current `nerdalert/praxis` main unless the user provides a different base
4. Inspect current Praxis support for:
   - listener mTLS;
   - upstream mTLS;
   - access to downstream peer certificate/identity;
   - filter context metadata/extensions;
   - router/load_balancer cluster selection;
   - MCP/A2A and AI inference metadata.
5. Produce a concrete `implementation-notes.md` in the demo directory with:
   - exact E2E architecture;
   - code areas that need POC changes;
   - scripts/manifests/mock servers needed;
   - expected pass/fail assertions;
   - extraction targets from `pr-extraction-map.md`;
   - risks/blockers.

Constraints:

- Do not implement the actual Praxis feature code in this task unless it is
  needed only to discover a feasibility blocker and is clearly marked as a
  scratch change.
- Do not touch `demo/praxis-ai-grid/`.
- Do not stage unrelated changes.

Validation:

- `git status -sb` in both the spike repo and the E2E Praxis worktree.
- `rg` search showing no stale broader-platform language was introduced in the
  new gateway-to-gateway demo docs.
- `git diff --check`.

Handoff:

- Summarize worktree path, branch, base commit.
- List exact files changed.
- List planned E2E assertions.
- Confirm the documentation artifacts required by
  `pr-stack-documentation-plan.md` were updated or explain why they are not yet
  applicable.
- Identify the first coding task prompt that should follow.

## G2G-E2E-01 — implement minimal local three-gateway smoke harness

Use this only after G2G-E2E-00 is reviewed.

Goal:
Create the smallest runnable local harness with three Praxis gateway configs
and local mock backends. It may fail expected gateway-routing assertions until
the POC feature code exists, but it must prove the process model, ports, cert
generation, and cleanup path.

Read `implementation-notes.md` first — it contains port assignments, cert plan,
mock backend specs, and config sketches validated against the actual Praxis
source.

Key facts from G2G-E2E-00 inspection:

- Codex review correction: on the current E2E base, Praxis router does not
  skip when `ctx.cluster` is already set. Do not rely on a `grid_route` filter
  running before router unless the POC explicitly adds skip behavior or splits
  the chain. This belongs with G2G-E2E-03/G2G-04, not the smoke harness.
- Pingora `SslDigest` contains `organization`, `serial_number`, and
  `cert_digest` from the peer certificate, but Praxis only extracts a boolean
  `downstream_tls` today. Peer identity exposure is deferred to G2G-E2E-02.
- Reserved internal headers (`x-praxis-*`, `x-mcp-*`, `x-a2a-*`) are rejected
  on client ingress before filters can observe them and stripped before
  upstream in `upstream_request.rs`.
- The `headers` filter removes explicit header names with `request_remove`; it
  does not provide wildcard stripping. In the smoke harness it is only
  defense-in-depth for future non-reserved internal names, not the primary
  protection for `x-praxis-*`.

Port plan (all on 127.0.0.1):

- Site A: public :18100, grid :18101, backends :18001-18003
- Site B: grid :18110, backends :18011-18013
- Site C: grid :18120, backends :18021-18023

Required demo assets:

- `scripts/check-prereqs.sh`
- `scripts/generate-certs.sh`
- `scripts/run-demo.sh`
- `scripts/cleanup.sh`
- `configs/site-a.yaml`
- `configs/site-b.yaml`
- `configs/site-c.yaml`
- `mocks/inference.py` — minimal OpenAI-compatible echo server
- `mocks/mcp.py` — minimal JSON-RPC MCP echo server
- `mocks/a2a.py` — minimal JSON-RPC A2A echo server

Required behavior:

- Starts site A, B, and C Praxis instances.
- Starts local mock backends.
- Generates or loads a local CA and gateway certs.
- Verifies basic local route through site A.
- Verifies direct call to a grid listener without a client cert fails.
- Emits clear "not implemented yet" failures for route-selection checks that
  require POC code.

Do not implement route feature code in this task unless G2G-E2E-00 explicitly
identified a tiny prerequisite.

## G2G-E2E-02 — implement POC peer identity and grid ingress trust

Use this after the local harness runs.

Goal:
Add enough POC Praxis behavior to expose/derive peer gateway identity and
validate trusted gateway ingress.

Task scope:

1. Add a minimal typed peer identity to Praxis request/filter context.
   - Keep this POC small and extraction-friendly for G2G-01.
   - `SslDigest` already exposes `organization: Option<String>`,
     `serial_number: Option<String>`, and `cert_digest: Vec<u8>`.
   - Do not parse SANs in this E2E task unless the organization/serial/digest
     fields are unusable. SAN parsing is a likely upstream hardening follow-up.
2. Populate the peer identity during Pingora request setup.
   - Current code only sets `ctx.downstream_tls`.
   - Main files to inspect first:
     - `filter/src/context.rs`
     - `filter/src/lib.rs` test utilities
     - `protocol/src/http/pingora/context.rs`
     - `protocol/src/http/pingora/handler/request_filter/mod.rs`
3. Add a POC `grid_ingress_trust` HTTP filter.
   - Place it under the HTTP security filters unless inspection finds a better
     existing home.
   - Register it in `filter/src/registry.rs`.
   - Config should be static and explicit. Suggested shape:

     ```yaml
     - filter: grid_ingress_trust
       trusted_peers:
         - organization: praxis-grid-e2e
     ```

     It is acceptable to include serial or digest matching if this is cleaner
     after inspecting available cert fields, but keep the POC config simple.
   - Reject when no verified peer identity exists.
   - Reject when identity does not match configured trusted peers.
   - Continue only when the peer identity is present and trusted.
   - Do not trust request headers as peer identity.
4. Update the three demo configs to include `grid_ingress_trust` on grid
   listeners only.
5. Update `scripts/run-demo.sh` to prove trusted and untrusted cases.
   - Keep the existing 17 assertions.
   - Add assertions that site B/C accept the site A client cert only when the
     configured peer identity is trusted.
   - Add an assertion that a client cert from an unknown CA is rejected.
   - If useful, add an untrusted-but-CA-valid client cert case. This requires
     generating a second client cert signed by the grid CA with a different
     organization/serial/digest and should be rejected by `grid_ingress_trust`.

Important corrections from G2G-E2E-01:

- Public client-supplied reserved headers (`x-praxis-*`, `x-mcp-*`,
  `x-a2a-*`) are rejected before filters run. Do not implement public ingress
  stripping for those reserved prefixes in this task.
- `ctx.extra_request_headers` is applied before `strip_reserved_internal`, so
  do not use `x-praxis-*` request headers as the peer identity mechanism.
- This task is not `grid_route`. Do not implement route selection, site
  descriptors, scoring, or gateway-to-gateway forwarding metadata here.
- The current router does not preserve an existing `ctx.cluster`; leave that
  for G2G-E2E-03/G2G-04.

Required assertions:

- Public listener rejects reserved internal gateway headers before filters can
  observe them.
- Grid listener requires mTLS and exposes verified peer identity to filters.
- Grid listener rejects a cert from an unknown CA.
- `grid_ingress_trust` accepts trusted site A peer identity on site B/C.
- `grid_ingress_trust` rejects missing or untrusted peer identity before
  forwarding to local backends.
- Trusted site A to site B/C call is accepted only when peer identity matches
  static trusted peer config.

Required tests:

- Unit tests for the peer identity type and context plumbing.
- Unit tests for `grid_ingress_trust` config parsing and trust decisions:
  - no peer identity rejects;
  - trusted organization accepts;
  - wrong organization rejects;
  - empty trusted peer list is rejected at config time or documented as
    fail-closed.
- Focused protocol/filter tests that prove `SslDigest` fields are copied into
  `HttpFilterContext`.
- Focused demo validation:
  - `scripts/check-prereqs.sh`
  - `scripts/generate-certs.sh`
  - `scripts/run-demo.sh`
  - `scripts/cleanup.sh`
- Required repository validation:
  - `cargo test -p praxis-proxy-filter grid_ingress_trust`
  - `cargo test -p praxis-proxy-protocol`
  - `cargo test -p praxis-proxy-filter`
  - `cargo test -p praxis-proxy`
  - `make lint`
  - `cargo clippy --workspace --all-targets -- -D warnings`
  - `git diff --check`

If any command is too broad or fails for an environmental reason, run the most
focused equivalent, capture the exact command/output, and explain with
evidence. Do not skip focused tests for touched Praxis code.

Documentation requirements:

- Update `implementation-notes.md` with actual files/functions touched,
  validated behavior, deviations, and extraction notes.
- Update `pr-extraction-map.md` with concrete evidence for G2G-01 and G2G-02.
- Update `sample-output.md` with sanitized new passing output.
- Add validated production prompt drafts for G2G-01 and G2G-02 only if the E2E
  behavior passes and the prompt is narrow enough for one upstream PR each.

Handoff must follow the strict review standard in
`pr-stack-documentation-plan.md`.

## G2G-E2E-03 — implement POC static site descriptor and inference routing

Goal:
Add enough POC Praxis behavior to choose local or remote gateway clusters from
a static site/capability descriptor.

Task scope:

1. Add a POC static descriptor/config model for inference route candidates.
   - Keep it small and extraction-friendly for G2G-03.
   - Inline `grid_route` config is acceptable for the E2E. A separate
     `snapshot.yaml` is also acceptable if that keeps config cleaner.
   - The model must represent:
     - local site name;
     - model/capability name;
     - destination site;
     - cluster to select.
   - Validate config at parse time with `#[serde(deny_unknown_fields)]`.
   - Reject empty model names, site names, and cluster names.
2. Add a POC `grid_route` HTTP filter.
   - Suggested location: an AI/grid or traffic-management-adjacent module,
     after inspecting current filter layout.
   - Register it in `filter/src/registry.rs`.
   - It should read the model promoted by `model_to_header` (`X-Model` by
     default) and set `ctx.cluster` to the selected local or remote cluster.
   - It must not read client-supplied `x-praxis-*` headers as routing
     authority.
   - It must write safe bounded route decision metadata to `ctx.filter_metadata`
     and/or tracing. Do not log prompts, request bodies, API keys, private keys,
     or full headers.
3. Resolve the router conflict explicitly.
   - Current router overwrites `ctx.cluster`.
   - Preferred POC fix: teach router to preserve an existing `ctx.cluster` and
     add a router unit test proving it does not overwrite a prior selector.
   - Alternate: split the demo chain so router runs only when `grid_route` did
     not select a cluster. Use this only if existing branching can express it
     clearly.
   - Do not let `grid_route` set a remote cluster and then allow router to
     overwrite it.
4. Update demo configs.
   - Site A public listener should classify model, run `grid_route`, then route
     or load-balance.
   - Site B/C grid listeners should continue to use `grid_ingress_trust`.
   - Existing `grid-site-b` and `grid-site-c` mTLS clusters should be used for
     remote inference.
5. Update `scripts/run-demo.sh`.
   - Keep existing trust assertions.
   - Add local model assertion through site A.
   - Add site-B-only model assertion through site A public listener and assert
     response body identifies `site-b`.
   - Add site-C-only model assertion through site A public listener and assert
     response body identifies `site-c`.
   - Add unknown model assertion with deterministic error status.
   - Add a safe route-decision evidence check if logs/metadata are emitted.

Important constraints from G2G-E2E-01/02:

- `grid_ingress_trust` validates the destination grid listener; do not weaken
  that path.
- `x-praxis-*`, `x-mcp-*`, and `x-a2a-*` request headers are reserved and are
  rejected on client ingress / stripped before upstream. Do not use them for
  route state in this task.
- Gateway-to-gateway forwarding metadata (G2G-05) should stay minimal here:
  safe internal metadata/log evidence is enough unless the route assertion
  genuinely needs HTTP headers.
- Scoring/freshness and MCP/A2A routing belong to G2G-E2E-04.

Required assertions:

- site A model routes locally.
- site B-only model routes through site B gateway.
- site C-only model routes through site C gateway.
- no eligible model returns a deterministic error.
- route decision metadata is safe and bounded.

Required tests:

- Unit tests for descriptor/config validation:
  - valid local and remote candidates parse;
  - empty model/site/cluster rejected;
  - duplicate or ambiguous model entries are rejected or resolved
    deterministically with an explicit test.
- Unit tests for `grid_route`:
  - local model selects local cluster;
  - site-B model selects `grid-site-b`;
  - site-C model selects `grid-site-c`;
  - unknown model rejects deterministically;
  - client-supplied reserved/internal headers do not influence route choice;
  - route metadata is bounded and contains no body content.
- Router test if router is changed:
  - existing `ctx.cluster` is preserved.
- Focused demo validation:
  - `scripts/check-prereqs.sh`
  - `scripts/generate-certs.sh`
  - `scripts/run-demo.sh`
  - `scripts/cleanup.sh`
- Required repository validation:
  - `cargo test -p praxis-proxy-filter grid_route`
  - `cargo test -p praxis-proxy-filter router` if router changes
  - `cargo test -p praxis-proxy-filter`
  - `cargo test -p praxis-proxy`
  - `make lint`
  - `cargo clippy --workspace --all-targets -- -D warnings`
  - `git diff --check`

Documentation requirements:

- Update `implementation-notes.md` with actual files/functions touched,
  route descriptor shape, router conflict resolution, and extraction notes.
- Update `pr-extraction-map.md` with concrete evidence for G2G-03, G2G-04,
  and any G2G-05 metadata behavior actually validated.
- Update `sample-output.md` with sanitized passing output.
- Add or refine validated production prompts only for behavior that passes.

Handoff must follow the strict review standard in
`pr-stack-documentation-plan.md`.

## G2G-E2E-04 — add freshness/locality scoring and agent-shaped route

Goal:
Extend the POC to validate scoring and at least one MCP or A2A remote route.

Task scope:

1. Extend the POC route descriptor for multiple candidate types and scoring.
   - Keep the model extraction-friendly for later G2G-06/G2G-07 PRs.
   - Add the minimum fields needed to express:
     - capability kind (`inference_model`, `mcp_tool`, and/or `a2a_agent`);
     - capability name;
     - destination site;
     - cluster;
     - freshness state or freshness timestamp;
     - deterministic tie-break/local-preference behavior.
   - Prefer enums over strings for fixed value sets.
   - Validate config at parse time with `#[serde(deny_unknown_fields)]`.
   - Reject empty/blank names, duplicate ambiguous candidates, invalid scoring
     fields, and unbounded metadata.
2. Add deterministic scoring.
   - Fresh candidates must beat stale candidates.
   - If candidates are otherwise equal, configured local preference should select
     the local site.
   - If no configured local preference applies, tie-break deterministically and
     document the rule.
   - Do not use wall-clock time in tests unless the clock is injectable. Static
     `fresh: true/false` or a fixed timestamp is acceptable for the POC.
3. Extend route input extraction beyond inference.
   - Inspect the existing `json_rpc`, `mcp`, and `a2a` filters before changing
     code.
   - Prefer existing filter metadata/promoted request facts over reparsing the
     body in `grid_route`.
   - Implement at least one remote agent-shaped route:
     - MCP tool route, or
     - A2A agent/task route.
   - If both MCP and A2A are small, implement both. If not, implement one
     thoroughly and document why the other is deferred.
4. Keep G2G-E2E-02/03 behavior intact.
   - Existing trust assertions must remain green.
   - Existing local/site-B/site-C inference assertions must remain green.
   - Router must still preserve a cluster selected by `grid_route`.
   - `grid_route` must still reject reserved internal header prefixes as route
     authority.
5. Update demo configs and mocks only as needed.
   - Use the existing site A/B/C topology.
   - Add a fresh-vs-stale inference assertion.
   - Add an equal-score/local-preference assertion.
   - Add one MCP or A2A request that enters site A public listener and reaches a
     remote site through the mTLS grid path.

Required assertions:

- fresh candidate beats stale candidate.
- configured local preference is honored when candidates are otherwise equal.
- MCP or A2A request crosses from site A to site B/C through mTLS.
- destination gateway still validates trust before forwarding.
- existing G2G-E2E-02/03 assertions still pass.
- route decision metadata remains bounded and safe.

Required tests:

- Unit tests for scoring:
  - fresh beats stale;
  - equal candidates honor local preference;
  - deterministic tie-break when local preference does not apply;
  - invalid scoring/freshness config rejects.
- Unit tests for route input extraction:
  - inference model route still works;
  - selected MCP or A2A request fact selects the expected cluster;
  - unknown capability returns deterministic error;
  - reserved/internal headers do not influence route choice.
- Unit tests for metadata:
  - selected capability/site/cluster metadata is bounded;
  - rejected/unknown routes do not store unbounded user-controlled values.
- Focused demo validation:
  - `scripts/check-prereqs.sh`
  - `scripts/generate-certs.sh`
  - `scripts/run-demo.sh`
  - `scripts/cleanup.sh`
- Required repository validation:
  - `cargo test -p praxis-proxy-filter "grid::route"`
  - targeted tests for any MCP/A2A filter touched
  - `cargo test -p praxis-proxy-filter`
  - `cargo test -p praxis-proxy`
  - `make lint`
  - `cargo clippy --workspace --all-targets -- -D warnings`
  - `git diff --check`

Documentation requirements:

- Update `implementation-notes.md` with scoring rules, candidate shape, and
  actual files/functions touched.
- Update `pr-extraction-map.md` with concrete evidence for G2G-06 and G2G-07.
- Update `sample-output.md` with sanitized passing output.
- Add or refine validated production prompts only for behavior that passes.
- Include extraction notes for G2G-06 and G2G-07.

Handoff must follow the strict review standard in
`pr-stack-documentation-plan.md`.

## G2G-E2E-05 — final demo evidence and PR-stack extraction

Goal:
Produce the final demo evidence and a clean proposed upstream PR stack.

Required outputs:

- `sample-output.md` with sanitized run output.
- updated `README.md` with exact run instructions.
- updated `pr-extraction-map.md` with actual file/function references from the
  E2E branch.
- final prompt list for upstream PR implementation tasks.

Validation:

- full demo script passes from a clean shell;
- focused Praxis tests pass;
- `git diff --check` clean in all touched repos.

## Validated production prompts

Production prompts start empty. Fill this section only after the corresponding
E2E behavior passes and Codex reviews the result.

Each production prompt must be copy-paste ready for Claude Code when the team
returns to upstreaming. It must not ask Claude to reproduce the whole E2E. It
must ask for one upstreamable change, with tests and docs aligned to
`praxis/docs/developing/conventions.md`.

Use the template from `pr-extraction-map.md`.

## UP-G2G-01 — expose verified downstream TLS peer identity

Validated by:

- E2E task: G2G-E2E-02
- Demo assertions: trusted site A client cert accepted by site B/C; CA-valid
  wrong-org cert rejected by `grid_ingress_trust`
- POC files:
  - `filter/src/context.rs`
  - `protocol/src/http/pingora/context.rs`
  - `protocol/src/http/pingora/handler/request_filter/mod.rs`

Goal:
Expose verified downstream client-certificate identity to HTTP filters without
requiring filters to parse TLS certificates or request headers.

Scope:

- Add a typed peer identity to `HttpFilterContext`.
- Populate it from Pingora `SslDigest` during request setup.
- Carry it through `PingoraRequestCtx` into all filter phases.
- Include organization, serial number, and SHA-256 certificate digest.
- Add a safe display/hex representation for the digest if any config or docs
  reference it.

Non-goals:

- Do not add route selection.
- Do not add gateway trust policy.
- Do not trust client-controlled request headers.
- Do not make organization-only identity a recommended production trust model.
- Do not add SAN parsing unless maintainers decide G2G-01 should include it.

Implementation notes learned from E2E:

- `SslDigest` already exposes `organization`, `serial_number`, and
  `cert_digest`.
- Plain TLS without a client cert can have an SSL digest but should not produce
  peer identity.
- Identity must remain read-only request context, not mutable filter authority.
- SAN/SPIFFE parsing is the stronger production identity direction and should
  be documented as an open design question if not implemented here.

Required tests:

- Unit/context tests proving default identity is `None`.
- Protocol/request setup tests proving `SslDigest` fields copy into
  `HttpFilterContext`.
- Negative test proving an SSL digest with no peer certificate fields does not
  create peer identity.
- Existing TLS tests must remain green.

Validation commands:

- `cargo test -p praxis-proxy-protocol`
- `cargo test -p praxis-proxy-filter`
- `cargo test -p praxis-proxy`
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `git diff --check`

Handoff requirements:

- Changed files and why.
- Commands run and results.
- Whether SAN parsing is included or explicitly deferred.
- Extraction link back to G2G-E2E-02 evidence.

## UP-G2G-02 — add grid ingress trust filter

Validated by:

- E2E task: G2G-E2E-02
- Demo assertions: trusted peer accepted; CA-valid wrong-org peer rejected;
  unknown-CA client cert rejected by mTLS
- POC files:
  - `filter/src/builtins/http/security/grid_ingress_trust.rs`
  - `filter/src/registry.rs`
  - `docs/filters/http/security/grid_ingress_trust.md`
  - `docs/filters/reference.md`

Goal:
Add an upstreamable HTTP security filter that allows a grid listener to
fail-closed unless the downstream peer identity is trusted.

Scope:

- Add `grid_ingress_trust` as a built-in HTTP security filter.
- Register it in the filter registry.
- Validate config at parse time with `#[serde(deny_unknown_fields)]`.
- Reject missing peer identity.
- Reject peers that do not match configured trust criteria.
- Add generated filter docs, an example config, and example integration test
  coverage required by `docs/developing/conventions.md`.

Production trust requirement:

- Do not copy the POC's organization-only trust model as the default production
  recommendation.
- Prefer SAN/SPIFFE identity if G2G-01 exposes it.
- If SAN identity is deferred, require a strong field such as certificate
  SHA-256 digest for production trust entries; organization and serial may be
  optional additional constraints.

Non-goals:

- Do not implement route selection.
- Do not add site descriptors.
- Do not add gateway-to-gateway forwarding metadata.
- Do not strip or trust `x-praxis-*` request headers; those are already
  rejected on client ingress and stripped before upstream forwarding.

Implementation notes learned from E2E:

- The filter must read `ctx.peer_identity`, not request headers.
- Empty trusted peer lists and empty match fields must fail at config time.
- Positive and negative tests need to distinguish TLS rejection from filter
  rejection:
  - unknown CA should fail at mTLS;
  - CA-valid but untrusted identity should reach the filter and return 403.

Required tests:

- Unit tests for config validation:
  - empty trusted list;
  - empty match fields;
  - no match fields;
  - valid config.
- Unit tests for trust decisions:
  - missing peer identity rejects;
  - trusted identity accepts;
  - wrong organization rejects;
  - serial/digest mismatch rejects when configured.
- Integration test with a real mTLS listener and `grid_ingress_trust`:
  - trusted client cert succeeds;
  - unknown CA cert fails TLS;
  - CA-valid but untrusted identity returns 403.
- Example config under `examples/configs/security/`.
- Functional example integration test and `examples/README.md` update.

Validation commands:

- `cargo test -p praxis-proxy-filter grid_ingress_trust`
- `cargo test -p praxis-proxy-filter`
- `cargo test -p praxis-proxy-protocol`
- relevant integration/example test command
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `make test` when practical
- `git diff --check`

Handoff requirements:

- Findings first with file/line references.
- Changed files and why.
- Commands run and results.
- Commands not run and evidence-backed reason.
- Remaining gaps.
- Extraction link back to G2G-E2E-02 evidence.

## UP-G2G-03 — add static gateway route descriptor model

Validated by:

- E2E task: G2G-E2E-03
- Demo assertions: local model routes to site A; site-B/site-C models route
  through remote gateways; unknown model returns deterministic 404
- POC file:
  - `filter/src/builtins/http/ai/grid/route.rs`

Goal:
Add the first upstreamable static route descriptor model for gateway-to-gateway
inference routing.

Scope:

- Add typed config for route candidates with:
  - local site name;
  - model/capability name;
  - destination site;
  - cluster to select.
- Validate config at parse time with `#[serde(deny_unknown_fields)]`.
- Reject empty or blank local site, model, site, and cluster values.
- Reject oversized names.
- Reject duplicate model candidates instead of relying on first-match behavior.
- Reject `model_header` values that use reserved internal/protocol prefixes:
  `x-praxis-*`, `x-mcp-*`, `x-a2a-*`.

Non-goals:

- Do not implement scoring/freshness.
- Do not implement MCP/A2A route selection.
- Do not add gateway-to-gateway HTTP forwarding headers.
- Do not rely on request headers with reserved prefixes as routing authority.

Implementation notes learned from E2E:

- Inline candidate config was enough for the POC, but upstream should place
  descriptor types where maintainers expect reusable AI/grid route config to
  live.
- Duplicate model entries are ambiguous. Reject them at config time unless the
  proposal explicitly chooses a deterministic priority model.
- `model_header` config must not allow reserved prefixes, even if public ingress
  currently rejects those headers, because internal listeners and future chains
  should not accidentally treat reserved metadata as user route input.

Required tests:

- Config parses for valid local and remote candidates.
- Empty/blank local site, model, site, and cluster reject.
- Oversized names reject.
- Duplicate model candidates reject.
- Reserved `model_header` prefixes reject.
- Unknown config fields reject.

Validation commands:

- `cargo test -p praxis-proxy-filter "grid::route"`
- `cargo test -p praxis-proxy-filter`
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `git diff --check`

Handoff requirements:

- Findings first with file/line references.
- Changed files and why.
- Commands run and results.
- Commands not run and evidence-backed reason.
- Extraction link back to G2G-E2E-03 evidence.

## UP-G2G-04 — add grid_route filter and preserve prior route selection

Validated by:

- E2E task: G2G-E2E-03
- Demo assertions: site A routes local, site-B, and site-C model requests to the
  expected backend through the expected gateway
- POC files:
  - `filter/src/builtins/http/ai/grid/route.rs`
  - `filter/src/builtins/http/traffic_management/router/mod.rs`
  - `filter/src/builtins/http/traffic_management/router/tests.rs`
  - `filter/src/registry.rs`
  - `docs/filters/http/ai/grid_route.md`
  - `docs/filters/reference.md`

Goal:
Add an upstreamable `grid_route` HTTP filter that selects a local or remote
gateway cluster from validated route descriptors and request facts, while
composing safely with the existing router/load-balancer pipeline.

Scope:

- Register `grid_route` as a built-in HTTP AI/grid filter.
- Read the model promoted by `model_to_header` from `X-Model` by default.
- Select the configured candidate and set `ctx.cluster`.
- Return deterministic 404 for a valid model with no candidate.
- Reject invalid, blank, or oversized model header values with deterministic 400.
- Write only bounded, safe route decision metadata to `ctx.filter_metadata`.
- Add generated filter docs and reference entry.
- Ensure the router does not overwrite `ctx.cluster` when a prior selector has
  already chosen a cluster.

Non-goals:

- Do not add scoring/freshness.
- Do not add MCP/A2A route matching.
- Do not add route forwarding headers.
- Do not log prompts, request bodies, API keys, private keys, full headers, or
  unbounded user-controlled values.

Implementation notes learned from E2E:

- The router conflict is real. Without a guard, router path matching can
  overwrite the remote cluster selected by `grid_route`.
- The preferred fix is a small router guard that returns `Continue` when
  `ctx.cluster` is already set, plus a router unit test.
- Metadata must stay bounded for both successful and rejected requests. Do not
  copy an oversized `X-Model` value into metadata.
- `grid_route` must ignore reserved/internal headers such as
  `x-praxis-grid-site`; route authority comes from validated config plus the
  promoted model value.

Required tests:

- `grid_route` local model selects local cluster.
- `grid_route` site-B model selects `grid-site-b`.
- `grid_route` site-C model selects `grid-site-c`.
- Unknown model returns deterministic 404.
- Missing model header skips so normal router behavior can handle fallback
  routes.
- Invalid/oversized model header returns deterministic 400 and does not store
  the value in metadata.
- Reserved/internal request headers do not influence route choice.
- Route metadata is bounded and contains no body content.
- Router preserves an existing `ctx.cluster`.
- Integration/example coverage through `model_to_header` → `grid_route` →
  router/load_balancer before upstreaming as complete feature work.

Validation commands:

- `cargo test -p praxis-proxy-filter "grid::route"`
- `cargo test -p praxis-proxy-filter "router::tests"`
- `cargo test -p praxis-proxy-filter`
- `cargo test -p praxis-proxy`
- relevant integration/example test command
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `make test` when practical
- `git diff --check`

Handoff requirements:

- Findings first with file/line references.
- Changed files and why.
- Exact validation results.
- Commands not run and evidence-backed reason.
- Remaining scope gaps, especially integration/example coverage.
- Extraction link back to G2G-E2E-03 evidence.

## UP-G2G-05 — define bounded gateway forwarding metadata contract

Validated by:

- E2E task: G2G-E2E-03
- Evidence: route decisions are stored as bounded `ctx.filter_metadata`; no
  HTTP forwarding metadata was validated in the POC.
- POC files:
  - `filter/src/builtins/http/ai/grid/route.rs`
  - `filter/src/context.rs`

Goal:
Define and implement the minimal upstreamable gateway-to-gateway metadata
contract needed for observability and downstream audit without trusting
client-controlled headers.

Scope:

- Start by documenting the intended metadata contract before implementing code.
- Decide whether gateway-to-gateway metadata should use:
  - typed/filter metadata only;
  - explicitly injected internal request headers between gateways; or
  - a combination with strict ingress/egress stripping.
- If HTTP headers are used, define exact header names, when they are injected,
  when they are stripped, and which listeners may trust them.
- Keep all metadata bounded.
- Do not include prompts, request bodies, API keys, cert material, or full
  headers.
- Preserve existing public ingress behavior: client-supplied reserved internal
  headers must be rejected before filters observe them.

Non-goals:

- Do not implement scoring/freshness.
- Do not implement MCP/A2A routing.
- Do not create a broad distributed membership protocol.
- Do not assume `x-praxis-*` request headers survive a normal upstream hop
  without proving where existing reserved-header stripping runs.

Implementation notes learned from E2E:

- The POC validated safe in-process `ctx.filter_metadata`, not gateway-visible
  HTTP forwarding metadata.
- Existing reserved header behavior is a security boundary. Public clients
  cannot set `x-praxis-*`, `x-mcp-*`, or `x-a2a-*` without receiving 400.
- Existing upstream stripping may remove reserved headers before backend hops.
  Any header-based gateway metadata must be intentionally placed in the
  lifecycle and covered by tests.
- Treat this PR as design-sensitive. If the right contract is unclear, stop
  after docs/tests/proposal updates rather than silently inventing a broad
  metadata scheme.

Required tests:

- Public client-supplied internal metadata headers are rejected or ignored.
- Gateway-generated metadata is bounded.
- Metadata does not include body content or secrets.
- If headers are used, destination grid listener can read only metadata from an
  authenticated peer, and final local backend does not receive internal headers
  unless explicitly intended.
- Existing G2G route/trust tests remain green.

Validation commands:

- focused tests for touched filter/protocol modules
- `cargo test -p praxis-proxy-filter`
- `cargo test -p praxis-proxy-protocol` if protocol/header lifecycle changes
- `cargo test -p praxis-proxy`
- relevant integration/example test command
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `git diff --check`

Handoff requirements:

- Findings first with file/line references.
- Explicit metadata contract summary.
- Changed files and why.
- Exact validation results.
- Remaining open design questions.
- Extraction link back to G2G-E2E-03 partial evidence.

## UP-G2G-06 — add deterministic freshness and locality scoring

Validated by:

- E2E task: G2G-E2E-04
- Demo assertions:
  - `freshness-model` routes to site C because fresh remote beats stale remote;
  - `equal-model` routes to site A because local preference wins when candidates
    are otherwise equal.
- POC file:
  - `filter/src/builtins/http/ai/grid/route.rs`

Goal:
Add deterministic candidate scoring to gateway-to-gateway route selection.

Scope:

- Add validated scoring fields to the route descriptor.
- Prefer fresh candidates over stale candidates.
- Prefer the local site when otherwise equal.
- Use a deterministic tie-break and document it.
- Keep route metadata bounded and safe.

Non-goals:

- Do not implement dynamic discovery.
- Do not add request-header forwarding metadata.
- Do not add A2A routing in this PR.
- Do not use wall-clock time in tests unless the clock is injectable.

Implementation notes learned from E2E:

- A combined “fresh local beats stale remote” case is not enough evidence; tests
  and examples need isolated freshness and isolated local-preference cases.
- `Iterator::max_by_key` is not the right tie-break if the intended behavior is
  first configured candidate wins. Use explicit selection logic or a key that
  encodes the desired stable ordering.
- Static `fresh: true/false` is POC-only. Upstream should decide whether
  freshness is boolean, timestamp/TTL, generation, or snapshot-derived.

Required tests:

- Fresh remote beats stale remote with no local-preference involvement.
- Local candidate beats remote candidate when otherwise equal.
- Equal non-local candidates choose the documented deterministic tie-break.
- Invalid scoring/freshness config rejects at parse time.
- Existing local/remote/unknown route tests remain green.
- Metadata for selected score/freshness remains bounded.

Validation commands:

- `cargo test -p praxis-proxy-filter "grid::route"`
- `cargo test -p praxis-proxy-filter`
- `cargo test -p praxis-proxy`
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `git diff --check`

Handoff requirements:

- Findings first with file/line references.
- Changed files and why.
- Exact validation results.
- Remaining scope gaps.
- Extraction link back to G2G-E2E-04 evidence.

## UP-G2G-07-MCP — route MCP tools/call from MCP metadata

Validated by:

- E2E task: G2G-E2E-04
- Demo assertion: JSON-RPC `tools/call` for `weather-lookup` enters site A,
  routes through mTLS to site C, passes `grid_ingress_trust`, and reaches the
  site-C MCP mock.
- POC files:
  - `filter/src/builtins/http/ai/grid/route.rs`
  - demo config showing `json_rpc`/`mcp` with `on_invalid: continue`

Goal:
Extend gateway-to-gateway route selection to MCP `tools/call` requests using
body-derived MCP metadata.

Scope:

- Add an MCP capability kind for route candidates.
- Match MCP `tools/call` by `mcp.name` metadata produced by the MCP filter.
- Route matching must read filter metadata, not request headers.
- Unknown MCP tools return deterministic 404.
- Invalid/blank/oversized MCP tool names reject with deterministic 400 and do
  not copy the value into route metadata.
- Document mixed-traffic listener configuration: `json_rpc` and `mcp` need
  `on_invalid: continue` when the listener also receives non-JSON-RPC or
  non-MCP traffic.

Non-goals:

- Do not add A2A routing in this PR.
- Do not add MCP broker/catalog behavior.
- Do not trust `x-mcp-*`, `x-praxis-*`, or other client-controlled internal
  headers for route authority.
- Do not route non-`tools/call` MCP methods unless the proposal explicitly
  defines them.

Implementation notes learned from E2E:

- MCP filter defaults can reject non-MCP traffic on mixed listeners. Example
  configs must set `on_invalid: continue` or use separate listener/chains.
- The grid route filter should not reparse the body; it should consume metadata
  produced by existing protocol-aware filters.
- Keep A2A separate unless it is implemented and validated with the same depth.

Required tests:

- MCP `tools/call` with known tool selects expected remote gateway cluster.
- Unknown MCP tool returns deterministic 404.
- Non-`tools/call` MCP method skips route selection.
- Blank/oversized MCP tool rejects with 400 and bounded metadata.
- Reserved/internal request headers do not influence MCP route choice.
- Mixed-traffic config/example proves inference requests still work with
  `json_rpc`/`mcp` in the chain.

Validation commands:

- `cargo test -p praxis-proxy-filter "grid::route"`
- targeted MCP filter tests if MCP config/metadata behavior changes
- `cargo test -p praxis-proxy-filter`
- `cargo test -p praxis-proxy`
- relevant integration/example test command
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `git diff --check`

Handoff requirements:

- Findings first with file/line references.
- Changed files and why.
- Exact validation results.
- Remaining A2A gap explicitly called out.
- Extraction link back to G2G-E2E-04 evidence.

## UP-G2G-08 — add upstream examples, docs, and integration coverage

Validated by:

- E2E task: G2G-E2E-05
- Evidence: final demo docs, sample output, and extraction map describe the
  complete validated gateway-to-gateway path.
- Spike files:
  - `demo/gateway-to-gateway-routing/README.md`
  - `demo/gateway-to-gateway-routing/sample-output.md`
  - `demo/gateway-to-gateway-routing/pr-extraction-map.md`
  - `demo/gateway-to-gateway-routing/configs/`
  - `demo/gateway-to-gateway-routing/scripts/`

Goal:
Convert the validated gateway-to-gateway behavior into upstream documentation,
example configs, and integration/example tests required by
`docs/developing/conventions.md`.

Scope:

- Add minimal example config(s) under `examples/configs/` for the upstreamed
  pieces that exist by this point in the PR stack.
- Add functional example integration tests under
  `tests/integration/tests/suite/examples/`.
- Update `examples/README.md`.
- Update generated filter docs/reference docs as required by the repo tooling.
- Add or update operating/architecture docs for:
  - peer identity exposure;
  - grid ingress trust;
  - grid route descriptor/route filter;
  - mixed-traffic `json_rpc`/`mcp` `on_invalid: continue` requirement;
  - any accepted gateway metadata contract from G2G-05.
- Keep examples minimal and production-safe.

Non-goals:

- Do not upstream the spike scripts, generated certs, or Python mocks verbatim.
- Do not add features not already accepted in prior upstream PRs.
- Do not document POC-only shortcuts as production recommendations.
- Do not claim A2A support unless an A2A PR has been implemented and validated.

Implementation notes learned from E2E:

- The E2E demo is useful as source material, but upstream examples should use
  normal repo example/test patterns.
- `grid_ingress_trust` production docs should not recommend organization-only
  certificate matching as the default trust model.
- Mixed-traffic listeners need explicit `on_invalid: continue` guidance when
  JSON-RPC/MCP filters sit in a chain that also handles inference or health
  requests.
- Example tests must prove behavior, not just parse configs.

Required tests:

- Example config parse/validation test.
- Functional integration test for the example config.
- Negative/security coverage for public internal-header spoofing.
- Trust path coverage for accepted and rejected mTLS peers if the upstream PR
  stack includes `grid_ingress_trust`.
- Route selection example coverage for local, remote, unknown route, and any
  upstreamed MCP route behavior.

Validation commands:

- relevant example/integration test command
- `cargo xtask lint-example-tests`
- `cargo xtask sync-example-readme`
- `cargo xtask lint-filter-docs`
- `cargo test -p praxis-proxy-filter`
- `cargo test -p praxis-proxy`
- `make lint`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `make test` when practical
- `git diff --check`

Handoff requirements:

- Findings first with file/line references.
- Changed files and why.
- Exact validation results.
- Commands not run and evidence-backed reason.
- Any behavior intentionally not documented because it remains POC-only.
- Extraction link back to G2G-E2E-05 evidence.
