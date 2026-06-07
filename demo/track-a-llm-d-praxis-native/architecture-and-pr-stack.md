# Track A: Praxis Native llm-d Architecture And PR Stack

Updated: 2026-06-01

This document describes the runnable Track A llm-d Praxis-native demo
architecture and the planned Praxis PR stack behind it. It is intentionally written from the demo
point of view: what is in the request path, what cluster state is read, what
each demo proves, and how the implementation should be split when it is prepared
for upstream review.

The implementation snapshot used for end-to-end review is:

- Repository: `https://github.com/nerdalert/praxis`
- Branch: `e2e-llm-d-epp`
- Purpose: native Praxis llm-d endpoint picker implementation snapshot for demo
  and E2E validation.

## Architecture Summary

Praxis is used as the user-facing AI gateway. The `llmd_endpoint_picker`
`HttpFilter` embeds the useful llm-d Endpoint Picker Provider scheduling path
inside the proxy process. A client sends normal OpenAI-compatible requests, and
Praxis reads the request body, resolves the model, applies llm-d-style endpoint
selection, and forwards directly to the selected model-serving backend.

The native request path demonstrated here is:

```text
+--------------------+       +-------------------------------------+       +--------------------------+
| OpenAI API client  | ----> | Praxis / Pingora                    | ----> | selected model backend   |
|                    |       | llmd_endpoint_picker filter          |       | vLLM, SGLang, or sim     |
+--------------------+       +-------------------------------------+       +--------------------------+
                                      |
                                      | in process
                                      v
                             +-----------------------------+
                             | model-aware filtering       |
                             | load-aware scoring          |
                             | prefix-cache scoring        |
                             | saturation/admission        |
                             | P/D role routing            |
                             | model rewrite policy        |
                             | objective priority metadata |
                             +-----------------------------+
```

This removes the demonstrated Envoy `ext_proc` hop and the external Go EPP
service from the request path. It does not claim that Praxis now owns every
backend data-plane responsibility. Model servers still execute inference, and
backend P/D data transfer remains the responsibility of the model serving stack.

## What Praxis Replaces

The current llm-d router path has a proxy and an Endpoint Picker Provider. The
proxy receives traffic. The EPP is the scheduling brain: it inspects requests,
reads endpoint state, applies routing plugins, and chooses an endpoint.

The native Praxis path moves the scheduling brain into the proxy:

| Existing llm-d role | Native Praxis role | Demo status |
|---------------------|--------------------|-------------|
| Envoy proxy receives OpenAI traffic | Praxis/Pingora listener receives OpenAI traffic | Implemented in demo |
| Envoy buffers body and calls `ext_proc` | Praxis filter reads the request body directly | Implemented |
| Go EPP extracts model and builds candidates | `llmd_endpoint_picker` extracts model and builds candidates | Implemented |
| Go EPP scores by load and policy plugins | Praxis scores by load, KV pressure, prefix affinity, saturation, role, and policy | Implemented POC slices |
| Go EPP returns routing metadata to Envoy | Praxis writes `ctx.upstream` directly | Implemented |
| Envoy forwards to selected backend | Praxis forwards to selected backend | Implemented |
| Backend model server executes inference | Backend model server executes inference | Still backend responsibility |

## System Components

| Component | Responsibility | Hot path |
|-----------|----------------|----------|
| Praxis listener | Accepts client HTTP requests and runs the filter chain. | Yes |
| `llmd_endpoint_picker` filter | Parses OpenAI request bodies, selects endpoints, mutates headers/body when needed, and sets upstream. | Yes |
| Endpoint snapshot | Immutable view of healthy endpoints, models, roles, and latest metrics. | Yes, lock-free read |
| Endpoint state worker | Scrapes metrics, polls Kubernetes objects, and publishes snapshots. | No |
| Kubernetes client | Reads `InferencePool`, `HTTPRoute`, `InferenceModelRewrite`, and `InferenceObjective`. | No |
| Prefix index | Tracks prompt-prefix to endpoint affinity in Praxis memory. | Yes |
| Saturation gate | Rejects saturated pools or filters overloaded endpoints before scoring. | Yes |
| Backend model server | Serves the OpenAI-compatible response. | Downstream of Praxis |
| `llm-d-inference-sim` | Demo backend that provides OpenAI-like responses and fake vLLM metrics. | Demo only |

## Request Path

