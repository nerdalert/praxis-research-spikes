# Gateway-to-gateway E2E implementation notes

## POC branch

| Property | Value |
| --- | --- |
| Repository | `nerdalert/praxis` |
| Branch | `praxis-multi-cluster-poc-v1` |
| Base commit | `60f1041` (`fix(store): move conversation lifecycle to ConversationItemStore (#717)`) |
| POC commit | `05353df` (Gateway-to-gateway E2E POC implementation) |
| URL | https://github.com/nerdalert/praxis/tree/praxis-multi-cluster-poc-v1 |

**Note:** Production extraction remains future work. This branch contains POC-quality implementation for demo validation only.

## Chosen architecture

Gateway-to-gateway routing uses a typed `grid_route` filter backed by an
immutable local routing snapshot. The filter chooses a Praxis cluster by
setting `ctx.cluster`; existing Praxis clusters, load balancing, timeouts, TLS,
and mTLS handle the connection to a local backend or remote gateway.

The AI Grid Operator is the production owner of snapshot updates. It renders
or publishes validated gateway-local state outside the request path. Praxis
does not query the Operator, Kubernetes, SWIM/CRDT, metrics, or a database
while a client request is waiting.

## Snapshot model and fault tolerance

The demo is masterless: there is no master node, leader election, or central
coordinator in the request path. Each gateway makes routing decisions from its
own local config.

The demo is **not dynamically fault tolerant**. It uses static config with
static candidate snapshots. If a configured target site goes down, the origin
gateway continues attempting that route until the config is updated. The
`fresh: true/false` field is a static POC signal that demonstrates scoring
behavior but is not automatically updated by health or liveness signals.

Dynamic fault tolerance belongs in the AI Grid Operator, which will render and
publish updated gateway snapshots outside the request path. The Operator may
consume Kubernetes resource watches, SWIM/CRDT membership state, and metrics
summaries — those are Operator inputs, not Praxis request-path dependencies.

When config changes, Praxis hot-reloads atomically (file watcher, 500ms
debounce). New requests use the new config; in-flight requests finish on
the previous pipeline.

## E2E architecture

### Process topology

```text
                       ┌─ mock-inference-a :18001 ─┐
client ──> site-a      │                            │
           :18100 pub  ├─ mock-mcp-a      :18002 ──┤  site-a backends
           :18101 grid │                            │
                       └─ mock-a2a-a      :18003 ──┘

           site-b      ┌─ mock-inference-b :18011 ─┐
           :18110 grid ├─ mock-mcp-b      :18012 ──┤  site-b backends
                       └─ mock-a2a-b      :18013 ──┘

           site-c      ┌─ mock-inference-c :18021 ─┐
           :18120 grid ├─ mock-mcp-c      :18022 ──┤  site-c backends
                       └─ mock-a2a-c      :18023 ──┘
```

All processes bind `127.0.0.1`. Port ranges avoid conflicts with
common dev services and with each other.

| Process | Listener | Port | TLS mode |
| --- | --- | --- | --- |
| site-a Praxis | public | 18100 | plain HTTP (client-facing) |
| site-a Praxis | grid | 18101 | mTLS (grid ingress) |
| site-b Praxis | grid | 18110 | mTLS (grid ingress) |
| site-c Praxis | grid | 18120 | mTLS (grid ingress) |
| mock-inference-a | HTTP | 18001 | plain |
| mock-mcp-a | HTTP | 18002 | plain |
| mock-a2a-a | HTTP | 18003 | plain |
| mock-inference-b | HTTP | 18011 | plain |
| mock-mcp-b | HTTP | 18012 | plain |
| mock-a2a-b | HTTP | 18013 | plain |
| mock-inference-c | HTTP | 18021 | plain |
| mock-mcp-c | HTTP | 18022 | plain |
| mock-a2a-c | HTTP | 18023 | plain |

Site A has both a public listener (for client traffic) and a grid
listener (so site B or C could route back to it). Sites B and C
have grid listeners only for the initial demo.

### Trust boundaries

| Boundary | Enforcement |
| --- | --- |
| Public client → site A public listener | No client cert. Reject client-supplied reserved `x-praxis-*`, `x-mcp-*`, and `x-a2a-*` headers before filter execution. |
| Site A → site B grid listener | Site A presents client cert signed by grid CA. Site B requires it. |
| Site A → site C grid listener | Same. |
| Grid listener → local backend | Strip internal gateway headers before forwarding. |

## mTLS certificate plan

Use the existing `TestCertificates` pattern from
`tests/utils/src/net/tls.rs` as reference. For the E2E demo
scripts, generate a local PKI at demo time:

```text
certs/
  grid-ca.pem              # grid CA (signs all gateway certs)
  grid-ca-key.pem
  site-a.pem               # site-a server cert (SAN: DNS:site-a, IP:127.0.0.1)
  site-a-key.pem
  site-a-client.pem         # site-a client cert for upstream mTLS
  site-a-client-key.pem
  site-b.pem
  site-b-key.pem
  site-c.pem
  site-c-key.pem
```

Generation tool: `openssl` or `mkcert`. A
`scripts/generate-certs.sh` script creates the full set. All certs
share one grid CA so any gateway can verify any other.

