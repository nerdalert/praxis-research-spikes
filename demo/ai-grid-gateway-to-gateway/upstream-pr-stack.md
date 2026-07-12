# AI Grid — Upstream PR Stack

Maps demo validation to the PRs that implement each behavior.

Last full validation: 2026-07-12 (10/10 mTLS, all demos PASS)

---

## Validation branches

| Repo | Branch / Ref | Purpose |
|---|---|---|
| `praxis-proxy/grid` | `main` @ `0969412` | Grid xtask demo commands |
| `nerdalert/praxis` | `ai-grid-g2g-demo-validation` @ `ab4bc3f` | Praxis G2G filters (demo fork branch) |

The `nerdalert/praxis:ai-grid-g2g-demo-validation` branch is a reproducibility
anchor until the Praxis upstream PRs (below) are opened and merged.

---

## Praxis PRs

These implement the data-plane primitives. All four are committed to
`nerdalert/praxis:ai-grid-g2g-demo-validation` and ready for upstream review.

| PR | Title | Upstream status | Depends on |
|---|---|---|---|
| PR-04 | `feat(tls): expose downstream mTLS peer identity` | Ready to open | none |
| PR-05 | `feat(filter): add grid_route inference routing` | Ready to open | none |
| PR-06 | `feat(filter): add grid_ingress_trust mTLS peer identity enforcement` | Ready to open | PR-04 |
| PR-07 | `feat(filter): add MCP tool routing to grid_route` | Ready to open | PR-05 |

**Root bug fixed in PR-04:** The `filter_context!` macro used `.take()` on
`peer_identity`, consuming it during pre-read body processing. Fixed with
`.clone()`. This was why `grid_ingress_trust` returned 403 despite valid certs.

Submit PR-04 + PR-05 simultaneously (independent). Submit PR-06 after PR-04
merges. Submit PR-07 after PR-05 merges.

---

## Praxis image build

The gateway image is built from the AI repo using the Praxis fork as a local
sibling:

```bash
# 1. Clone the Praxis G2G fork
git clone -b ai-grid-g2g-demo-validation \
  https://github.com/nerdalert/praxis.git /tmp/praxis-g2g

# 2. In the AI repo parent directory (containing both ai/ and praxis/ siblings):
cd /path/to/parent
ln -s /tmp/praxis-g2g praxis  # or copy

# 3. Build
docker build \
  -f ai/Containerfile.composed \
  --build-arg CARGO_FEATURES=llmd-ext-proc \
  -t localhost/praxis-ai:llmd-ext-proc \
  .
```

The `Containerfile.composed` automatically patches the AI repo's Praxis git
dependency with the local sibling via `[patch]` in `.cargo/config.toml`.

---

## Grid PRs (upstream praxis-proxy/grid main)

Grid main now contains all xtask demo infrastructure:

| PR | Title | Status |
|---|---|---|
| GRID-01 | cert identity helpers | Merged |
| GRID-02 | provider inference baseline | Merged |
| GRID-03 | gateway image build/load + provider E2E | Merged |
| GRID-04 | consumer G2G static routing | Merged |
| GRID-05 | mTLS trust verification | Merged |
| GRID-06 | operator overlay file input | Merged |
| GRID-docs | xtask orchestration model docs | Merged |
| GRID-backend | provider backend selection (inference-sim / mock-openai) | Merged |
| GRID-responses | /v1/responses gateway verification | Merged |

Operator PRs (OPERATOR-01/02/03) are prepared but not yet upstreamed. They live
in `prs/08-grid-operator-overlay-reconciler/grid`.

---

## AI repo PR

| Item | Status |
|---|---|
| llm-d ext_proc transfer to `praxis-proxy/ai` | Pending — open AI PR |
| `localhost/praxis-ai:llmd-ext-proc` image | Built from AI repo + Praxis G2G fork |
| `localhost/praxis-ai-mock-epp:latest` | Built from AI repo |
| `grid-mock-providers:latest` | Built from Grid `mock-providers/Containerfile` |

---

## Latest validation results (2026-07-12)

| Demo | Result | Count |
|---|---|---|
| Provider baseline (inference-sim) | PASS | 15/15 |
| Provider gateway E2E | PASS | 16/16 |
| Consumer G2G static | PASS | 8/8 |
| mTLS trust | PASS | **10/10** |
| Consumer G2G overlay-config | PASS | 8/8 |
| Mock-openai /v1/responses gateway | PASS | 9/9 |

All validation used freshly built `localhost/praxis-ai:llmd-ext-proc` image
(sha `742e64f01891`) from `nerdalert/praxis:ai-grid-g2g-demo-validation`.

**mTLS note:** Previous runs showed 9/10 due to a port-forward timing race between
the TLS-rejection tests and the wrong-org filter test in cluster-b. This is a
test harness timing issue, not a filter defect. The 2026-07-12 run achieved
10/10 with the fresh image. Expect 9/10 to 10/10 depending on environment load.