```text
+--------------------------------------------------+
| Client sends OpenAI-compatible request           |
| Example: /v1/chat/completions with JSON model.   |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| Praxis receives request                          |
| The request enters the normal Pingora/Praxis      |
| filter chain.                                    |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| Body access                                      |
| The picker buffers enough body to parse the       |
| OpenAI JSON shape.                               |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| Policy pre-processing                            |
| InferenceModelRewrite may mutate the model field. |
| InferenceObjective may resolve request priority. |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| Candidate construction                           |
| Praxis reads the latest endpoint snapshot and     |
| keeps endpoints that are healthy and serve the    |
| effective model.                                 |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| Admission and scoring                            |
| Saturation can reject the pool or filter loaded   |
| endpoints. Remaining endpoints are scored by      |
| load, KV pressure, and prefix-cache affinity.     |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| P/D role routing                                 |
| If enabled, Praxis selects a decode endpoint as   |
| upstream and separately selects a prefill hint.   |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| Upstream selection                               |
| Praxis sets the selected backend in request       |
| context and forwards the request.                |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
| Backend response                                 |
| vLLM, SGLang, or llm-d-inference-sim generates    |
| the response, which returns through Praxis.       |
+--------------------------------------------------+
```

## Background State Flow

Praxis separates state refresh from request handling. A background worker
updates endpoint state while the hot path reads immutable snapshots.

```text
+-----------------------------+       +-----------------------------+
| Static config               |       | Kubernetes API              |
| endpoints, models, roles    |       | HTTPRoute, InferencePool,   |
| optional metrics URLs       |       | policy objects, pod list    |
+-------------+---------------+       +---------------+-------------+
              |                                       |
              v                                       v
        +-----------------------------------------------+
        | Endpoint state worker                         |
        | - discovers pods                              |
        | - scrapes /metrics                            |
        | - applies health and metric updates           |
        | - builds immutable endpoint snapshot          |
        +----------------------+------------------------+
                               |
                               v
                    +---------------------+
                    | ArcSwap snapshot    |
                    | lock-free reads     |
                    +----------+----------+
                               |
                               v
                    +---------------------+
                    | Request hot path    |
                    | scores candidates   |
                    +---------------------+
```

Important behavior:

- Static-only configuration does not need Kubernetes.
- Metrics-backed routing uses vLLM-compatible Prometheus output.
- `llm-d-inference-sim` fake metrics are used only to make demos deterministic.
- A failed scrape marks an endpoint unhealthy until a later scrape succeeds.
- Kubernetes discovery is polling-based in the POC, not a production watch loop.

## Background Worker Implementation

The background state path is implemented inside the `llmd_endpoint_picker`
filter as an owned worker, not as a separate process or sidecar. The filter
constructs an `EndpointStateHandle` at startup and keeps an optional
`EndpointStateWorker` alive for as long as the filter instance exists.

```text
+-----------------------------+
| llmd_endpoint_picker filter |
| owns worker + state handle  |
+--------------+--------------+
               |
               v
+-----------------------------+       +-------------------------------+
| EndpointStateWorker         | ----> | EndpointStateHandle          |
| background refresh loop     |       | ArcSwap<EndpointSnapshot>    |
+--------------+--------------+       +---------------+---------------+
               |                                      ^
               | publish immutable snapshot           |
               v                                      |
+-----------------------------+                       |
| Request hot path            | ----------------------+
| snapshot read, no scraping  |
+-----------------------------+
```

Worker startup is conditional. Static-only configs with no dynamic state do not
start the worker. The worker starts when at least one of these features needs
refresh work:

- an endpoint has `metrics_url`;
- `inference_pool` discovery is configured;
- `gateway_api` discovery is configured;
- `model_rewrite` is enabled;
- `inference_objective` is enabled.

Each refresh cycle follows the same order:

```text
+--------------------------+
| read previous snapshot   |
+------------+-------------+
             |
             v
+--------------------------+
| discover K8s endpoints   |
| or preserve last result  |
+------------+-------------+
             |
             v
+--------------------------+
| refresh policy snapshots |
| model rewrite/objective  |
+------------+-------------+
             |
             v
+--------------------------+
| merge static + discovered|
| endpoints, dedupe address|
+------------+-------------+
             |
             v
+--------------------------+
| scrape /metrics          |
| update health + pressure |
+------------+-------------+
             |
             v
+--------------------------+
| publish ArcSwap snapshot |
+------------+-------------+
             |
             v
+--------------------------+
| interruptible sleep      |
+--------------------------+
```