For the Praxis integration test variant, use the
`TestCertificates::generate_for_san` and `generate_client_cert`
helpers directly rather than shelling out to openssl.

### Pingora peer certificate availability

Pingora's `SslDigest` (from the `quixotic-plecostomus-core` crate)
is populated for downstream connections by `SslDigest::from_stream`,
which calls `session.peer_certificates()` and extracts:

- `cert_digest`: SHA-256 hash of the leaf certificate
- `organization`: X.509 subject organization (O= field)
- `serial_number`: certificate serial number

**Gap**: Pingora does not extract Subject Alternative Names (SANs)
from the peer certificate. For SPIFFE URI SAN or DNS SAN identity
matching, the E2E must either:

1. Parse the raw DER certificate bytes from `peer_certificates()`
   using `x509-cert` or `rustls-pki-types` in the protocol layer;
   or
2. Match on `organization` + `serial_number` as a simpler initial
   peer identity scheme, and add SAN extraction in a follow-up.

Recommended: start with option 2 for the POC (organization-based
matching is sufficient for a three-gateway demo), plan option 1
for the upstream PR that exposes typed peer identity.

## Mock backend plan

Each mock backend is a minimal HTTP server that echoes enough
information to prove the route decision was correct.

### Inference mock

Listens for `POST /v1/chat/completions` (OpenAI-compatible).
Returns a JSON response with:

```json
{
  "site": "site-b",
  "model": "llama-3.1-8b",
  "source": "mock-inference"
}
```

The test client asserts that the `site` field matches the expected
route destination.

### MCP mock

Listens for `POST /mcp`. Reads the JSON-RPC body, extracts the
method and tool name. Returns:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "site": "site-c",
    "tool": "weather-lookup",
    "source": "mock-mcp"
  }
}
```

### A2A mock

Listens for `POST /a2a`. Reads the JSON-RPC body. Returns:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "site": "site-b",
    "agent": "code-review-agent",
    "source": "mock-a2a"
  }
}
```

### Mock server choice

The demo harness uses small Python scripts for mock inference, MCP, and A2A
servers because they are fast to run, easy to inspect, and do not add another
compiled binary to the spike. The upstream integration-test variant should use
the Rust `start_backend` helpers from `tests/utils/` instead of carrying these
demo-only mocks into production tests.

## Praxis config plan

### site-a.yaml

```yaml
listeners:
  - name: public
    address: "127.0.0.1:18100"
    filter_chains:
      - grid-strip
      - ai-classify
      - grid-route
      - traffic

  - name: grid
    address: "127.0.0.1:18101"
    filter_chains:
      - grid-ingress
      - ai-classify
      - traffic
    tls:
      certificates:
        - cert_path: certs/site-a.pem
          key_path: certs/site-a-key.pem
      client_ca:
        ca_path: certs/grid-ca.pem
      client_cert_mode: require

filter_chains:
  - name: grid-strip
    filters:
      # POC: strip known X-Praxis-Grid-* headers from public clients.
      # The existing headers filter does not support wildcards, so keep this
      # list explicit until grid_ingress_trust owns the trust boundary.
      - filter: headers
        request_remove:
          - "x-praxis-grid-origin"
          - "x-praxis-grid-capability"
          - "x-praxis-grid-generation"

  - name: grid-ingress
    filters:
      # POC: validate peer identity and trust internal headers
      - filter: grid_ingress_trust  # new POC filter

  - name: ai-classify
    filters:
      - filter: model_to_header
      - filter: json_rpc
      - filter: mcp
      - filter: a2a

  - name: grid-route
    filters:
      # POC: select local or remote cluster from snapshot
      - filter: grid_route  # new POC filter

  - name: traffic
    filters:
      - filter: router
        routes:
          - path_prefix: "/v1/chat/completions"
            cluster: local-inference
          - path_prefix: "/mcp"
            cluster: local-mcp
          - path_prefix: "/a2a"
            cluster: local-a2a
      - filter: load_balancer
        clusters:
          - name: local-inference
            endpoints:
              - "127.0.0.1:18001"
          - name: local-mcp
            endpoints:
              - "127.0.0.1:18002"
          - name: local-a2a
            endpoints:
              - "127.0.0.1:18003"
          - name: grid-site-b
            tls:
              sni: site-b
              ca:
                ca_path: certs/grid-ca.pem
              client_cert:
                cert_path: certs/site-a-client.pem
                key_path: certs/site-a-client-key.pem
            endpoints:
              - "127.0.0.1:18110"
          - name: grid-site-c
            tls:
              sni: site-c
              ca:
                ca_path: certs/grid-ca.pem
              client_cert:
                cert_path: certs/site-a-client.pem
                key_path: certs/site-a-client-key.pem
            endpoints:
              - "127.0.0.1:18120"
```

Sites B and C follow the same pattern but with only grid listeners
and their own local backends. They do not need the `grid-route`
chain (they only receive routed traffic, not originate it, for the
initial demo).

### Key config observations

1. The `grid_route` filter is the core POC addition. It reads
   AI/MCP/A2A metadata from the pipeline, consults a static
   `RoutingSnapshot`, and sets `ctx.cluster` to the selected
   cluster name.

