# Demo 4 — Metrics-Driven Load Balancing

## Overview

Two provider sites both advertise the same model (`model-metrics-shared`).  The Grid
operator scrapes a Prometheus metric (`provider_queue_depth_normalized`) from each
provider and uses it in the scoring formula — lower queue depth scores higher and
appears first in the overlay candidate list.  The Praxis consumer gateway, reading the
overlay, routes all shared-model requests to the first (lowest-queue) candidate.

Two phases prove that the overlay ordering and routing are live and responsive to
metric changes:

- **Phase 1** — site-east queue=0.1, site-west queue=0.9 → site-east is candidate 0 → shared model routes to east
- **Phase 2** — metrics swapped (east=0.9, west=0.1) → site-west is candidate 0 → shared model routes to west

## Topology

```
Consumer (kind-grid-consumer)
  └─ model-metrics-shared → first overlay candidate
        ├─ Phase 1: gateway-site-east ──mTLS──► site-east mock-epp (queue_depth=0.1)
        └─ Phase 2: gateway-site-west ──mTLS──► site-west mock-epp (queue_depth=0.1)

Metrics server pods (in kind-grid-site-east, reachable via kubectl port-forward)
  ├─ op-e2e-mr-metrics-east → :18611 → python HTTP server serving queue_depth=0.1 (phase 1)
  └─ op-e2e-mr-metrics-west → :18612 → python HTTP server serving queue_depth=0.9 (phase 1)

Grid operator (out-of-cluster, context kind-grid-site-east)
  └─ InferenceProvider.spec.endpoint = "http://127.0.0.1:{port}"
       (port-forward bridges out-of-cluster operator to in-cluster metrics pods)
```

## Scoring Mechanism

The `queue_depth` signal weight is 3.0 (equal to `locality`).  Both providers use
`backendKind = "local"` (locality score 1.0, equal), so the queue depth signal is the
tiebreaker.  Lower queue depth → higher score → earlier position in overlay candidates.

| Phase | East queue | West queue | Overlay candidate 0 |
|---|---|---|---|
| 1 | 0.1 (low) | 0.9 (high) | site-east |
| 2 | 0.9 (high) | 0.1 (low) | site-west |

## How Metrics Reach the Operator

The operator runs out-of-cluster.  Metrics pods run inside `kind-grid-site-east`.
`kubectl port-forward` bridges the gap:

```
kubectl port-forward pod/op-e2e-mr-metrics-east 18611:8080
kubectl port-forward pod/op-e2e-mr-metrics-west 18612:8080
```

`InferenceProvider.spec.endpoint` is set to `http://127.0.0.1:18611` and
`http://127.0.0.1:18612` respectively.  The operator appends `/metrics` and scrapes:

```
# HELP provider_queue_depth_normalized Normalized provider queue depth
# TYPE provider_queue_depth_normalized gauge
provider_queue_depth_normalized 0.1
```

## Attribution Note

Both mock-epps echo the same model name in the response body, so response content alone
cannot distinguish which provider served a request.  Attribution uses structural proof:

1. The overlay candidate list is ordered by the operator based on live metric values.
2. The Praxis consumer gateway picks the first matching candidate (deterministic).
3. Therefore: overlay position 0 = traffic destination.

The xtask harness verifies:
- Overlay candidate ordering matches expected metric values (operator proof).
- `model-metrics-shared` returns HTTP 200 from the consumer after config reload (routing proof).
- Unknown model returns 404/503 (clean failure path).

## Prerequisites

1. Two-provider kind environment ready:

   ```bash
   cargo xtask env up -c tests/env/operator-routing-two-provider.toml
   cargo xtask env load-gateway-images -c tests/env/operator-routing-two-provider.toml
   ```

2. `grid-mock-providers:latest` image available locally (for mock-epp):

   ```bash
   docker build -t grid-mock-providers:latest -f mock-providers/Containerfile .
   ```

## Validation Command

```bash
cargo xtask env verify-metrics-routing -c tests/env/operator-routing-two-provider.toml
```

## Expected PASS Output