The request path never waits on Kubernetes discovery or metrics scraping. It
only calls `snapshot()` on the handle, scores the immutable endpoint list, and
sets the selected upstream. That keeps endpoint-state refresh work out of the
latency-sensitive routing path.

Failure handling is intentionally conservative:

- worker spawn failure logs a warning and leaves static endpoint state in use;
- Kubernetes discovery failure preserves the last discovered endpoints;
- metrics scrape failure marks that endpoint unhealthy but preserves prior
  numeric pressure values;
- publishing a snapshot is an atomic pointer swap, so readers always see a
  complete snapshot;
- worker shutdown uses a stop flag and joins the worker when the filter is
  dropped.

## Scheduling Pipeline

The picker behaves like a compact scheduling pipeline:

```text
+-----------------+
| request body    |
+--------+--------+
         |
         v
+-----------------+      +-----------------------+
| effective model | <--- | InferenceModelRewrite |
+--------+--------+      +-----------------------+
         |
         v
+-----------------+
| eligible models |
+--------+--------+
         |
         v
+-----------------+      +-----------------------+
| live candidates | <--- | endpoint snapshot     |
+--------+--------+      +-----------------------+
         |
         v
+-----------------+      +-----------------------+
| admission gate  | <--- | InferenceObjective    |
+--------+--------+      +-----------------------+
         |
         v
+-----------------+      +-----------------------+
| weighted score  | <--- | load, KV, prefix      |
+--------+--------+      +-----------------------+
         |
         v
+-----------------+
| selected route  |
+-----------------+
```

The current scorer is intentionally understandable:

- Model filtering is mandatory. If no endpoint serves the effective model,
  there is no eligible backend.
- Load-aware scoring penalizes running and waiting requests.
- KV-cache pressure scoring penalizes high cache utilization.
- Prefix-cache scoring rewards endpoints that recently handled matching prompt
  prefixes.
- Saturation/admission can reject the whole pool or filter overloaded
  candidates before normal scoring.
- Objective-aware admission changes the saturation threshold by priority. It
  does not implement queues or fairness.
- P/D mode selects decode as the primary upstream and a prefill endpoint as a
  hint.

## Kubernetes And Gateway API Discovery

The POC supports two Kubernetes discovery entry points.

### Direct InferencePool

```text
+----------------+      +----------------+      +----------------------+
| InferencePool  | ---> | Pod label list | ---> | endpoint snapshot    |
+----------------+      +----------------+      +----------------------+
        |                         |                         |
        | selector + ports        | ready pod IPs           | names, models,
        |                         |                         | metrics URLs
        v                         v                         v
                    +---------------------+      +-------------------+
                    | Praxis llm-d picker | ---> | selected sim pod  |
                    +---------------------+      +-------------------+
```

Praxis reads the `InferencePool`, extracts selector and port information, lists
matching pods, filters to ready/running/non-terminating pods, and builds
endpoint entries with pod IPs.

### Gateway API HTTPRoute

```text
+-----------+      +----------------+      +------------------+
| HTTPRoute | ---> | InferencePool  | ---> | selected pods    |
+-----------+      +----------------+      +------------------+
     |                     |                       |
     | backendRef          | selector + ports      | pod IPs
     v                     v                       v
              +---------------------+      +-------------------+
              | Praxis llm-d picker | ---> | selected backend |
              +---------------------+      +-------------------+
```

Praxis reads one configured `HTTPRoute`, finds the first supported
`InferencePool` backendRef, resolves that pool, and reuses direct
`InferencePool` discovery. This is read-only discovery. It is not a Gateway API
controller and does not reconcile route status.

## Policy Object Flow

### InferenceModelRewrite

```text
+----------------+      +-----------------------+      +----------------+
| client request | ---> | InferenceModelRewrite | ---> | effective model|
+----------------+      +-----------------------+      +----------------+
 original-model             K8s policy object            rewritten-model
                                      |
                                      v
                         +---------------------+      +-------------------+
                         | Praxis llm-d picker | ---> | rewritten backend|
                         +---------------------+      +-------------------+
```

Model rewrite is applied before candidate selection. That means model-aware
routing, prefix-cache scoring, saturation, and P/D routing all see the effective
model.

### InferenceObjective