2. The existing `router` filter remains in the pipeline as a
   fallback and for path-based routing within a site. The
   `grid_route` filter runs first and may set `ctx.cluster`
   before the router executes. Review correction: the current
   router does not skip when `ctx.cluster` is already set, so the POC
   must either add explicit router skip behavior or branch around the
   router after `grid_route` selects a cluster.

3. Internal gateway headers (`X-Praxis-Grid-*`) use the existing
   reserved header prefix system
   (`protocol/src/http/pingora/handler/reserved_headers.rs`).
   They are already stripped on upstream and from client
   responses. The POC needs to add stripping on public ingress
   and validation on grid ingress.

## Code areas requiring POC changes

### New code (POC-only initially, extraction targets later)

| Area | Likely location | Purpose | Extraction target |
| --- | --- | --- | --- |
| Peer identity extraction | `protocol/src/http/pingora/handler/request_filter/mod.rs` | Extract `organization` from `SslDigest` and expose in filter context | G2G-01 |
| `grid_ingress_trust` filter | `filter/src/builtins/http/security/` | Validate peer identity and protect internal headers on grid listeners | G2G-02 |
| `RoutingSnapshot` model | `filter/src/builtins/http/ai/grid/` or `core/src/config/` | Typed site/capability/freshness data model | G2G-03 |
| `grid_route` filter | `filter/src/builtins/http/ai/grid/` | Read metadata + snapshot, select cluster | G2G-04 |
| Internal route header injection | Inside `grid_route` filter | Add `X-Praxis-Grid-*` headers for gateway-to-gateway hops | G2G-05 |
| Scoring logic | Inside `grid_route` filter | Freshness/locality/capability scoring | G2G-06 |
| MCP/A2A candidate matching | Inside `grid_route` filter | Extend matching to tool/agent metadata | G2G-07 |

### Existing code requiring modification

| File | Change | Reason |
| --- | --- | --- |
| `filter/src/context.rs` | Add optional peer identity field | Filters need to read authenticated gateway identity |
| `protocol/src/http/pingora/handler/request_filter/mod.rs` | Extract peer identity from `SslDigest` | Populate the new context field |
| `protocol/src/http/pingora/context.rs` | Add peer identity to protocol context | Pass through to filter context |
| `filter/src/registry.rs` | Register new `grid_ingress_trust` and `grid_route` filters | Make them available in configs |

### Code that should NOT be modified

- Existing router, load_balancer, or TLS infrastructure
- MCP/A2A/json_rpc filter internals (only read their metadata)
- Pingora/rustls internals
- Existing integration tests

## Expected assertions by demo phase

### Phase 1: smoke harness (G2G-E2E-01)

| Assertion | Method |
| --- | --- |
| All three Praxis instances start successfully | Process exit codes |
| All nine mock backends respond | HTTP GET health checks |
| Local inference route works through site A public listener | `curl http://127.0.0.1:18100/v1/chat/completions`, assert `site: site-a` |
| Direct call to grid listener without client cert fails | `curl https://127.0.0.1:18110/...` without `--cert`, assert TLS rejection |
| Cert generation script is idempotent | Run twice, second run reuses or regenerates cleanly |

### Phase 2: trust and header protection (G2G-E2E-02)

| Assertion | Method |
| --- | --- |
| Public client-supplied `X-Praxis-Grid-Origin` header is rejected | Send with header, verify 400 before filter execution |
| Grid listener rejects connection without client cert | curl without cert to grid port fails |
| Grid listener accepts trusted peer with valid cert | curl with site-a client cert to site-b grid port succeeds |
| Grid listener rejects cert from unknown CA | Generate cert from separate CA, verify rejection |
| Peer identity is available in filter context | Log output shows extracted identity |

### Phase 3: static routing (G2G-E2E-03)

| Assertion | Method |
| --- | --- |
| Request for site-a-only model routes locally | Assert response `site: site-a` |
| Request for site-b-only model routes to site B | Assert response `site: site-b` |
| Request for site-c-only model routes to site C | Assert response `site: site-c` |
| Request for unknown model returns error | Assert 404 or 503 with route-not-found reason |
| Route decision metadata logged safely | Grep logs for snapshot generation, selected site, no secrets |

### Phase 4: scoring and agent routing (G2G-E2E-04)

| Assertion | Method |
| --- | --- |
| Fresh candidate beats stale candidate | Configure two sites with same model, make one stale, verify winner |
| Local preference honored when otherwise equal | Both local and remote have same model, local wins |
| MCP request crosses gateway boundary | JSON-RPC tool call routes to site C, assert `site: site-c` |
| A2A request crosses gateway boundary | JSON-RPC agent call routes to site B, assert `site: site-b` |
| Destination gateway still validates trust | Verify mTLS is checked on every gateway hop |

### Phase 5: final evidence (G2G-E2E-05)

| Assertion | Method |
| --- | --- |
| Full demo script passes from clean shell | `scripts/run-demo.sh` exits 0 |
| Sample output is sanitized | No prompts, API keys, cert private keys, or full bodies |
| Extraction map has concrete file/function references | Diff against template shows filled entries |

## Known blockers and missing primitives

### Blocker: peer certificate identity not exposed to filters

**Status**: confirmed blocker.

Praxis sets `ctx.downstream_tls = true/false` from `SslDigest`
presence but does not extract or expose certificate identity fields
(`organization`, `serial_number`, `cert_digest`) to HTTP filters.