```
verify-metrics-routing: loading two-provider config...
  east=site-east (model-east), west=site-west (model-west), shared=model-metrics-shared
verify-metrics-routing: [1/7] deploying provider gateways...
  [PASS] provider gateway ready in kind-grid-site-east
  [PASS] provider gateway ready in kind-grid-site-west
  [OK] mock-epp patched in site-east to also serve "model-metrics-shared"
  [OK] mock-epp patched in site-west to also serve "model-metrics-shared"
  [OK] site-east mock-epp ready with shared model route
  [OK] site-west mock-epp ready with shared model route
verify-metrics-routing: [2/7] installing CRDs and cleaning stale resources...
  [OK] Grid CRDs installed
  [OK] stale metrics-routing resources removed
verify-metrics-routing: [3/7] phase 1 — east=0.1, west=0.9...
  [OK] metrics-routing pods applied (op-e2e-mr-metrics-east: queue=0.1, op-e2e-mr-metrics-west: queue=0.9)
  [OK] op-e2e-mr-metrics-east Pod ready
  [OK] op-e2e-mr-metrics-west Pod ready
  [OK] port-forward 18611 → op-e2e-mr-metrics-east:8080
  [OK] port-forward 18612 → op-e2e-mr-metrics-west:8080
  [OK] metrics-routing fixtures applied (op-e2e-mr-east@site-east/18611, op-e2e-mr-west@site-west/18612)
  [OK] op-e2e-mr-east phase = Pending
  [OK] op-e2e-mr-west phase = Pending
  [OK] overlay ConfigMap grid-overlay-op-e2e-metrics-routing-net-op-e2e-gw exists
  [OK] metrics-routing overlay order: site-east (pos 0, lower queue) before site-west (pos 1, higher queue)
  [OK] phase 1 overlay: site-east (low queue) before site-west (high queue)
  [PASS] consumer gateway ready in kind-grid-consumer
  [OK] overlay first candidate for "model-metrics-shared": site="site-east" (expected)
  [PASS] consumer gateway reachable via port-forward
  [PASS] "model-metrics-shared" returns 200 (attributed to "site-east" — overlay position 0)
  [PASS] unknown model fails cleanly
verify-metrics-routing: [4/7] flipping metrics — east=0.9, west=0.1...
  [OK] metrics-routing pods applied (op-e2e-mr-metrics-east: queue=0.9, op-e2e-mr-metrics-west: queue=0.1)
  [OK] op-e2e-mr-metrics-east Pod ready
  [OK] op-e2e-mr-metrics-west Pod ready
  [OK] port-forward 18611 → op-e2e-mr-metrics-east:8080
  [OK] port-forward 18612 → op-e2e-mr-metrics-west:8080
  [OK] bumped op-e2e-metrics-routing-net annotation to force reconcile
  [OK] overlay ConfigMap grid-overlay-op-e2e-metrics-routing-net-op-e2e-gw exists
  [OK] metrics-routing overlay order: site-west (pos 0, lower queue) before site-east (pos 1, higher queue)
  [OK] phase 2 overlay: site-west (now low queue) before site-east (now high queue)
  [PASS] consumer gateway ready in kind-grid-consumer
  [OK] overlay first candidate for "model-metrics-shared": site="site-west" (expected)
  [PASS] consumer gateway reachable via port-forward
  [PASS] "model-metrics-shared" returns 200 (attributed to "site-west" — overlay position 0)
  [PASS] unknown model fails cleanly
verify-metrics-routing: [5/7] cleaning up...
  [OK] stale metrics-routing resources removed
verify-metrics-routing: [6/7] checking for unexpected pod restarts...
  [OK] site-east: no pod restarts
  [OK] site-west: no pod restarts
verify-metrics-routing: [7/7] summarising results...
verify-metrics-routing: PASS — overlay order and routing flipped correctly when metrics values were swapped
```

## What This Proves

| Proof Point | Evidence |
|---|---|
| Operator reads `provider_queue_depth_normalized` | Phase 1 overlay: site-east (queue=0.1) at pos 0 |
| Lower queue depth → higher scoring → earlier overlay position | Pos 0 is always the lower-queue site |
| Consumer routes to overlay position 0 (shared model) | `model-metrics-shared` returns 200 from consumer |
| Overlay flip when metrics flip | Phase 2: site-west (now queue=0.1) moves to pos 0 |
| Consumer routing flips after overlay reload | `model-metrics-shared` returns 200 routed to west |
| Unknown model fails cleanly | `nonexistent-model-xyz` returns 404/503 (both phases) |
| No unexpected pod restarts | pod restart counts = 0 on both sites |

## Metrics Flip Mechanism

Python metrics pods serve a static hardcoded gauge value and cannot be updated in-place.
The harness:

1. Force-deletes both pods (`--force --grace-period=0`)
2. Recreates them with swapped queue depth values
3. Restarts both port-forwards
4. Spawns a new operator instance
5. Bumps a `last-reconcile-ts` annotation on the `GridNetwork` to force immediate
   reconcile (xtask validation synchronization only — not a production mechanism)
6. Waits 5 seconds for the operator to rescrape and update the overlay

## What This Does Not Prove

| Capability | Status |
|---|---|
| Continuous live metric scraping (no restart) | Not proven — pod recreation required to change values |
| CRDT propagation of queue depth across peers | Not proven — single-cluster operator |
| kv_cache and prefix_cache signals | Not proven — only queue_depth tested |
| Cost signal interaction with metrics | Not proven — all providers use default cost |
| Metrics scraping over mTLS | Not proven — port-forward bypasses in-cluster TLS |
| Auto-recovery when a provider's metrics endpoint goes down | Not proven — no failure injection |
| Per-request dynamic scoring rebalancing | Not proven — overlay is updated per operator run |