```text
+----------------+      +---------------------+      +----------------+
| request header | ---> | InferenceObjective  | ---> | priority meta  |
+----------------+      +---------------------+      +----------------+
 objective name             K8s policy object           request metadata
                                      |
                                      v
                         +---------------------+
                         | saturation policy   |
                         +---------------------+
```

Objective metadata resolves from `x-llm-d-inference-objective`, with
`x-gateway-inference-objective` accepted as a fallback. PR-11 uses that priority
to adjust saturation admission thresholds. This is still immediate admit/reject,
not queued flow control.

## P/D Disaggregation Flow

```text
+--------+      +---------------------+      +-------------------+
| Client | ---> | Praxis decode pick  | ---> | decode backend    |
+--------+      +---------------------+      +-------------------+
                       |
                       +-- separately scores prefill candidates
                       +-- injects x-prefiller-host-port
                       +-- can merge kv_transfer_params into body
                       v
                +-------------------+
                | prefill endpoint  |
                +-------------------+
```

Praxis chooses the decode endpoint as the actual upstream and separately picks a
prefill endpoint. It can inject a header and, in the implementation, can merge
`kv_transfer_params` into the request body. The model server or decode-side
runtime is still responsible for actual P/D data transfer. Praxis is not a NIXL
or RDMA data-plane implementation.

## Demo Validation Architecture

The demo uses KIND and `kubectl port-forward` for local access:

```text
+---------------------+       +--------------------------+
| local terminal      | ----> | localhost:<demo port>    |
| curl + scripts      |       | kubectl port-forward     |
+---------------------+       +-------------+------------+
                                           |
                                           v
                            +-----------------------------+
                            | Praxis service/deployment   |
                            +-------------+---------------+
                                          |
                                          v
                            +-----------------------------+
                            | simulator or mock backend   |
                            +-----------------------------+
```

KIND NodePort behavior has been unreliable in this environment, so the demo
scripts prefer port-forwarding. Each demo prints the exact validation signal:
curl output, backend identity, Kubernetes object state, metrics output, or logs.

Rust integration tests are also part of the proof. The demo scenarios map to
Praxis integration tests, and Rust's fast test harness makes it practical to
validate routing, body mutation, fake Kubernetes API behavior, and managed
metrics without requiring a full cluster for every assertion.

## Demo Flow Diagrams

### 1. Static Model-Aware Baseline

Purpose: prove Praxis extracts the OpenAI `model` field and routes only to
endpoints that serve that model.

```text
+--------+      +---------------------+      +----------------------+
| Client | ---> | Praxis llm-d picker | ---> | matching model pod   |
+--------+      +---------------------+      +----------------------+
                       |
                       +-- reads JSON model field
                       +-- drops endpoints that do not serve the model
```

Validation:

- Send a request for a served model and expect HTTP 200.
- Send a request for a missing model and expect no eligible endpoint.
- Inspect response/backend identity to confirm the matching endpoint path.

### 2. Load-Aware Routing

Purpose: prove Praxis scrapes vLLM/llm-d-compatible metrics and prefers the
lower-pressure endpoint.

```text
+--------+      +---------------------+      +-------------------+
| Client | ---> | Praxis llm-d picker | ---> | lower-load sim-a  |
+--------+      +---------------------+      +-------------------+
                       ^
                       |
               +----------------+
               | /metrics scrape|
               +----------------+
                   sim-a idle, sim-b loaded
```

Validation:

- `sim-a` uses fake metrics for idle state.
- `sim-b` uses fake metrics for busy state.
- Curl shows requests route to `sim-a`.
- Metrics curl from the Praxis pod shows the pressure difference.

### 3. Kubernetes InferencePool Discovery

Purpose: prove static endpoint lists are not required in Kubernetes mode.

```text
+----------------+      +----------------+      +----------------------+
| InferencePool  | ---> | Pod label list | ---> | endpoint snapshot    |
+----------------+      +----------------+      +----------------------+
        |                         |                         |
        | selector + ports        | ready pod IPs           | names, models,
        |                         |                         | metrics URLs
        v                         v                         v
                    +---------------------+      +-------------------+
                    | Praxis llm-d picker | ---> | selected sim pod  |
                    +---------------------+      +-------------------+
```

Validation:

- Praxis config has no static endpoints.
- `kubectl get inferencepool` and pod labels show the object relationship.
- Requests route to discovered pod IP endpoints.
- Metrics still scrape after discovery.