**Mitigation for POC**: add a small protocol-layer change to extract
`organization` from `SslDigest` and store it in a new
`HttpFilterContext` field. This is the minimum viable peer identity
for a three-gateway demo.

**Upstream plan**: the production PR (G2G-01) should add a typed
`TlsPeerIdentity` struct with organization, serial, cert digest,
and later SAN fields.

### Not a blocker: client-supplied reserved headers are rejected on ingress

**Status**: resolved by existing protocol behavior for reserved prefixes.

The reserved header system rejects client-supplied `x-praxis-*`, `x-mcp-*`,
and `x-a2a-*` headers before special handling or filter execution can observe
them (`request_filter/mod.rs::reject_reserved_internal_headers`). The smoke
harness verified `x-praxis-grid-origin` receives a 400 from the public
listener.

This means a future `grid_route` or `grid_ingress_trust` filter should not try
to solve public spoofing for these reserved prefixes in the filter layer; the
request is already rejected before filters run.

**Remaining POC requirement**: `grid_ingress_trust` still needs to validate
authenticated peer identity on grid listeners before trusting any internal
metadata produced by another gateway. If the POC introduces any non-reserved
internal header names, they must be stripped or ignored on public ingress.

### Not a blocker: existing reserved header stripping

The existing `strip_reserved_internal` in `upstream_request.rs`
already removes `x-praxis-*` and `x-mcp-*` and `x-a2a-*` before
upstream. This is helpful for the final backend hop but means the
POC must inject internal grid headers *after* the standard strip,
or use a different mechanism for gateway-to-gateway metadata (e.g.,
filter metadata or typed extensions rather than request headers).

**Recommendation**: prefer typed filter/protocol metadata for gateway-to-gateway
state where possible. If the POC must put gateway metadata on the HTTP request,
it needs a deliberate contract for where those headers are added and removed,
because `ctx.extra_request_headers` is applied before
`strip_reserved_internal`. Do not rely on `x-praxis-*` request headers
surviving a normal upstream hop without changing that behavior explicitly.

### Router conflict

The existing `router` filter sets `ctx.cluster` based on path/host
matching. The `grid_route` filter also needs to set `ctx.cluster`.

Review correction: in the current E2E worktree, the router does not skip
when `ctx.cluster` is already set. It matches path/host and writes
`ctx.cluster` again. Do not rely on the original G2G-E2E-00 assumption that
router already has this guard.

Options:

1. Preferred production direction: teach the router to preserve an existing
   `ctx.cluster` and add tests proving a prior selector is not overwritten.
   This is small, explicit, and keeps `grid_route` composable with the existing
   traffic chain.
2. Alternate: split chains so the router runs only when `grid_route` did not
   select a cluster. Use this only if existing branching support can express it
   cleanly without hidden coupling.
3. Avoid: allowing `grid_route` to set `ctx.cluster` and then running the
   current router after it. That makes remote route selection look like it
   works in logs while the final upstream cluster may be overwritten.

E2E should make this conflict visible in G2G-E2E-03 and map the chosen fix to
the G2G-04 route-filter PR.

## Extraction targets from upstream-pr-stack.md

| Target | E2E phase | Key files to touch | Upstream priority |
| --- | --- | --- | --- |
| G2G-01 peer identity | E2E-02 | `protocol/src/http/pingora/handler/request_filter/mod.rs`, `filter/src/context.rs` | First — unblocks all trust work |
| G2G-02 ingress trust | E2E-02 | New filter in `filter/src/builtins/http/security/` | Second — enables trust validation |
| G2G-03 site descriptor model | E2E-03 | New types in `filter/src/builtins/http/ai/grid/` or `core/src/config/` | Third — data model for routing |
| G2G-04 route filter | E2E-03 | New filter in `filter/src/builtins/http/ai/grid/` | Fourth — core routing logic |
| G2G-05 remote forwarding | E2E-03 | Inside grid_route filter + upstream_request changes | Fifth — gateway-to-gateway metadata |
| G2G-06 scoring | E2E-04 | Inside grid_route filter | Sixth — quality of route decisions |
| G2G-07 MCP/A2A routing | E2E-04 | Inside grid_route filter | Seventh — agent traffic |
| G2G-08 docs and examples | E2E-05 | `examples/configs/`, `docs/`, integration tests | Last — cleanup |

## Scripts and manifests needed

```text
demo/gateway-to-gateway-routing/
  scripts/
    check-prereqs.sh        # verify praxis binary, openssl, python3, curl
    generate-certs.sh        # create grid CA + per-site certs
    start-mocks.sh           # start all nine mock backends
    start-gateways.sh        # start three Praxis instances
    run-assertions.sh        # run all demo assertions
    run-demo.sh              # orchestrate: prereqs, certs, mocks, gateways, assertions, cleanup
    cleanup.sh               # kill all demo processes, optionally remove certs
  configs/
    site-a.yaml
    site-b.yaml
    site-c.yaml
    snapshot.yaml             # static RoutingSnapshot for grid_route
  mocks/
    inference.py              # mock inference backend
    mcp.py                    # mock MCP backend
    a2a.py                    # mock A2A backend
```

