# AI Grid — Upstream PR Stack

Maps demo validation to the PRs that implement each behavior.
Use this to track what can be submitted and in what order.

---

## Praxis PRs

These implement the data-plane primitives. All four are prepared locally.

| PR | Title | Status | Depends on | Path |
|---|---|---|---|---|
| UP-G2G-01 | `feat(tls): expose downstream mTLS peer identity` | Ready | none | `prs/04-praxis-peer-identity-pr/praxis` |
| UP-G2G-02 | `feat(filter): add grid_ingress_trust peer identity enforcement` | Ready | UP-G2G-01 | `prs/06-praxis-grid-ingress-trust-pr/praxis` |
| UP-G2G-03/04 | `feat(filter): add grid_route inference routing` | Ready (hold for selector fix) | none | `prs/05-praxis-grid-route-pr/praxis` |
| UP-G2G-07 | `feat(filter): add MCP tool routing to grid_route` | Ready | UP-G2G-04 | `prs/07-praxis-grid-route-mcp-pr/praxis` |

**Root bug fixed in UP-G2G-01:** The `filter_context!` macro used `.take()` on
`peer_identity`, consuming it during pre-read body processing. Fixed with
`.clone()`. This was why `grid_ingress_trust` returned 403 despite valid certs.

---

## AI Repo PRs

| Item | Status | Blocks |
|---|---|---|
| llm-d ext_proc transfer to AI repo | Pending AI PR | GRID-03 |
| `localhost/praxis-ai:llmd-ext-proc` image | Built and present | none |
| `localhost/praxis-ai-mock-epp:latest` image | Built and present | none |
| `mock-providers`: `POST /v1/responses` | Implemented (PR candidate at `prs/14-grid-openai-responses-mock`) | nothing for core demo |

---

## Grid PRs

These implement reusable xtask infrastructure and cert library changes.
None require changes to Praxis or AI for GRID-01/02.

| PR | Title | Status | Depends on | Path |
|---|---|---|---|---|
| GRID-CI | CI: tests, supply-chain, documentation | Ready to amend | none | `prs/12-grid-basic-ci/grid` |
| GRID-01 | cert identity + .gitignore | Ready | none | `prs/10-grid-01-cert-identity-dry-run/grid` |
| GRID-02 | inference baseline (verify-providers) | Ready | GRID-01 | `prs/13-grid-02-provider-baseline-dry-run/grid` |
| GRID-03 | gateway E2E (ext_proc + mock EPP) | Needs AI ext_proc PR | GRID-02 + AI | pending |
| GRID-04 | consumer G2G | Needs GRID-03 | GRID-03 | pending |
| GRID-05 | mTLS trust verification | Needs GRID-03 | GRID-03 | pending |
| GRID-06 | overlay mode (--overlay-config) | Needs GRID-04 | GRID-04 | pending |
| GRID-DOCS | multi-cluster demo plan | After GRID-06 | GRID-06 | pending |
| GRID-14 | mock-providers /v1/responses | Independent | none | `prs/14-grid-openai-responses-mock/grid` |

---

## Operator PRs

These implement production control-plane reconciliation.
All are independent of the Grid demo PR order.

| PR | Title | Status | Tests |
|---|---|---|---|
| OPERATOR-01 | routing overlay renderer | Ready | 56 tests (dry-run at `prs/11-operator-01-overlay-renderer-dry-run/grid`) |
| OPERATOR-02 | InferenceProvider controller | Ready after OPERATOR-01 | +14 tests |
| OPERATOR-03 | overlay bridge helper | Ready after OPERATOR-01 | +11 tests |
| OPERATOR-BLOCKED | gateway annotation patching | Blocked — target k8s object type unknown | — |

---

## Submission order

```
Independent (submit any order):
  Praxis UP-G2G-01, UP-G2G-03/04
  Operator OPERATOR-01

After UP-G2G-01:
  Praxis UP-G2G-02

After UP-G2G-03/04:
  Praxis UP-G2G-07

After AI ext_proc PR:
  Grid GRID-03, GRID-04, GRID-05, GRID-06

After OPERATOR-01:
  OPERATOR-02, OPERATOR-03
```

---

## What this demo proves about the upstream PRs

| Demo | PR validated |
|---|---|
| Provider inference baseline | GRID-02 (xtask env up, verify-providers) |
| Provider gateway ext_proc | GRID-03 (ext_proc path), AI (image) |
| Consumer G2G static | GRID-04 (consumer gateway), Praxis UP-G2G-03/04 (grid_route) |
| Consumer G2G overlay | GRID-06 (operator_overlay.rs), OPERATOR-01/03 (wire format) |
| mTLS trust | GRID-05 (verify-mtls-trust), Praxis UP-G2G-01/02 (peer identity + ingress trust) |
| /v1/responses mock | GRID-14 (mock-providers) |

---

## Split rules

- Do not merge the full demo stack into a single PR.
- Grid xtask / demo tooling changes do not belong in Praxis PRs.
- Operator overlay logic does not belong in Grid demo scripts.
- This research-spikes repo stores demo evidence and assets only; do not
  copy production-planning notes or implementation code here.
