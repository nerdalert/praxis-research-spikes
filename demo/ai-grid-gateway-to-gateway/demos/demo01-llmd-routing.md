# Demo 1 -- llm-d Two-Provider Model Routing

End-to-end proof that the AI Grid routes Chat Completions requests to the
correct provider cluster through the full llm-d path: ext\_proc, mock EPP,
endpoint\_selector, and the Grid Operator overlay -- across a two-provider
kind topology with mTLS and mock-openai backends.

---

## Prerequisites

| Requirement | Version / Notes |
|---|---|
| Rust stable | 1.96+ (edition 2024) |
| Rust nightly | `nightly-2026-03-28` (for `rustfmt`) |
| Docker | Running; able to pull / build images |
| kind | Installed and on `$PATH` |
| kubectl | Installed and on `$PATH` |
| curl | Installed (used by xtask for HTTP probes) |
| Free ports | 10011--10014 (mock providers), plus ephemeral ports for port-forwards |

Ensure no existing kind clusters named `grid-site-east`, `grid-site-west`,
or `grid-consumer` are running before starting.

### Container images

The gateway images must be built locally before the first run.  From the
`grid/` directory:

```console
cargo xtask env build-gateway-images
```

This builds `localhost/praxis-ai:llmd-ext-proc` and
`localhost/praxis-ai-mock-epp:latest`.

---

## Topology

```text
                +-----------------------------------------+
                |  site-east  (provider)                   |
                |  +----------------+  +----------------+ |
                |  | Praxis AI gw   |  | mock-openai    | |
     +--------->|  | ext_proc path  |->| model-east     | |
     |          |  | mock EPP       |  |                | |
     |          |  +----------------+  +----------------+ |
     |          +-----------------------------------------+
     |
client --> consumer (grid_route + load_balancer)
     |
     |          +-----------------------------------------+
     |          |  site-west  (provider)                   |
     |          |  +----------------+  +----------------+ |
     +--------->|  | Praxis AI gw   |  | mock-openai    | |
                |  | ext_proc path  |->| model-west     | |
                |  | mock EPP       |  |                | |
                |  +----------------+  +----------------+ |
                +-----------------------------------------+
```

Three kind clusters:

- **site-east** -- provider; serves `model-east` via `mock-openai`.
- **site-west** -- provider; serves `model-west` via `mock-openai`.
- **consumer** -- consumer; routes to both provider gateways based on model
  name, using the Grid Operator overlay.

All consumer-to-provider traffic crosses mTLS enforced by the Grid CA and
the `grid_ingress_trust` Praxis filter.

---

## Setup

All commands run from the `grid/` directory.

### 1. Create kind clusters and deploy backends

```console
cargo xtask env up -c tests/env/operator-routing-two-provider.toml
```

This creates three kind clusters (`grid-site-east`, `grid-site-west`,
`grid-consumer`), deploys `mock-openai` backend pods in each provider
cluster, and generates mTLS certificates.

### 2. Load gateway images into kind clusters

```console
cargo xtask env load-gateway-images -c tests/env/operator-routing-two-provider.toml
```

Loads `localhost/praxis-ai:llmd-ext-proc` and
`localhost/praxis-ai-mock-epp:latest` into all three kind clusters.

### 3. Verify baseline (optional)

```console
cargo xtask env status -c tests/env/operator-routing-two-provider.toml
```

Confirms all clusters and pods are healthy before running the full proof.

---

## Validation command

```console
cargo xtask env verify-demo1-llmd-routing \
  -c tests/env/operator-routing-two-provider.toml
```

The `-c` flag can be omitted; it defaults to
`tests/env/operator-routing-two-provider.toml`.

This single command orchestrates the entire Demo 1 proof:

1. **Deploy provider gateways** -- deploys Praxis AI with ext\_proc +
   mock EPP + endpoint\_selector on site-east and site-west.
2. **Operator reconcile + overlay export** -- installs Grid CRDs, applies
   per-site InferenceProvider fixtures, spawns the operator, waits for
   reconciliation, and exports the routing overlay ConfigMap.
3. **Verify provider-side llm-d path** -- sends mTLS Chat Completions
   requests directly to each provider gateway, proving the full llm-d
   chain: ext\_proc calls mock EPP, mock EPP sets
   `x-gateway-destination-endpoint`, endpoint\_selector routes to the
   mock-openai backend.
4. **Deploy consumer gateway** -- deploys the consumer Praxis AI gateway
   with `grid_route` and `load_balancer` filters configured from the
   operator overlay.
5. **Verify consumer routing + model names** -- sends plaintext requests
   through the consumer gateway for each model, asserts HTTP 200, and
   verifies the response JSON `model` field matches the requested model.
   Also sends an unknown model request and asserts a clean 404 or 503.
6. **Pod restart check** -- queries all three clusters for pods with
   non-zero restart counts.

---

## Expected output

Successful output ends with a proof summary table:

```text
demo1: [1/6] deploying provider gateways...
  ...
demo1: [2/6] operator reconcile + overlay export...
  ...
demo1: [3/6] verifying provider-side llm-d path...
  ...
demo1: [4/6] deploying consumer gateway from overlay...
  ...
demo1: [5/6] verifying consumer routing + model names...
  ...
demo1: [6/6] checking for unexpected pod restarts...

## Demo 1 llm-d Routing Proof

| Step | Result | Evidence |
|---|---|---|
| provider gateways | **PASS** | 2 sites deployed |
| operator reconcile | **PASS** | overlay for 2 sites |
| provider llm-d path | **PASS** | ext_proc + mock EPP + endpoint_selector verified |
| consumer deploy | **PASS** | deployed from operator overlay |
| consumer routing | **PASS** | all models routed correctly, unknown model fails cleanly |
| response model field | **PASS** | model-east, model-west |
| pod restarts | **PASS** | 0 restarts across all clusters |

demo1: ALL proof points PASS
```

Exit code is 0 on full PASS, non-zero if any proof point fails.

---

## Interpretation

Each row in the table corresponds to a distinct proof point:

| Proof point | What it proves |
|---|---|
| provider gateways | Praxis AI gateway + mock EPP + endpoint\_selector deployed and ready on both provider sites |
| operator reconcile | Grid Operator generates a valid routing overlay with candidates for every provider site |
| provider llm-d path | The full llm-d filter chain works on each provider: ext\_proc calls mock EPP for backend selection, endpoint\_selector uses the EPP response, request reaches mock-openai |
| consumer deploy | Consumer gateway starts from the operator-generated overlay without manual config |
| consumer routing | End-to-end: client request enters consumer, grid\_route selects the correct provider site, load\_balancer forwards over mTLS, provider gateway processes the request, mock-openai responds HTTP 200 |
| response model field | The response body `model` field matches the requested model, confirming the right backend served the request |
| pod restarts | No pods crashed during the test run, ruling out transient failures |

---

## Cleanup

Tear down all clusters:

```console
cargo xtask env down -c tests/env/operator-routing-two-provider.toml
```

This deletes the three kind clusters (`grid-site-east`, `grid-site-west`,
`grid-consumer`) and all associated resources.

To remove only a single cluster:

```console
kind delete cluster --name grid-site-east
```

---

## What this demo proves

- The **full llm-d routing path** works end-to-end: ext\_proc filter calls
  mock EPP for backend selection, mock EPP sets the
  `x-gateway-destination-endpoint` header, endpoint\_selector routes the
  request to the mock-openai backend.

- The **Grid Operator** reconciles multiple InferenceProvider CRDs across
  separate provider clusters and generates a single routing overlay with
  scored candidates for every provider site.

- The **consumer gateway** routes requests by model name to the correct
  provider site using `grid_route` and `load_balancer` filters, with
  routing configuration derived entirely from the operator overlay.

- **mTLS trust** is enforced on all consumer-to-provider traffic via the
  Grid CA and the `grid_ingress_trust` filter.

- **Model name fidelity** is preserved: the response JSON `model` field
  matches the model the client requested, proving the correct backend
  served the request.

- **Mock-openai backend** demonstrates that the architecture is compatible
  with real OpenAI-compatible inference servers, not just the
  inference-sim test fixture.

## What this demo does not prove

- **SWIM/CRDT distributed state propagation.** The overlay is generated
  from direct operator reconciliation, not from SWIM gossip.  CRDT/SWIM
  routing is proved separately by `verify-swim-routing`.

- **Scoring-based provider selection.** All candidates have equal locality
  and no live metrics, so the scoring engine does not differentiate.  The
  scoring proof is covered by `validate-operator-routing` with the
  single-provider config.

- **Production TLS termination.** The consumer gateway listens on
  plaintext HTTP.  Only the consumer-to-provider hop uses mTLS.

- **Dynamic provider health changes.** All providers remain healthy
  throughout the test.  Degraded-provider and API-fallback paths are
  covered by separate validation commands.

- **Multi-model per site.** Each provider site serves exactly one model.
  Multi-model routing within a single site is validated elsewhere.

- **Real inference latency or throughput.** The mock-openai backend returns
  canned responses immediately.  No load testing is performed.

---

## Failure modes and recovery

| Symptom | Likely cause | Recovery |
|---|---|---|
| `kind cluster not found` | Clusters not created or deleted | `cargo xtask env up -c tests/env/operator-routing-two-provider.toml` |
| `image not found` | Gateway images not loaded | `cargo xtask env load-gateway-images -c tests/env/operator-routing-two-provider.toml` |
| `operator reconcile failed` | CRD not installed or operator binary not built | `cargo build -p operator` then retry |
| `consumer routing FAIL` | Overlay missing or consumer gateway not ready | Check `kubectl --context kind-grid-consumer get pods` |
| `response model field FAIL` | Backend returned wrong model name | Verify mock-openai is deployed correctly on the provider cluster |
| `pod restarts > 0` | OOM, crash loop, or image pull error | `kubectl --context kind-grid-<site> describe pod <pod>` |
| `provider llm-d path FAIL` | mock EPP not running or ext\_proc misconfigured | `kubectl --context kind-grid-site-east logs deploy/mock-epp` |