## What should become upstream vs POC-only

### Upstream PR material

- Typed `TlsPeerIdentity` in filter context (G2G-01)
- `grid_ingress_trust` filter (G2G-02)
- `RoutingSnapshot` data model with serde validation (G2G-03)
- `grid_route` filter with deterministic scoring (G2G-04)
- Internal route header injection/validation contract (G2G-05)
- Freshness/locality scoring (G2G-06)
- MCP/A2A candidate matching (G2G-07)
- Example configs and integration tests (G2G-08)

### POC-only (do not upstream)

- Demo scripts (`scripts/`, `mocks/`)
- Generated cert artifacts
- Organization-based peer identity matching (upstream should use SAN)
- Any hardcoded port numbers or site names
- Monolithic POC filter implementations that combine multiple concerns
- Any `verify: false` or security shortcuts

## First coding prompt recommendation for G2G-E2E-01

The next task should create the minimal runnable harness:

1. Write `scripts/generate-certs.sh` using `openssl` to create
   the grid CA and per-site certificates.
2. Write `mocks/inference.py`, `mocks/mcp.py`, `mocks/a2a.py`
   as minimal Python HTTP servers.
3. Write `configs/site-a.yaml`, `configs/site-b.yaml`,
   `configs/site-c.yaml` using only existing Praxis filters
   (no POC code yet).
4. Write `scripts/run-demo.sh` that starts mocks, starts
   gateways, runs basic assertions, and cleans up.
5. Verify: local route through site A works; direct call to
   grid listener without cert fails; all processes start and
   stop cleanly.

This does not require any Praxis code changes. It exercises
existing mTLS, router, and load_balancer functionality. The
POC filter code starts in G2G-E2E-02.

## G2G-E2E-01 results

### Files added

| File | Purpose |
| --- | --- |
| `scripts/check-prereqs.sh` | Verify praxis binary, openssl, python3, curl, and demo files |
| `scripts/generate-certs.sh` | Create grid CA + per-site server/client certs with X.509 v3 extensions |
| `scripts/run-demo.sh` | Orchestrate: prereqs, certs, mocks, gateways, assertions, cleanup |
| `scripts/cleanup.sh` | Kill all demo processes by PID file |
| `configs/site-a.yaml` | Site A: public listener :18100 + grid listener :18101 (mTLS) |
| `configs/site-b.yaml` | Site B: grid listener :18110 (mTLS only) |
| `configs/site-c.yaml` | Site C: grid listener :18120 (mTLS only) |
| `mocks/inference.py` | OpenAI-compatible echo server returning site name |
| `mocks/mcp.py` | JSON-RPC MCP echo server returning site name |
| `mocks/a2a.py` | JSON-RPC A2A echo server returning site name |
| `.gitignore` | Exclude certs/, .pids/, .logs/ from git |

### Deviations from plan

1. **Certificate v3 extensions required**: Rustls/webpki rejects X.509 v1
   client certificates with `UnsupportedCertVersion`. All certs now include
   `basicConstraints` and `keyUsage` extensions to produce v3 certificates.
   This will also apply to the Praxis integration test variant.

2. **Reserved header rejection at protocol layer**: The original plan assumed
   `x-praxis-*` headers from public clients would silently pass through to
   filters and need stripping. In practice, Praxis rejects them with 400 Bad
   Request at the protocol layer (`reserved_headers.rs`). The `headers` filter
   `request_remove` chain in `site-a.yaml` is defense-in-depth but never
   executes for `x-praxis-*` headers.

3. **Script structure simplified**: `start-mocks.sh`, `start-gateways.sh`, and
   `run-assertions.sh` were consolidated into `run-demo.sh` to reduce the
   number of scripts while keeping the logic clearly sectioned.

4. **No `snapshot.yaml` yet**: The static `RoutingSnapshot` config is not
   needed until G2G-E2E-03 when the `grid_route` filter exists.

5. **Binary name is `praxis`, not `praxis-proxy`**: The cargo package is
   `praxis-proxy` but the binary crate produces `target/debug/praxis`.

### Validated assertions (17 pass, 0 fail, 7 not-yet-implemented)

| # | Assertion | Result |
| --- | --- | --- |
| 1-9 | All nine mock backends respond to GET / | PASS |
| 10 | POST /v1/chat/completions through site-a → site-a inference mock | PASS |
| 11 | GET / through site-a → site-a inference mock health | PASS |
| 12 | site-b grid :18110 rejects plain HTTP | PASS (expected failure) |
| 13 | site-b grid :18110 rejects HTTPS without client cert | PASS (expected failure) |
| 14 | site-c grid :18120 rejects plain HTTP | PASS (expected failure) |
| 15 | site-b grid accepts site-a client cert (mTLS) | PASS |
| 16 | site-c grid accepts site-a client cert (mTLS) | PASS |
| 17 | x-praxis-grid-origin from public client rejected (400) | PASS (expected failure) |

### Extraction notes

