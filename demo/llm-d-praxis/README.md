# llm-d Praxis Endpoint Picker and Native Gateway Demo

| Resource | Link |
|----------|------|
| Deployment Guide | [deploy.md](deploy.md) |
| Demo Scripts | [scripts/](scripts/) |
| Architecture Reference | [architecture-and-pr-stack.md](architecture-and-pr-stack.md) |
| Sample Output | [sample-output.md](sample-output.md) |
| Praxis Branch | [`e2e-llm-d-epp`](https://github.com/nerdalert/praxis/tree/e2e-llm-d-epp) |

## What This Demo Proves

This demo validates the implemented Praxis-native llm-d endpoint picker path
and provides material for explaining Praxis as the native llm-d endpoint picker
and AI gateway path. The runnable examples use Praxis as the user-facing proxy
with the `llmd_endpoint_picker` filter. That filter understands llm-d concepts:
model-aware routing, load-based scoring, KV-cache utilization, InferencePool
discovery, Gateway API HTTPRoute discovery, prefix-cache affinity,
saturation/admission, P/D role hints, InferenceModelRewrite, and
InferenceObjective metadata.

The client sends standard OpenAI-compatible requests. Praxis handles model
resolution, endpoint scoring, policy lookup, admission decisions, and upstream
selection internally.

## Architecture

```
Praxis Native Architecture (Runnable Demo):

  Client
    -> Praxis (llmd_endpoint_picker filter)
        - model extraction from request body
        - InferencePool pod discovery
        - Gateway API HTTPRoute discovery
        - vLLM-compatible metrics scraping
        - load + KV-cache + prefix scoring
        - saturation gating
        - P/D role routing
        - InferenceModelRewrite
        - InferenceObjective metadata and priority
        -> selected vLLM or llm-d-inference-sim backend
    <- response
```

The native demo path is one proxy process with no Envoy, no `ext_proc` hop,
and no external EPP process.

## Feature Matrix

| # | Example | Backend | K8s Objects | llm-d Feature | Limitations |
|---|---------|---------|-------------|---------------|-------------|
| 1 | Static model-aware baseline | Real sim | Deployment, Service, ConfigMap | Model-based endpoint filtering | Static endpoints only |
| 2 | Load-aware routing | Real sim | Deployment, Service, ConfigMap | Queue + KV-cache scoring with metrics scraping | Uses `llm-d-inference-sim` fake metrics for deterministic demo load |
| 3 | InferencePool discovery | Real sim | Deployment, InferencePool CRD, RBAC | v1alpha2 CRD pod discovery | Demo uses discovery-only config |
| 4 | Gateway API HTTPRoute | Real sim | HTTPRoute, InferencePool CRD, RBAC | HTTPRoute -> InferencePool wiring | Read-only; no Gateway controller |
| 5 | Prefix-cache-aware routing | Mock | Deployment (echo) | Approximate prefix-cache scoring | In-memory LRU index, not real KV-cache |
| 6 | Saturation/admission gate | Real sim | Deployment, ConfigMap | Pool + endpoint saturation gating | Uses `llm-d-inference-sim` fake metrics for deterministic saturation |
| 7 | P/D disaggregation | Real sim | Deployment | Prefill/decode role selection | Role-based routing proven; header injection verified via logs |
| 8 | InferenceModelRewrite | Real sim | Deployment, InferenceModelRewrite CRD, RBAC | Request body model field rewrite | Weighted targets are not deterministic in demo output |
| 9 | InferenceObjective | Real sim | Deployment, InferenceObjective CRD, RBAC | Priority metadata and objective-aware admission support | Runnable demo proves metadata; objective-aware admission is covered by Rust integration tests |

## Simulator Fake Metrics

Several examples use `fake-metrics`, which is a testing feature of
`llm-d-inference-sim`.

The simulator:

- reads `fake-metrics` from its config file;
- exposes those values as vLLM-style Prometheus metrics on `/metrics`;
- lets the demo create idle, busy, healthy, and saturated endpoints
  without generating real GPU load.

Praxis:

- scrapes the simulator `/metrics` endpoint exactly like any real
  vLLM/SGLang metrics endpoint;
- does not know whether the values came from fake simulator config
  or real backend load;
- updates its endpoint snapshot from the scraped queue and KV-cache
  values;
- runs the same load-aware scorer and saturation gate either way.

Production:

- uses real model-serving backends instead of fake simulator load;
- relies on actual queue depth, running request, and KV-cache metrics;
- does not need `fake-metrics`.

The examples that intentionally use fake metrics as the proof mechanism are:

- **Example 2: Load-aware routing** - `sim-a` is configured idle and
  `sim-b` is configured busy, so Praxis should route to `sim-a`.
- **Example 6: Saturation/admission** - one manifest configures a
  mixed healthy/saturated pool and another configures both endpoints
  saturated to prove HTTP 429 rejection.

| Demo file | Fake metric purpose |
|-----------|---------------------|
| `manifests/02-load-aware.yaml` | `sim-a` idle, `sim-b` busy; proves load-aware scoring selects `sim-a`. |
| `manifests/06-saturation.yaml` | `sim-a` healthy, `sim-b` saturated; proves saturated endpoint filtering. |
| `manifests/06b-saturation-reject.yaml` | both endpoints saturated; proves pool-level HTTP 429 rejection. |

Other simulator-backed examples may include neutral `fake-metrics`
values so `/metrics` exists, but the fake load is not the main proof.

## Architecture Reference

The detailed architecture and upstream PR stack reference for this demo is:

```text
architecture-and-pr-stack.md
```

## Prerequisites

See [deploy.md](deploy.md) for full setup instructions.

Quick version:

- Docker 29+, kind 0.20+, kubectl 1.28+
- Rust stable 1.94+ (for building Praxis)
- Go 1.21+ (for building llm-d-inference-sim)
- Local clones of Praxis and llm-d-inference-sim

---

## Example 1: Static Model-Aware Baseline

**Purpose:** Prove that Praxis extracts the `model` field from an
OpenAI-compatible request body and routes only to endpoints that
serve that model.

**llm-d feature:** Model-based endpoint filtering.

**Backend:** Real `llm-d-inference-sim` with `fake-model` in echo mode.

**Setup:**

Two simulator deployments (sim-a, sim-b) both serving `fake-model`.
Praxis configured with static endpoints pointing to each service.

**Request:**

```bash
curl -s http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** HTTP 200 with a real simulator response
containing a UUID `chatcmpl-*` ID, `kv_transfer_params`, and
`usage.prompt_tokens_detail`.

**Known limitations:** Both endpoints serve the same model. To prove
model filtering, a request for a non-existent model should return an
error. The script sends a `missing-model` request to verify this.

---

## Example 2: Load-Aware Routing

**Purpose:** Prove that Praxis scrapes vLLM/llm-d-compatible
`/metrics` endpoints and prefers the lower-pressure endpoint
(`sim-a`).

**llm-d feature:** Queue + KV-cache scoring with configurable weights,
background metrics scraping via `vllm:num_requests_running`,
`vllm:num_requests_waiting`, and `vllm:kv_cache_usage_perc`.

**Backend:** Real `llm-d-inference-sim` with asymmetric
`fake-metrics` configuration.

`fake-metrics` is a simulator-only testing utility. The simulator
turns the configured values into vLLM-style Prometheus output. Praxis
scrapes those values normally and does not know they are fake.

**Setup:**

- sim-a: `running=0, waiting=0, kv-cache=0.0` (idle)
- sim-b: `running=5, waiting=2, kv-cache=0.5` (loaded)

Praxis scrapes both endpoints every 1 second.

**Validation flow:**

1. Praxis worker scrapes `sim-a` (idle) and `sim-b` (busy).
2. The endpoint snapshot updates queue and KV-cache state.
3. The load-aware scorer penalizes `sim-b` pressure.
4. `sim-a` is selected for incoming client requests.

**Request:**

```bash
curl -s http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** HTTP 200. The response should consistently come
from sim-a (the idle endpoint) because it scores higher. The script
sends multiple requests and checks that all route to the same backend
by examining the response content (echo mode returns the content back).

**Known limitations:** The asymmetric metrics are baked into the sim
config, not driven by real request load. This proves the scoring
algorithm works with vLLM-compatible metric formats. In production,
real vLLM/SGLang load would generate the metrics.

---

## Example 3: InferencePool Discovery

**Purpose:** Prove that Praxis discovers pod endpoints from an
InferencePool CRD (v1alpha2) without any static endpoint
configuration.

**llm-d feature:** Kubernetes InferencePool discovery with label
selector, pod IP extraction, metrics scraping via pod IP.

**Backend:** Real `llm-d-inference-sim` pods labeled for pool membership.

**Setup:**

- InferencePool CRD installed
- InferencePool `sim-pool` with selector `app=llm-d-sim,pool=sim-pool`
- Two sim pods with matching labels
- ServiceAccount + ClusterRole + ClusterRoleBinding for Praxis
- No static endpoints in Praxis config — discovery-only

**Request:**

```bash
curl -s http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** HTTP 200. Praxis discovers both pods, scrapes
metrics via pod IP, and routes to the lower-pressure pod.

**Known limitations:** The InferencePool CRD must be installed before
the Praxis pod starts. Praxis reads the CRD at startup and polls
periodically; it does not watch for changes via the K8s watch API.

---

## Example 4: Gateway API HTTPRoute

**Purpose:** Prove that Praxis reads an HTTPRoute resource, extracts
the InferencePool backendRef, and discovers endpoints through the
HTTPRoute -> InferencePool -> PodList chain.

**llm-d feature:** Gateway API HTTPRoute to InferencePool wiring.

**Backend:** Real `llm-d-inference-sim`.

**Setup:**

- HTTPRoute CRD installed (from Gateway API)
- InferencePool CRD installed
- HTTPRoute `llm-route` with backendRef pointing to InferencePool `sim-pool`
- InferencePool `sim-pool` with pod selector
- Praxis configured with `gateway_api` instead of `inference_pool`

**Request:**

```bash
curl -s http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** HTTP 200. Same routing behavior as Example 3,
but the discovery path starts from the HTTPRoute.

**Known limitations:** Praxis reads the HTTPRoute for discovery only.
It does not implement a full Gateway controller — no status updates,
no TLS termination from the HTTPRoute spec, no hostname matching.
The HTTPRoute and InferencePool CRDs must be pre-installed.

---

## Example 5: Prefix-Cache-Aware Routing

**Purpose:** Prove that Praxis tracks prefix hashes per endpoint and
show the prefix-cache-enabled request path. The KIND demo is a
narrated smoke demo; the route-change proof lives in the Praxis
integration test.

**llm-d feature:** Approximate prefix-cache scoring with stable FNV-1a
block hashing, per-endpoint LRU index, longest contiguous prefix
match, configurable prefix weight.

**Backend:** Mock echo backends (not real llm-d-inference-sim).

**Why mocks:** The prefix-cache index is an in-memory approximation
inside Praxis. It does not read the actual KV-cache state from vLLM.
The demo proves that Praxis builds the index, records which prefixes
went to which endpoints, and routes subsequent matching requests
to the same endpoint. Using mock backends isolates the prefix
routing logic from real vLLM behavior. A real vLLM backend would not
expose its KV-cache block hashes for verification.

**Setup:**

Two echo backends with different response signatures. Praxis
configured with `prefix_cache` enabled, high prefix weight, and
static endpoints. The script does not mutate nginx pods or rewrite
mock metrics during the demo.

**Request sequence:**

1. First request with prompt A — Praxis selects a backend and records
   prompt A's block hashes for that endpoint.
2. Second request with prompt A — should prefer the endpoint recorded
   for prompt A.
3. Third request with prompt B — exercises a different prompt without
   prompt A's prefix history.

**Expected response:** Request 1 and request 2 usually return the same
backend ID. Request 3 may also return the same backend because the
static scores are identical and the picker has deterministic
tie-breaking. The script calls this out explicitly so the demo does
not overclaim.

**Acceptance proof:** The stronger proof is
`llmd_endpoint_picker_prefix_cache_changes_routing` in the Praxis
integration test suite. In that test, metrics are managed by local
test servers so endpoint pressure can be changed deterministically
without tinkering with KIND pods. The test seeds a prefix, changes
backend metrics, and proves a repeated prefix can stay on the
recorded endpoint even when normal load scoring would prefer the
other endpoint.

**Known limitations:**

- The prefix index is approximate — it uses block hashing, not exact
  KV-cache state.
- The index is per-Praxis-instance, not shared across replicas.
- Block size and capacity are configurable but not tuned for
  production.
- No cache salt is implemented yet.
- The KIND demo uses mock echo backends and does not prove real
  backend KV-cache hit rates.
- Identical requests landing on the same backend are consistent with
  prefix affinity but are not conclusive proof on their own because
  deterministic baseline routing can produce the same result.

---

## Example 6: Saturation/Admission Gate

**Purpose:** Prove that Praxis rejects requests when pool-level
saturation exceeds a threshold (429) and filters out individual
saturated endpoints from the candidate set.

**llm-d feature:** Deterministic saturation/admission with
configurable KV-cache threshold, queue headroom, pool-level
rejection, and fail-open semantics.

**Backend:** Real `llm-d-inference-sim` with controlled
`fake-metrics`.

The fake metrics make the healthy, saturated, and all-saturated
states deterministic. Praxis still scrapes `/metrics` the same way it
would scrape production vLLM/SGLang metrics.

**Setup:**

Two endpoints: one healthy (low fake metrics), one saturated (high
fake KV-cache and queue depth). Praxis is configured with saturation
gate thresholds. A second manifest makes both endpoints saturated to
prove pool-level HTTP 429 rejection.

**Request:**

```bash
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** When one endpoint is saturated, requests route
to the healthy one. When both are saturated (pool-level), Praxis
returns HTTP 429.

**Known limitations:**

- Saturation is computed from scraped metrics, which are static
  simulator fake metrics in this demo. Dynamic saturation under real
  production load is not proven by the demo.
- The fail-open semantic means that if filtering removes all
  candidates, Praxis routes to any available endpoint rather than
  rejecting. This is by design but differs from strict admission
  control.

---

## Example 7: P/D Disaggregation

**Purpose:** Prove that Praxis selects a decode-role endpoint as the
upstream, selects a prefill-role endpoint separately, and injects
the `x-prefiller-host-port` header into the request sent to the
decode backend.

**llm-d feature:** Minimal prefill/decode disaggregation with
endpoint roles, decode-first selection, and prefill header
injection.

**Backend:** Real `llm-d-inference-sim` in echo mode for both
decode and prefill endpoints.

**Setup:**

Two llm-d-inference-sim deployments are configured with role labels and static
endpoint roles in the Praxis config:

- `decode-backend` with role label `decode`
- `prefill-backend` with role label `prefill`

Praxis configured with disaggregation enabled,
`inject_kv_transfer_params: false`.

**Request:**

```bash
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** HTTP 200 from the decode endpoint. The
`x-prefiller-host-port` header injection is verified via Praxis
debug logs (the simulator does not echo request headers). Role-based
routing is proven; body mutation is not claimed
(`inject_kv_transfer_params: false`).

**Sidecar clarification:** This demo does not need an EPP sidecar,
an Envoy `ext_proc` hop, or an external Go EPP process. Praxis owns
the endpoint-picking decision in process. A real production
prefill/decode deployment may still use model-serving sidecars or
helpers for KV-transfer mechanics, but those helpers are part of the
backend data plane, not the endpoint picker process that Praxis is
replacing.

**Known limitations:**

- No real prefill/decode execution happens.
- Header injection (`x-prefiller-host-port`) is verified via Praxis
  logs, not the response body.
- `inject_kv_transfer_params` is disabled; body mutation is not
  proven in this demo.
- No token counting for disaggregation decisions.
- The demo uses static endpoint role config. The implementation also supports
  `llm-d.ai/role` pod labels when endpoints are discovered through Kubernetes.

---

## Example 8: InferenceModelRewrite

**Purpose:** Prove that Praxis reads InferenceModelRewrite CRDs from
the Kubernetes API, matches the request model name against rewrite
rules, and mutates the request body `model` field before endpoint
selection.

**llm-d feature:** InferenceModelRewrite with exact/generic
precedence, weighted target selection, and body mutation.

**Backend:** Real `llm-d-inference-sim` or echo backend.

**Setup:**

- InferenceModelRewrite CRD installed
- InferenceModelRewrite resource: maps `gpt-4` -> `fake-model`
- Praxis configured with `model_rewrite` enabled and K8s API access

**Request:**

```bash
curl -s http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** HTTP 200. The upstream backend receives a
request with `"model":"fake-model"` (rewritten from `gpt-4`). The
response `model` field reflects the rewritten name.

**Known limitations:**

- Requires Praxis to have K8s API access (ServiceAccount + RBAC)
  or a fake HTTPS K8s API for the rewrite snapshot.
- Weighted selection uses `rand::random()` — not deterministic in
  demo output.
- Regex match types are not supported; only exact matches and the generic
  fallback behavior are included in this POC.

---

## Example 9: InferenceObjective

**Purpose:** Prove that Praxis reads InferenceObjective CRDs, resolves
the `x-llm-d-inference-objective` request header to a priority value,
and attaches priority metadata for routing decisions.

**llm-d feature:** InferenceObjective priority metadata.

**Status:** Priority metadata and objective-aware admission are implemented.
This runnable demo proves objective metadata resolution. Objective-aware
admission is proven by Rust integration tests because the priority value is
internal and is not echoed in the HTTP response.

The InferenceObjective CRD defines named objectives with priority.
Praxis reads the objective list, filters by poolRef, and resolves the
request header `x-llm-d-inference-objective` to a priority value.
That priority is request metadata and can adjust the saturation reject
threshold when objective-aware admission is configured.

**Backend:** Real `llm-d-inference-sim`.

**Setup:**

- InferenceObjective CRD installed
- InferenceObjective resource `high-priority` with priority 10
- Praxis configured with `inference_objective` enabled and K8s API access

**Request:**

```bash
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://localhost:30081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-llm-d-inference-objective: high-priority' \
  -d '{"model":"fake-model","messages":[{"role":"user","content":"hello"}]}'
```

**Expected response:** HTTP 200. Priority metadata is internal to
Praxis routing -- it is not echoed in the response. Praxis logs
(at debug level) show objective/priority resolution activity.

**Known limitations:**

- Priority metadata is not visible in the HTTP response; verification relies
  on HTTP 200 plus Praxis log inspection. Objective-aware admission is covered
  by Praxis integration tests.
- Full queued flow-control, fairness, eviction, and tenant accounting are not
  implemented.

---

## What Is Not Proven

This demo validates the Praxis `llmd_endpoint_picker` filter as a native path
for the useful llm-d EPP scheduling pipeline. It proves the implemented
request path with no Envoy, no `ext_proc`, and no external Go EPP process.
The following capabilities are **not proven** by this demo:

1. **Full Go EPP plugin parity.** Praxis implements the focused scheduling
   slices needed for this POC. It does not implement every Go EPP plugin,
   extension point, metric, or policy behavior.

2. **Full Gateway controller behavior.** Praxis reads HTTPRoute and
   InferencePool CRDs for discovery only. It does not implement
   Gateway status updates, TLS termination from HTTPRoute spec,
   hostname matching, or traffic splitting via HTTPRoute weights.

3. **Precise or real KV-cache prefix hits.** The demo uses the approximate
   in-memory prefix index. It does not prove tokenizer/KVEvents-based precise
   prefix cache, read actual KV block state from vLLM, or measure backend
   cache-hit rates.

4. **Dynamic load under real inference.** Metrics are static sim
   configurations. The demo proves correct scoring and routing
   given those metrics, not that the system adapts in real-time
   to changing inference load.

5. **Real prefill/decode execution.** The P/D disaggregation demo proves
   role-based selection and prefill hint propagation. It does not prove
   actual disaggregated inference execution, NIXL/RDMA, or physical KV-transfer
   data movement.

6. **P/D retry on prefill failure.** Praxis does not yet have the
   response-phase retry and request-body replay primitives needed to safely
   retry a failed prefill stage with another prefiller.

7. **Full queued flow-control.** Objective-aware admission is implemented as
   immediate admit/reject threshold adjustment. Full priority queues,
   fairness, eviction, and tenant accounting are not implemented.

8. **Multi-replica prefix-cache sharing.** The prefix index is
   per-Praxis-instance.

9. **Watch-based discovery.** Praxis polls the K8s API periodically.
   It does not use the K8s watch API for real-time pod changes.

10. **Performance benchmarks.** The demo does not prove high-concurrency SSE
    limits, TTFT improvement on large prompts, or production throughput.

11. **Non-Kubernetes packaging.** The demo uses KIND and Kubernetes manifests.
    It does not prove Ray, Slurm, or bare-metal packaging.

12. **TLS metrics scraping.** Only plain HTTP metrics scraping is supported in
    this POC.

## Quick Start

See [deploy.md](deploy.md) for copy/paste setup and demo commands.

See [sample-output.md](sample-output.md) for a pre-generated transcript.