### 4. Gateway API HTTPRoute To InferencePool

Purpose: prove the user-facing Gateway API shape can be used as the discovery
entry point.

```text
+-----------+      +----------------+      +------------------+
| HTTPRoute | ---> | InferencePool  | ---> | selected pods    |
+-----------+      +----------------+      +------------------+
     |                     |                       |
     | backendRef          | selector + ports      | pod IPs
     v                     v                       v
              +---------------------+      +-------------------+
              | Praxis llm-d picker | ---> | selected backend |
              +---------------------+      +-------------------+
```

Validation:

- Praxis is configured with `gateway_api.http_route`, not direct static
  endpoints.
- `HTTPRoute` backendRef points to `InferencePool`.
- Requests route successfully through resolved pool discovery.
- Docs state this is read-only discovery, not Gateway API conformance.

### 5. Prefix-Cache-Aware Routing

Purpose: prove repeated prompt prefixes can influence endpoint selection.

```text
+------------------+      +---------------------+      +----------------+
| repeated prompt  | ---> | prefix block hasher | ---> | prefix scores  |
+------------------+      +---------------------+      +----------------+
                                  |                           |
                                  | endpoint LRU index        | score joins
                                  v                           v
                         +---------------------+      +-------------------+
                         | Praxis llm-d picker | ---> | prefix-hit pod   |
                         +---------------------+      +-------------------+
```

Validation:

- Demo script shows the in-memory prefix index behavior and prints the
  integration-test acceptance proof.
- Praxis integration test
  `llmd_endpoint_picker_prefix_cache_changes_routing` uses managed local metrics,
  seeds a prefix, changes endpoint pressure, and proves the repeated prefix can
  override normal load scoring.
- The demo is honest that deterministic baseline routing can hide prefix effects
  in a simple KIND run.

### 6. Saturation And Admission Gate

Purpose: prove Praxis can reject a saturated pool and filter overloaded
endpoints.

```text
+--------+      +---------------------+      +-----------------------+
| Client | ---> | saturation gate     | ---> | reject or pass        |
+--------+      +---------------------+      +-----------------------+
                       |
                       +-- computes pool saturation from queue + KV
                       +-- filters overloaded endpoints with headroom
                       +-- fails open only when filtering removes all
```

Validation:

- Mixed case returns HTTP 200 from the healthy endpoint.
- Saturated case returns configured HTTP 429.
- Fake simulator metrics are used to produce deterministic saturation values.
- This is not full queueing or fairness.

### 7. Minimal P/D Disaggregation

Purpose: prove role-aware prefill/decode selection.

```text
+--------+      +---------------------+      +-------------------+
| Client | ---> | Praxis decode pick  | ---> | decode backend    |
+--------+      +---------------------+      +-------------------+
                       |
                       +-- separately scores prefill candidates
                       +-- injects x-prefiller-host-port
                       v
                +-------------------+
                | prefill endpoint  |
                +-------------------+
```

Validation:

- Demo config assigns static endpoint roles for prefill and decode.
- Request is proxied to the decode endpoint.
- Praxis logs show prefill/decode selection and the prefill hint.
- Integration tests prove header forwarding with a header-echo backend.
- Full KV transfer remains backend model-server data-plane responsibility.

### 8. InferenceModelRewrite

Purpose: prove policy-based model rewrite happens before endpoint selection.

```text
+----------------+      +-----------------------+      +----------------+
| client request | ---> | InferenceModelRewrite | ---> | effective model|
+----------------+      +-----------------------+      +----------------+
 original-model             K8s policy object            rewritten-model
                                      |
                                      v
                         +---------------------+      +-------------------+
                         | Praxis llm-d picker | ---> | rewritten backend|
                         +---------------------+      +-------------------+
```

Validation:

- Client sends the original model.
- Backend receives the rewritten model.
- Routing uses the rewritten model eligibility set.
- Integration test proves the worker loads rewrite objects through a fake HTTPS
  Kubernetes API.

### 9. InferenceObjective Metadata And Admission

Purpose: prove objective priority metadata is loaded and can influence
admission.

```text
+----------------+      +---------------------+      +----------------+
| request header | ---> | InferenceObjective  | ---> | priority meta  |
+----------------+      +---------------------+      +----------------+
 objective name             K8s policy object           request metadata
                                      |
                                      v
                         +---------------------+
                         | admission threshold |
                         +---------------------+
```