```text
Extraction target: none directly from E2E-01
Validated behavior: process topology, mTLS enforcement, cert generation, local routing
Files touched in E2E: demo scripts and configs only (no Praxis code changes)
Likely upstream files: none
POC-only shortcuts: Python mock servers, openssl cert generation, hardcoded ports
Required upstream tests: n/a for smoke harness
Docs/examples impact: n/a
Security or correctness pitfalls:
  - X.509 v3 extensions required for rustls/webpki
  - Reserved header rejection already exists at protocol layer
Open questions:
  - For G2G-E2E-02: should grid_ingress_trust also strip non-reserved internal
    headers, or is the reserved header system sufficient?
```

### Constraints discovered for G2G-E2E-02

1. **Peer identity blocker**: Confirmed. `SslDigest` has `organization`,
   `serial_number`, `cert_digest` but none are exposed to `HttpFilterContext`.
   G2G-E2E-02 must add extraction in `request_filter/mod.rs`.

2. **Reserved header stripping is protocol-level, not filter-level**: The
   `grid_ingress_trust` filter cannot rely on seeing `x-praxis-*` headers from
   public clients — they are already rejected. The filter's role is to validate
   peer identity on grid listeners, not to strip headers from public listeners.

3. **Upstream reserved header stripping**: `strip_reserved_internal` runs in
   `upstream_request_filter` and removes all `x-praxis-*` headers before
   forwarding. For gateway-to-gateway internal metadata, G2G-E2E-02/03 will
   need to either: (a) inject headers after the strip phase, (b) use a
   different prefix not in the reserved list, or (c) conditionally skip
   stripping for gateway clusters.

## G2G-E2E-02 results

### Files changed in Praxis E2E worktree

| File | Change |
| --- | --- |
| `filter/src/context.rs` | Added `TlsPeerIdentity` struct and `peer_identity` field to `HttpFilterContext` |
| `filter/src/lib.rs` | Exported `TlsPeerIdentity`; added `peer_identity: None` to test utility |
| `filter/src/builtins/http/security/grid_ingress_trust.rs` | New `grid_ingress_trust` filter (10 unit tests) |
| `filter/src/builtins/http/security/mod.rs` | Added module and re-export |
| `filter/src/builtins/http/mod.rs` | Added re-export |
| `filter/src/builtins/mod.rs` | Added re-export |
| `filter/src/registry.rs` | Registered filter; added registry test assertion |
| `protocol/src/http/pingora/context.rs` | Added `peer_identity` field to `PingoraRequestCtx`; wired into `filter_context!` macro |
| `protocol/src/http/pingora/handler/request_filter/mod.rs` | Extract peer identity from `SslDigest` during request setup |
| `benchmarks/microbenchmarks/common.rs` | Added `peer_identity: None` to bench context constructor |
| `filter/ext-proc/src/tests.rs` | Added `peer_identity: None` to ext-proc test context constructor |
| `docs/filters/http/security/grid_ingress_trust.md` | Generated filter doc |
| `docs/filters/reference.md` | Updated with new filter entry |

### Files changed in spike repo

| File | Change |
| --- | --- |
| `configs/site-a.yaml` | Added `grid-trust` chain to grid listener |
| `configs/site-b.yaml` | Added `grid-trust` chain to grid listener |
| `configs/site-c.yaml` | Added `grid-trust` chain to grid listener |
| `scripts/generate-certs.sh` | Added untrusted client cert generation (O=wrong-org) and unknown-CA client cert generation |
| `scripts/run-demo.sh` | Added untrusted-peer and unknown-CA rejection assertions; removed 2 now-implemented skip entries |

### Validated assertions (21 pass, 0 fail, 5 not-yet-implemented)

| # | Assertion | Result |
| --- | --- | --- |
| 1-9 | All nine mock backends respond to GET / | PASS |
| 10 | POST /v1/chat/completions through site-a → site-a inference mock | PASS |
| 11 | GET / through site-a → site-a inference mock health | PASS |
| 12 | site-b grid :18110 rejects plain HTTP | PASS (expected failure) |
| 13 | site-b grid :18110 rejects HTTPS without client cert | PASS (expected failure) |
| 14 | site-c grid :18120 rejects plain HTTP | PASS (expected failure) |
| 15 | site-b grid accepts trusted site-a client cert (grid_ingress_trust) | PASS |
| 16 | site-c grid accepts trusted site-a client cert (grid_ingress_trust) | PASS |
| 17 | site-b grid rejects untrusted org (CA-valid, wrong org) with 403 | PASS (expected failure) |
| 18 | site-c grid rejects untrusted org (CA-valid, wrong org) with 403 | PASS (expected failure) |
| 19 | site-b grid rejects unknown-CA client cert | PASS (expected failure) |
| 20 | site-c grid rejects unknown-CA client cert | PASS (expected failure) |
| 21 | x-praxis-grid-origin from public client rejected (400) | PASS (expected failure) |

### Extraction notes

