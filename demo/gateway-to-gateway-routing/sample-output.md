# Final E2E sample output

Frozen output from the clean demo run on 2026-06-27.

## Source revisions

- Spike repo: `praxis-research-spikes` main
- E2E worktree: `dev/gateway-to-gateway-e2e` based on `60f1041`
- E2E tasks completed: G2G-E2E-00 through G2G-E2E-05

## Command

```console
cd demo/gateway-to-gateway-routing
rm -rf certs .pids .logs
bash scripts/run-demo.sh
```

## Assertion output

```text
Mock backend health:
  PASS  mock :18001 responds
  PASS  mock :18002 responds
  PASS  mock :18003 responds
  PASS  mock :18011 responds
  PASS  mock :18012 responds
  PASS  mock :18013 responds
  PASS  mock :18021 responds
  PASS  mock :18022 responds
  PASS  mock :18023 responds

Local routing through site-a public listener:
  PASS  POST /v1/chat/completions → site-a inference mock
  PASS  GET / → site-a inference mock (health)

mTLS enforcement on grid listeners:
  PASS  site-b grid :18110 rejects plain HTTP (expected failure)
  PASS  site-b grid :18110 rejects HTTPS without client cert (expected failure)
  PASS  site-c grid :18120 rejects plain HTTP (expected failure)

grid_ingress_trust acceptance with trusted peer identity:
  PASS  site-b grid accepts trusted site-a client cert
  PASS  site-c grid accepts trusted site-a client cert

grid_ingress_trust rejection of untrusted peer identity:
  PASS  site-b grid rejects untrusted org (CA-valid, wrong org) with 403 (expected failure)
  PASS  site-c grid rejects untrusted org (CA-valid, wrong org) with 403 (expected failure)

mTLS rejection of unknown client CA:
  PASS  site-b grid rejects unknown-CA client cert (expected failure)
  PASS  site-c grid rejects unknown-CA client cert (expected failure)

Reserved header rejection on public ingress:
  PASS  x-praxis-grid-origin from public client rejected (400) (expected failure)

grid_route inference routing:
  PASS  local-model routes to site-a inference mock
  PASS  site-b-model routes through site-b gateway to site-b mock
  PASS  site-c-model routes through site-c gateway to site-c mock
  PASS  unknown-model returns 404 (no candidate) (expected failure)

Freshness and local-preference scoring:
  PASS  shared-model routes to site-a (fresh local beats stale remote)
  PASS  freshness-model routes to site-c (fresh remote beats stale remote)
  PASS  equal-model routes to site-a (local preference when otherwise equal)

MCP tool routing through grid_route:
  PASS  MCP tools/call weather-lookup routes to site-c mock

Expected not-yet-implemented features:
  SKIP  A2A request routed across gateway boundary by grid_route

=== Summary ===
  Passed:              29
  Failed:              0
  Not implemented yet: 1

RESULT: PASS (all implemented assertions passed)
```

## Unit test summary

```text
cargo test -p praxis-proxy-filter "grid::route"       — 21 passed
cargo test -p praxis-proxy-filter "grid_ingress_trust" — 10 passed
cargo test -p praxis-proxy-filter "router::tests"      — 111 passed
cargo test -p praxis-proxy-filter (full)               — 2271 passed, 25 ignored
cargo test -p praxis-proxy                             — all passed
make lint                                              — passed
cargo clippy --workspace --all-targets -- -D warnings  — passed
```

## Praxis E2E worktree changes

14 modified files, 4 new files, +101 lines from base commit `60f1041`.

New filters: `grid_ingress_trust`, `grid_route`.
New type: `TlsPeerIdentity` in `HttpFilterContext`.
Router change: preserve existing `ctx.cluster`.

## Notes

- No prompts, API keys, cert private keys, or full request bodies in output.
- A2A routing is the single remaining deferred item.
- `json_rpc`/`mcp` filters require `on_invalid: continue` for mixed-traffic listeners.