Validation:

- Demo applies an `InferenceObjective` and sends the objective header.
- Runnable demo proves the request still routes through the metadata path.
- Rust integration tests prove high-priority admission and negative-priority
  rejection behavior.

## What The Demo Does Not Pretend

The demo is scoped to the implemented native picker POC:

- It does not implement the full Go EPP plugin framework.
- It does not implement Gateway API controller reconciliation or route status.
- It does not implement distributed prefix state across Praxis replicas.
- It does not implement true queued flow control, fairness, eviction, or tenant
  accounting.
- It does not implement NIXL/RDMA or physical KV-transfer execution.
- It does not implement prefill-failure retry with alternate prefiller.
- It does not provide a high-concurrency SSE benchmark or large-prompt TTFT
  benchmark.
- It does not prove Ray, Slurm, or bare-metal packaging.
- It does not implement TLS metrics scraping in the current POC.

## PR Stack

The upstream stack should be split for review even though the e2e branch carries
one implementation snapshot. Target PR size is 1k-2k changed LOC where practical.

```text
PR-01  Static picker
   |
PR-02  Metrics and endpoint state
   |
PR-03  Kubernetes InferencePool discovery
   |
PR-04  Discovery hardening and KIND proof
   |
PR-05  Approximate prefix-cache scoring
   |
PR-06  Saturation/admission gate
   |
PR-07  Minimal P/D disaggregation
   |
PR-08  Gateway API HTTPRoute wiring
   |
PR-09  InferenceModelRewrite
   |
PR-10  InferenceObjective priority metadata
   |
PR-11  Objective-aware saturation/admission
   |
PR-13  P/D disaggregation parity hardening

Blocked side branches:

PR-12  True priority queue / flow-control core
PR-15  P/D prefill-failure retry
```

| Planned PR | Status | Scope | Depends on | Demo relationship |
|------------|--------|-------|------------|-------------------|
| PR-01 | Accepted | Static native endpoint picker: model-aware and load-aware routing | none | Examples 1 and static pieces of 2 |
| PR-02 | Accepted | Dynamic vLLM metrics scraping and endpoint snapshots | PR-01 | Example 2 |
| PR-03 | Accepted | Kubernetes `InferencePool` discovery | PR-02 | Example 3 |
| PR-04 | Accepted | Discovery hardening and discovery-only KIND proof | PR-03 | Example 3 stability |
| PR-05 | Accepted | Approximate prefix-cache internals and scoring integration | PR-04 | Example 5 |
| PR-06 | Accepted | Deterministic saturation/admission gate | PR-05 | Example 6 |
| PR-07 | Accepted | Minimal prefill/decode disaggregation | PR-06 | Example 7 |
| PR-08 | Accepted | Gateway API `HTTPRoute` to `InferencePool` wiring | PR-07 | Example 4 |
| PR-09 | Accepted | `InferenceModelRewrite` request-body model rewrite | PR-08 | Example 8 |
| PR-10 | Accepted | `InferenceObjective` priority metadata | PR-09 | Example 9 metadata |
| PR-11 | Accepted | Objective-aware saturation/admission policy | PR-10 | Example 9 policy proof in tests |
| PR-12 | Blocked | Minimal priority queue / flow-control core | Praxis core request deferral | Not required for current demo |
| PR-13 | Accepted | P/D disaggregation parity hardening | PR-11 | Example 7 implementation hardening |
| PR-15 | Blocked | P/D prefill-failure retry | Praxis response-phase retry/body replay | Not required for current demo |

### PR-01: Static Native Endpoint Picker

Purpose: introduce `llmd_endpoint_picker` and prove Praxis can make model-aware
and basic load-aware decisions without the Envoy plus EPP request-path hop.

Included:

- Filter registration and `ai-inference` module wiring.
- OpenAI-compatible request body buffering.
- Model extraction.
- Model-aware endpoint filtering.
- Health-aware endpoint filtering.
- Static endpoint config.
- Queue/KV load-aware scoring from configured endpoint state.
- Direct upstream selection through `ctx.upstream`.
- Static routing unit tests and integration tests.
- Product docs for static endpoint config and load-aware behavior.

### PR-02: Dynamic Metrics And Endpoint State

Purpose: make load-aware routing use live vLLM-compatible metrics instead of
only static config.

Included:

- Background endpoint state worker.
- `ArcSwap` endpoint snapshots.
- vLLM Prometheus metrics parser.
- Plain HTTP metrics scraper.
- `metrics_url`, `metrics_refresh_ms`, and `metrics_timeout_ms` config.
- Scrape success/failure health behavior.
- Hostname and Kubernetes DNS support for metrics URLs.
- Bounded response reads and `Content-Length` enforcement.
- Compatibility with `vllm:kv_cache_usage_perc` from `llm-d-inference-sim`.
- Dynamic routing integration test proving route change.

### PR-03: Kubernetes InferencePool Discovery

Purpose: remove the need to statically list every endpoint in Kubernetes.

Included:

- Optional `inference_pool` config.
- In-cluster Kubernetes API client.
- Service account token and CA handling.
- Supported `InferencePool` parsing.
- Pod listing by selector.
- Ready/running/non-terminating pod filtering.
- Pod-IP endpoint construction.
- Static and discovered endpoint merge.

### PR-04: Discovery Hardening And KIND Proof

Purpose: harden discovery after the first implementation and prove
discovery-only routing.

Included:

- Percent-encoded label selectors.
- Strict API version parsing.
- Chunked transfer decoding and malformed/truncated chunk rejection.
- `Content-Length` enforcement for Kubernetes API responses.
- Empty/missing pod name rejection.
- Empty CA bundle rejection.
- Static/discovered endpoint deduplication by address.
- Discovery-only KIND validation.

### PR-05: Approximate Prefix-Cache Scoring

Purpose: add a POC-level approximation of llm-d prefix-aware routing.

Included:

- Optional `prefix_cache` config.
- Prefix material extraction for chat completions, completions, and responses.
- Structured chat content handling.
- Stable JSON serialization for complex prompt shapes.
- Explicit FNV-1a hash chain.
- Partial final block hashing.
- Per-endpoint in-memory LRU index.
- Longest contiguous prefix matching.
- Prefix score composition with queue/KV scoring.
- Post-selection prefix index updates.
- Integration test proving prefix score can change routing.

Known deferral:

- This is approximate gateway-side state. It is not full tokenizer plus KVEvents
  parity.

### PR-06: Deterministic Saturation/Admission Gate

Purpose: add the first flow-control-adjacent behavior by rejecting saturated
pools and filtering overloaded endpoints.

Included:

- Optional `saturation_gate` config.
- Endpoint saturation from queue depth and KV-cache fraction.
- Average pool saturation.
- Pool-level reject with configurable status.
- Headroom-adjusted endpoint filtering.
- Fail-open when endpoint filtering removes all candidates and pool reject did
  not fire.
- Request metadata for pool saturation and gate state.
- Config validation for non-finite thresholds.
- Queue headroom `ceil()` behavior with regression coverage.

### PR-07: Minimal Prefill/Decode Disaggregation

Purpose: add the smallest useful P/D routing slice.

Included:

- Endpoint roles: `prefill`, `decode`, and `prefill-decode`.
- Decode endpoint selected as primary upstream.
- Prefill endpoint selected when configured.
- `x-prefiller-host-port` injection.
- Decode-only fail-open when no prefill endpoint exists.
- Discovery support for `llm-d.ai/role` pod labels.
- Header validation for `disaggregation.prefill_header`.
- Prefill selection avoids saturated prefill endpoints when possible.

Out of scope:

- E/P/D encode routing.
- Direct prefill execution from Praxis.
- NIXL/RDMA protocol handling.
- Token-counted precise uncached-token decisions.

### PR-08: Gateway API HTTPRoute Wiring

Purpose: connect endpoint discovery to Gateway API objects llm-d users expect.

Included:

- Optional `gateway_api` config pointing at one `HTTPRoute`.
- In-cluster read of `gateway.networking.k8s.io/v1` `HTTPRoute`.
- Parse `spec.rules[].backendRefs[]` for supported `InferencePool` backends.
- Resolve selected backendRef into existing `InferencePool`.
- Reuse pod discovery, metrics scraping, role handling, and routing.
- Exact backendRef group matching for supported inference groups.
- Empty backendRef name filtering.
- `backendRef.port` fallback when `InferencePool` has no target ports.

Out of scope:

- Gateway API controller behavior.
- Weighted backendRef traffic splitting.
- Multi-route dispatch inside one listener.
- Route status reconciliation.

### PR-09: InferenceModelRewrite