```text
Extraction target: G2G-01 peer identity + G2G-02 ingress trust
Validated behavior:
  - SslDigest organization/serial/digest extracted and exposed to filters
  - grid_ingress_trust accepts trusted peers, rejects untrusted/missing
  - CA-valid cert with wrong org rejected at filter level (not TLS level)
  - unknown-CA client cert rejected by mTLS before trust filter authority
Files touched in E2E:
  - filter/src/context.rs (TlsPeerIdentity, peer_identity field)
  - protocol/src/http/pingora/handler/request_filter/mod.rs (extraction)
  - protocol/src/http/pingora/context.rs (carry + macro plumbing)
  - filter/src/builtins/http/security/grid_ingress_trust.rs (filter)
  - filter/src/registry.rs (registration)
Likely upstream files: same as E2E files (clean extraction)
POC-only shortcuts:
  - Organization-based matching only (no SAN parsing)
  - No logging of cert digest or serial for audit
  - Untrusted and unknown-CA cert tests use openssl-generated certs
Required upstream tests:
  - Unit tests for TlsPeerIdentity (equality, clone)
  - grid_ingress_trust config validation (empty list, empty fields, no-fields, valid)
  - grid_ingress_trust trust decisions (accept, reject-no-identity, reject-wrong-org, serial matching)
  - Integration test: mTLS listener with grid_ingress_trust config
  - Example config in examples/configs/security/
Docs/examples impact:
  - Generated filter docs (grid_ingress_trust.md, reference.md)
  - Example config needed for upstream
  - TLS operating doc update for peer identity
Security or correctness pitfalls:
  - Peer identity comes from SslDigest, not request headers
  - Empty trusted_peers rejected at config time (fail-closed)
  - SAN parsing not included; org matching is POC-only
Open questions:
  - Should upstream G2G-01 add SAN parsing in the same PR or a follow-up?
  - Should peer_identity be a typed extension or a context field?
    (Context field chosen for explicitness and discoverability)
```

## G2G-E2E-03 results

### Files changed in Praxis E2E worktree

| File | Change |
| --- | --- |
| `filter/src/builtins/http/ai/grid/mod.rs` | New module — re-exports `GridRouteFilter` |
| `filter/src/builtins/http/ai/grid/route.rs` | New `grid_route` filter (17 unit tests) |
| `filter/src/builtins/http/ai/mod.rs` | Added `grid` module and re-export |
| `filter/src/builtins/http/mod.rs` | Added `GridRouteFilter` re-export |
| `filter/src/builtins/mod.rs` | Added `GridRouteFilter` re-export |
| `filter/src/registry.rs` | Registered `grid_route`; added registry test assertion |
| `filter/src/builtins/http/traffic_management/router/mod.rs` | Added guard: skip when `ctx.cluster` is already set |
| `filter/src/builtins/http/traffic_management/router/tests.rs` | Added `on_request_preserves_existing_cluster` test |
| `docs/filters/http/ai/grid_route.md` | Generated filter doc |
| `docs/filters/reference.md` | Updated with `grid_route` entry |

### Files changed in spike repo

| File | Change |
| --- | --- |
| `configs/site-a.yaml` | Added `ai-classify` and `grid-route` chains to public listener |
| `scripts/run-demo.sh` | Added 4 inference routing assertions; removed 2 not-implemented entries |

### Router conflict resolution

The router filter (`filter/src/builtins/http/traffic_management/router/mod.rs`)
now checks `ctx.cluster.is_some()` at the top of `on_request` and returns
`Continue` without overwriting the cluster. A unit test
(`on_request_preserves_existing_cluster`) proves that a prior filter's
cluster selection is preserved.

This is the preferred approach from the implementation-notes. The `grid_route`
filter runs before the router in the public listener chain. When `grid_route`
sets `ctx.cluster`, the router skips. When `grid_route` does not set a cluster
(no model header), the router handles path-based routing as before.

### Validated assertions (25 pass, 0 fail, 3 not-yet-implemented)

| # | Assertion | Result | New in E2E-03 |
| --- | --- | --- | --- |
| 1-9 | Mock backends respond | PASS | |
| 10-11 | Local routing through site-a | PASS | |
| 12-14 | mTLS enforcement on grid listeners | PASS | |
| 15-16 | grid_ingress_trust accepts trusted peer | PASS | |
| 17-18 | grid_ingress_trust rejects untrusted org | PASS | |
| 19-20 | Unknown CA rejected by mTLS | PASS | |
| 21 | Reserved header rejected on public ingress | PASS | |
| 22 | local-model routes to site-a inference mock | PASS | yes |
| 23 | site-b-model routes through site-b gateway to site-b mock | PASS | yes |
| 24 | site-c-model routes through site-c gateway to site-c mock | PASS | yes |
| 25 | unknown-model returns 404 | PASS | yes |

### Extraction notes

```text
Extraction target: G2G-03 site descriptor + G2G-04 route filter
Validated behavior:
  - Static site/model candidates control local vs remote routing
  - Model header from model_to_header drives grid_route selection
  - Router preserves prior ctx.cluster (grid_route → router composition)
  - Unknown model deterministically returns 404
  - Duplicate model candidates are rejected at config time
  - Reserved internal header prefixes are rejected for model_header config
  - Invalid/oversized model header values reject without copying the value to metadata
  - Route metadata written to filter_metadata with bounded keys/values
Files touched in E2E:
  - filter/src/builtins/http/ai/grid/route.rs (grid_route filter)
  - filter/src/builtins/http/traffic_management/router/mod.rs (cluster guard)
  - filter/src/registry.rs (registration)
Likely upstream files: same as E2E files (clean extraction)
POC-only shortcuts:
  - Static inline candidate list (no separate snapshot file)
  - No freshness, locality, or scoring
  - No MCP/A2A routing (inference only)
Required upstream tests:
  - Config validation (empty candidates, blank fields, max candidates, duplicates)
  - Config rejects reserved internal header prefixes for model_header
  - Route decisions (local, remote-b, remote-c, unknown, no header, invalid header)
  - Router cluster preservation
  - Reserved headers do not influence route
  - Route metadata is bounded
  - Integration test with model_to_header → grid_route → router pipeline
  - Example config in examples/configs/ai/
Docs/examples impact:
  - Generated filter doc (grid_route.md, reference.md)
  - Example config needed for upstream
  - Architecture doc update for grid routing concept
Security or correctness pitfalls:
  - grid_route reads X-Model from request headers, which is set by
    model_to_header from the request body. It does NOT read x-praxis-*
    or other reserved headers as routing authority.
  - model_header itself must not be configurable to x-praxis-*, x-mcp-*,
    or x-a2a-* because those prefixes are reserved for internal/protocol
    metadata.
  - Route metadata written via ctx.set_metadata is bounded (64B key, 256B value)
  - Router must not overwrite a cluster set by grid_route
Open questions:
  - Should upstream G2G-04 include the router guard, or should that be
    a separate small PR?
```

## G2G-E2E-04 results

### Changes to Praxis E2E worktree

| File | Change |
| --- | --- |
| `filter/src/builtins/http/ai/grid/route.rs` | Extended with `CapabilityKind` enum, `fresh` field, deterministic scoring, `Lookup` enum for fail-closed invalid input, MCP tool matching. 21 unit tests. |
| `docs/filters/http/ai/grid_route.md` | Regenerated filter doc |
| `docs/filters/reference.md` | Updated |

### Changes to spike repo

| File | Change |
| --- | --- |
| `configs/site-a.yaml` | Added `json_rpc`/`mcp` (with `on_invalid: continue`) to ai-classify chain; extended grid_route candidates with `kind`, `fresh`, shared-model, freshness-model, equal-model, and MCP tool |
| `scripts/run-demo.sh` | Added freshness, local-preference, and MCP assertions; reduced SKIPs from 3 to 1 |

### Scoring rules

| Factor | Score |
| --- | --- |
| Fresh candidate | 0 |
| Stale candidate | -100 |
| Local site preference | +10 |
| Tie-break | First configured candidate wins (explicit loop in `select()`) |

### Review fixes applied

1. **Deterministic tie-break**: `select()` uses explicit loop returning first
   highest-scored candidate instead of `max_by_key` (which returns last equal).
2. **Fail-closed invalid input**: `Lookup` enum with `Invalid` variant rejects
   blank/oversized model headers and MCP tool names with 400 instead of skipping
   to router fallback.
3. **Separate freshness assertion**: `freshness-model` candidate pair (stale
   remote site-b, fresh remote site-c) proves freshness independently from
   local preference.
4. **Separate local-preference assertion**: `equal-model` candidate pair (remote
   first, local second, both fresh) proves local preference independently from
   freshness.

### Validated assertions (29 pass, 0 fail, 1 not-yet-implemented)

| # | Assertion | New in E2E-04 |
| --- | --- | --- |
| 1-21 | All E2E-02/03 assertions | |
| 22-25 | Inference routing (local, remote-b, remote-c, unknown) | |
| 26 | `shared-model` routes to site-a (fresh local beats stale remote) | yes |
| 27 | `freshness-model` routes to site-c (fresh remote beats stale remote) | yes |
| 28 | `equal-model` routes to site-a (local preference when otherwise equal) | yes |
| 29 | MCP `tools/call` for `weather-lookup` routes through site-c gateway | yes |

### Extraction notes

```text
Extraction target: G2G-06 scoring + G2G-07 MCP routing; A2A deferred
Validated behavior:
  - CapabilityKind enum (inference_model, mcp_tool) controls matching
  - Fresh candidates deterministically beat stale candidates
  - Pure freshness case validated separately from local preference
  - Local preference honored when scores are otherwise equal
  - MCP tools/call routes cross gateway boundary through mTLS
  - Destination grid_ingress_trust still validates peer identity
  - json_rpc/mcp filters must use on_invalid: continue for mixed traffic
Files touched in E2E:
  - filter/src/builtins/http/ai/grid/route.rs (scoring, multi-kind)
Likely upstream files: same
POC-only shortcuts:
  - Static fresh: true/false (no timestamp or TTL)
  - MCP matching only reads mcp.name for tools/call (no other methods)
  - A2A routing deferred because it needs explicit route-key semantics,
    session/task expectations, and gateway tests
  - on_invalid: continue required for mixed-traffic listeners
Required upstream tests:
  - Scoring: fresh beats stale, local preference, deterministic tie-break
  - MCP route: tools/call matched, non-tools/call skipped, unknown tool 404
  - Config: CapabilityKind enum validation, same name different kind allowed
Security or correctness pitfalls:
  - MCP tool name comes from filter_metadata (set by mcp filter from body),
    not from request headers
  - Reserved headers still ignored for route authority
  - json_rpc/mcp filters default to on_invalid: reject; mixed-traffic
    listeners must configure on_invalid: continue
Open questions:
  - Should upstream scoring use timestamps instead of boolean freshness?
  - Which A2A route keys and session/task semantics should a follow-up use?
```