Purpose: add llm-d policy-based request-body model rewrite.

Included:

- Parse `llm-d.ai/v1alpha2` `InferenceModelRewrite` list responses.
- Filter rewrites by `spec.poolRef`.
- Exact model matches and generic fallback matches.
- Precedence: exact before generic, oldest resource wins, first matching rule
  wins within a resource.
- Apply target model before endpoint selection.
- Weighted target selection with per-request roll.
- Unsupported match types skipped deterministically.
- Invalid targets filtered or rejected deterministically.
- Metadata for original model, target model, and rewrite source.
- Fake HTTPS Kubernetes API integration proof.

### PR-10: InferenceObjective Priority Metadata

Purpose: resolve objective priority metadata for later flow-control work.

Included:

- Parse `llm-d.ai/v1alpha2` `InferenceObjective` list responses.
- Filter objectives by `spec.poolRef`.
- Resolve `x-llm-d-inference-objective`.
- Accept `x-gateway-inference-objective` as fallback.
- Missing, unknown, or priority-less objectives resolve to priority `0`.
- Negative priorities are preserved.
- Metadata records objective name, source, and resolved priority.
- Fake HTTPS Kubernetes API integration proof.

### PR-11: Objective-Aware Saturation/Admission Policy

Purpose: use resolved objective priority to tune existing admission behavior
without adding queues.

Included:

- `priority_headroom_per_level` or equivalent saturation config.
- Existing behavior preserved when absent or zero.
- Positive priorities raise the pool saturation reject threshold.
- Negative priorities lower the reject threshold.
- Endpoint scoring remains unchanged for admitted requests.
- Integration proof that default priority rejects while high priority admits at
  the same saturation level.
- Negative-priority proof that moderate saturation admits default priority but
  rejects low priority.

Out of scope:

- Request queues.
- Fair scheduling.
- Cross-process state.
- Status writes.

### PR-12: Minimal Priority Queue / Flow-Control Core

Status: blocked.

Purpose: add true queued flow-control. This would hold lower-priority requests
while higher-priority requests move ahead.

Blocked because current Praxis filter lifecycle lacks:

- A safe `Hold`, `Defer`, `Yield`, or `Resume` action.
- Request body ownership semantics for held requests.
- Completion hooks or typed extensions for cancellation-safe permit release.
- Queue accounting on normal response, upstream error, rejection, timeout, and
  client disconnect.

Impact: this does not block the current endpoint-picker demo. PR-11 is the safe
flow-control slice available today: immediate admit/reject with priority-aware
thresholds.

### PR-13: P/D Disaggregation Parity Hardening

Purpose: harden P/D by adding decode-side KV-transfer hints in the request body.

Included:

- `inject_kv_transfer_params` config flag, default `true`.
- `BodyAccess::ReadWrite` when KV-transfer mutation is enabled.
- Request-body mutation inserts or merges `kv_transfer_params`.
- Existing unknown keys are preserved.
- Non-object `kv_transfer_params` values are replaced with an object.
- Model rewrite and KV-transfer body mutation compose correctly.
- `Content-Length` is updated after body mutation.

Out of scope:

- Full NIXL/RDMA orchestration.
- Token-counted P/D decision making.
- Retrying prefill failure with a different prefiller.

### PR-15: P/D Prefill-Failure Retry

Status: blocked.

Purpose: retry failed P/D prefill attempts with a different prefiller if Praxis
core can safely support it.

Blocked because:

- Branch chains are evaluated during request filter execution only.
- Response filters can continue or reject, but cannot re-enter request
  selection or branch-chain retry.
- Pingora retry in the current Praxis handler is scoped to connection failures,
  not application-level response-status retry for OpenAI POST requests.
- Safe request body replay after a complete upstream response is not available.

Impact: this does not block the current demo. It is a future Praxis core design
issue if alternate-prefiller retry parity becomes required.

## Demo Documentation Track

`DEMO-01` is separate from the Praxis upstream code stack. It lives in:

```text
https://github.com/nerdalert/praxis-research-spikes/tree/main/demo/track-a-llm-d-praxis-native
```

Scope:

- KIND-based setup.
- Scripts for each demo scenario.
- Kubernetes manifests and minimal CRDs.
- Demo README, deploy guide, architecture reference, and sample output.
- Honest limitations and explicit proof points for each scenario.

The demo PR should stay separate from the Praxis code PRs.
