# llm-d Praxis Benchmark Results

> **Disclaimer:** All results below are from a single-node development
> environment using `llm-d-inference-sim` in echo mode without GPU inference.
> These are not validated performance claims. Results should not be referenced
> as production benchmarks until reproduced on properly sized and isolated
> hardware with real model serving backends.

## How To Read These Results

The results are organized by **testing harness** and **workload shape**. Each
harness answers a different question:

| Harness | Sections | Primary Question | Best Use |
|---------|----------|------------------|----------|
| Vegeta | Simulator echo, large prompt, mock backend | How much raw request-path overhead does each proxy profile add? | Comparing `praxis-native`, `praxis-simple`, and `envoy-go-epp` control-path cost. |
| GuideLLM | GuideLLM results and matrix | How do the same profiles behave under an OpenAI/LLM-shaped benchmark client? | TTFT, ITL, token throughput, streaming behavior, and future GPU-backed runs. |
| Fortio | Not used in the llm-d tables below | How does the generic Praxis benchmark framework stress HTTP/TCP echo and connection behavior? | Generic proxy/network tests, not the OpenAI chat completion path shown here. |

The clearest control-path comparison is the **Vegeta simulator echo** result.
The clearest LLM-client comparison is the **GuideLLM streaming** result.
GuideLLM RPS should not be compared directly to Vegeta RPS because GuideLLM
does more client-side LLM accounting and, by default, processes streaming
responses token by token.

## What Is Actually Running

These results are local-process benchmarks unless a section explicitly says
KIND. They directly run the measured data-plane pieces, not a complete llm-d
cluster deployment.

The local benchmark scripts start:

- Vegeta or GuideLLM as the client.
- Praxis and/or Envoy as the proxy under test.
- The real Go EPP binary from `llm-d-router` for `envoy-go-epp` and
  `praxis-go-epp`.
- A benchmark backend: Python mock, Go mock, or `llm-d-inference-sim` in echo
  mode.

The local scripts do not start the full llm-d API Gateway, Gateway API
controller, Kubernetes CRDs, `llm-d-deployer`, InferencePool reconciliation, or
real vLLM/SGLang GPU workers. The Go EPP profiles use file discovery to point
at static benchmark backends, so they validate the proxy-to-EPP data path and
selected-endpoint handoff without depending on Kubernetes service discovery.

KIND sections are deployment-path validation. They run Kubernetes manifests for
the specific scenario being tested, but they are still not production llm-d
deployments unless the scenario explicitly includes those control-plane
components.

## Why The Local Results Are Still Useful

The local runs are representative for the request path because they exercise the
same hot-path contract used by a full llm-d deployment: OpenAI-compatible
request in, ext_proc or ext_proc-compatible EPP callout, selected endpoint back
from the Go EPP, and original request forwarded to the selected backend.

What changes in a full deployment is mostly how that path is created and kept
up to date. The API Gateway/Gateway API resources, `ModelService` controller,
`InferencePool` resources, Services, CRDs, and deployment reconciler create
routes, EPP Deployments, backend Deployments, and discovery state. The local
benchmarks replace that control plane with explicit process startup and file
discovery so the proxy/EPP data path can be measured directly.

That means these numbers give confidence in Track B's compatibility with the
Go EPP request protocol and selected-endpoint handoff. They do not prove
Kubernetes controller reconciliation, dynamic discovery, autoscaling,
multi-endpoint scheduling quality, real GPU throughput, or P/D data movement.
Those remain full-deployment validation items.

The result would not automatically carry over if the full deployment depends on
Kubernetes-only EPP plugins, Envoy-specific metadata that Praxis does not yet
emit, service mesh/TLS/auth filters, dynamic route behavior, richer endpoint
subset metadata, or real model-serving bottlenecks. Those are not expected to
invalidate the basic ext_proc request path, but they can change correctness or
performance once enabled.

## What This Can Test Without GPUs

The current benchmark set is intentionally focused on request-path and control
plane behavior. It can validate a large part of the llm-d integration story
without GPU-backed model serving:

| Area | No-GPU Status | What The Current Benchmarks Prove |
|------|---------------|-----------------------------------|
| Native EPP replacement path | Tested well | Praxis runs `llmd_endpoint_picker` in process, extracts the model, filters endpoints, scores candidates, and selects the upstream directly. |
| Envoy + Go EPP baseline | Tested well | Requests traverse Envoy, `ext_proc`, and the Go EPP process using file discovery and a static endpoint. |
| Generic Praxis control path | Tested well | `praxis-simple` measures ordinary Praxis proxy overhead without llm-d scheduling. |
| Request-path overhead | Tested well | Small prompt, large prompt, mock backend, and simulator backend runs show the cost of each proxy path. |
| Body handling overhead | Tested well | Large-prompt runs show how the Envoy plus EPP gap narrows as request body movement dominates. |
| OpenAI client behavior | Tested well | GuideLLM exercises OpenAI-style requests, streaming/non-streaming behavior, TTFT/ITL fields, token accounting, and concurrent/poisson/sweep traffic patterns. |
| Simulator compatibility | Tested well | `llm-d-inference-sim` echo mode proves the profiles work against llm-d-compatible OpenAI responses. |
| Load-aware routing | Partially testable | Fake or controlled metrics can prove scoring decisions, but not scheduling quality under real GPU pressure. |
| Saturation/admission | Partially testable | Fake queue/KV metrics can prove admission logic, but not real model saturation behavior. |
| Prefix-cache affinity | Partially testable | Approximate in-memory prefix routing can be tested functionally, but not real KV-cache hit latency. |
| P/D role routing | Partially testable | Role-aware endpoint selection and prefill hints/body mutation can be proven, but not actual disaggregated inference execution. |
| Policy objects | Partially testable | Model rewrite and objective metadata can be validated with fake K8s APIs or manifests. |

The following tracks need GPU-backed model serving or real vLLM/SGLang
deployments before the results should be treated as performance claims:

- True TTFT and ITL under real generation.
- Real KV-cache hit latency and throughput improvements.
- Load-aware scheduling quality under changing queue depth and KV pressure.
- Real saturation behavior where backends genuinely queue, slow down, or reject.
- P/D data-plane validation, including NIXL/RDMA/KV-transfer and true
  disaggregated prefill/decode execution.
- Production throughput claims on isolated hardware with longer runs and GPU
  observability.

## Performance Testing Analysis

Absolute RPS differs by harness because each tool drives a different client
workload. Compare profiles **within the same harness**, then use the harnesses
together to understand different parts of the system.

- Vegeta is the raw control-path harness. It sends fixed HTTP requests with
  low client-side overhead, so it is the best tool here for measuring proxy
  request-path cost and p50/p95/p99 latency.
- GuideLLM is the LLM-shaped harness. It loads prompt data, builds
  OpenAI-compatible requests, parses LLM-style responses, and in streaming mode
  processes token chunks so it can report TTFT, ITL, and token throughput. This
  extra work lowers absolute RPS compared with Vegeta.
- GuideLLM non-streaming is closer to a raw proxy comparison than GuideLLM
  streaming, but it still includes GuideLLM's dataset, scheduling, parsing, and
  reporting overhead.
- Fortio is part of the broader Praxis benchmark framework for generic HTTP,
  TCP, and connection behavior. It is not the right primary harness for the
  OpenAI chat-completion results shown on this page.

The consistent result across the current runs is that `praxis-native` stays in
the same performance band as `praxis-simple`, while `envoy-go-epp` is slower.
That supports the architecture hypothesis: running llm-d endpoint selection in
the Praxis process avoids the Envoy `ext_proc` round trip and the external Go
EPP process hop.

The large-prompt benchmark narrows the `praxis-native` to `envoy-go-epp` gap.
That is expected. The Envoy plus EPP path pays a mostly fixed per-request
architecture cost, while large request bodies make body movement and backend
echo work dominate the request. Small prompts isolate proxy architecture
overhead more clearly.

GuideLLM TTFT and ITL are intentionally shallow in echo mode because
`llm-d-inference-sim` returns immediately. Those metrics become much more useful
once the same harness is pointed at simulated latency or real GPU-backed
vLLM/SGLang deployments.

## Profile Definitions

| Profile | Request Path | What It Is For |
|---------|--------------|----------------|
| `praxis-simple` | Client -> Praxis generic proxy -> backend | Control profile for ordinary Praxis proxying, without llm-d scheduling. |
| `praxis-native` | Client -> Praxis `llmd_endpoint_picker` -> selected backend | Native Praxis llm-d scheduling path under test. |
| `praxis-go-epp` | Client -> Praxis -> ext_proc-compatible call -> Go EPP -> backend | Track B path: Praxis replaces Envoy while keeping the Go EPP scheduler. |
| `envoy-go-epp` | Client -> Envoy -> ext_proc -> Go EPP -> backend | Current-style llm-d baseline path using Envoy plus the Go EPP process. |

## Run Metadata

| Field | Value |
|-------|-------|
| Track A Praxis commit | `a142106` (branch: `e2e-llm-d-epp-benchmarking`) |
| Track B Praxis branch | `track-b-benchmarking` for benchmark reproduction; `track-b` for implementation-only review |
| llm-d-router commit | `bbb20ce` |
| llm-d-inference-sim commit | `b0b6faa` |
| Envoy image | `envoyproxy/envoy:distroless-v1.33.2` |
| Vegeta | v12.12.0, max-workers 16, rate 0 (open loop) |
| GuideLLM | Used for OpenAI/LLM-shaped streaming and non-streaming client measurements |
| Fortio | Available in the Praxis benchmark framework, not used for the llm-d result tables below |
| CPU | Intel Xeon E5-2686 v4 @ 2.30GHz |
| OS | Linux 6.14.0-1018-aws |
| Machine | AWS EC2 (single instance, no isolation) |

## Vegeta: llm-d-inference-sim Echo Backend

**Methodology:** 3 runs x 30s measurement, 5s warmup per run, median selected.

**Simulator config:** echo mode, model `test-model`, port 18080,
`--max-num-seqs 256`, zero simulated latency.

| Profile | RPS | p50 | p95 | p99 | Success |
|---------|-----|-----|-----|-----|---------|
| `praxis-simple` | 12,709 | 1.01ms | 2.37ms | 3.41ms | 100% |
| `praxis-native` | 12,551 | 1.03ms | 2.37ms | 3.42ms | 100% |
| `envoy-go-epp` | 3,677 | 3.99ms | 7.46ms | 9.76ms | 100% |

**praxis-native vs envoy-go-epp: 3.4x throughput, 2.9x lower p99.**

### Track B Simulator Echo (same session, same backend)

| Profile | RPS | p50 | p95 | p99 | Success |
|---------|-----|-----|-----|-----|---------|
| `praxis-simple` | 11,748 | 1.11ms | 2.58ms | 3.63ms | 100% |
| `praxis-go-epp` | 5,231 | 2.79ms | 5.11ms | 6.61ms | 100% |
| `envoy-go-epp` | 3,604 | 4.09ms | 7.52ms | 9.71ms | 100% |

**praxis-go-epp vs envoy-go-epp: 1.45x throughput, 1.47x lower p99.**
Both use the same Go EPP, same simulator, same session.

### Per-Run Variance

| Profile | Run 1 | Run 2 | Run 3 | CV |
|---------|-------|-------|-------|-----|
| `praxis-simple` | 12,946 | 12,709 | 12,707 | ~1% |
| `praxis-native` | 12,551 | 12,390 | 12,732 | ~1% |
| `envoy-go-epp` | 3,623 | 3,680 | 3,677 | ~1% |

Low variance across all profiles. Results are stable.

### Interpretation

With `llm-d-inference-sim` in echo mode, `praxis-native` is within the same
performance band as `praxis-simple`. The Envoy + Go EPP path shows materially
lower throughput and higher p99 latency. This validates the
architecture-overhead hypothesis but not GPU-backed inference or full EPP
plugin parity.

The `envoy-go-epp` profile uses a real Envoy, real ext_proc, and the real
Go EPP process, but with simplified scheduling: one static endpoint, random
picker, no full plugin scoring stack. This isolates architecture overhead,
not complete scheduling-equivalence cost.

## Vegeta: Large-Prompt Body Handling

**Methodology:** 3 runs x 30s measurement, 5s warmup per run, median selected.

**Workload:** `llmd-chat-large-prompt` — OpenAI chat completion with padded
user message. Prompt sizes: 16 KiB, 64 KiB, 256 KiB. `max_tokens: 10`.

This benchmark stresses request body handling. In the Envoy + Go EPP path,
the request body crosses the ext_proc gRPC boundary to the Go EPP process.
In the Praxis native path, body parsing happens in process.

### 16 KiB Prompt

| Profile | RPS | p99 | Success |
|---------|-----|-----|---------|
| `praxis-simple` | 2,864 | 11.82ms | 100% |
| `praxis-native` | 2,821 | 12.07ms | 100% |
| `envoy-go-epp` | 1,504 | 21.78ms | 100% |

**praxis-native vs envoy-go-epp: 1.9x throughput, 1.8x lower p99.**

### 64 KiB Prompt

| Profile | RPS | p99 | Success |
|---------|-----|-----|---------|
| `praxis-simple` | 439 | 84.15ms | 100% |
| `praxis-native` | 436 | 84.02ms | 100% |
| `envoy-go-epp` | 342 | 90.25ms | 100% |

**praxis-native vs envoy-go-epp: 1.3x throughput, 1.1x lower p99.**

### 256 KiB Prompt

| Profile | RPS | p99 | Success |
|---------|-----|-----|---------|
| `praxis-simple` | 114 | 235.57ms | 100% |
| `praxis-native` | 113 | 234.92ms | 100% |
| `envoy-go-epp` | 95 | 258.86ms | 100% |

**praxis-native vs envoy-go-epp: 1.2x throughput, 1.1x lower p99.**

### How the Gap Changes with Prompt Size (Track A)

| Prompt Size | praxis-native RPS | envoy-go-epp RPS | Throughput Ratio | p99 Ratio |
|-------------|-------------------|-------------------|-----------------|-----------|
| Small (100B) | 12,551 | 3,677 | 3.4x | 2.9x |
| 16 KiB | 2,821 | 1,504 | 1.9x | 1.8x |
| 64 KiB | 436 | 342 | 1.3x | 1.1x |
| 256 KiB | 113 | 95 | 1.2x | 1.1x |

### Track B Large-Prompt (same session, same backend)

| Prompt Size | praxis-simple RPS | praxis-go-epp RPS | envoy-go-epp RPS | go-epp/envoy Ratio |
|---|---|---|---|---|
| 16 KiB | 5,348 | 2,543 | 2,192 | 1.16x |
| 64 KiB | 589 | 529 | 496 | 1.07x |
| 256 KiB | 155 | 147 | 144 | 1.02x |

The `praxis-go-epp` vs `envoy-go-epp` gap narrows with prompt size,
matching the Track A pattern. At 256 KiB, both ext_proc paths are
body-transfer bound and nearly identical.

As prompt size grows, the architecture-overhead gap narrows because body
transfer and backend processing time dominate. At small prompts, ext_proc
round-trip overhead is the dominant cost difference. At 256 KiB, both paths
spend most of their time moving data, and the ext_proc overhead becomes a
smaller fraction of total request time.

This is the expected result: the ext_proc architecture penalty is a
per-request fixed cost, not proportional to body size. Large bodies amortize
it. The small-prompt benchmark remains the clearest isolation of architecture
overhead.

## KIND Deployment Validation

> KIND results are deployment-path validation, not production benchmarks.
> KIND networking adds overhead. Compare scenarios within KIND, not KIND
> vs local-process numbers.

**Methodology:** Single 10s Vegeta run via NodePort from host.

| KIND Scenario | RPS | p99 | Success |
|---------------|-----|-----|---------|
| praxis-native-static (NodePort 30090) | 2,116 | 14.63ms | 100% |
| envoy-to-praxis-native (NodePort 30091) | 1,858 | 16.10ms | 100% |
| envoy-go-epp | Blocked — EPP container exits in KIND | — | — |

The Envoy-edge-to-Praxis-native scenario is slightly slower than direct
Praxis native, which is expected from the extra Envoy hop (pass-through only,
no ext_proc). The envoy-go-epp scenario is blocked by an EPP container crash
that only manifests in KIND; the local-process benchmark remains valid.

## Vegeta: Minimal Mock Backend (Python)

**Methodology:** 3 runs x 30s measurement, 5s warmup per run, median selected.

**Backend:** Minimal Python `http.server` returning a static JSON response.

| Profile | RPS | p50 | p95 | p99 | Success |
|---------|-----|-----|-----|-----|---------|
| `praxis-simple` | 5,183 | 0.97ms | 2.02ms | 2.85ms | 100% |
| `praxis-native` | 5,343 | 0.95ms | 1.97ms | 2.80ms | 100% |
| `envoy-go-epp` | 2,284 | 5.08ms | 9.92ms | 13.65ms | 100% |

**praxis-native vs envoy-go-epp: 2.3x throughput, 4.9x lower p99.**

## Vegeta: Track B — Same-Backend Go Mock (validated comparison)

**Methodology:** 3 runs x 30s measurement, 5s warmup per run, median selected.
All profiles in the same session against the same Go `net/http` mock backend.

| Profile | RPS | p50 | p95 | p99 | Success |
|---------|-----|-----|-----|-----|---------|
| `praxis-simple` | 15,778 | 0.78ms | 1.95ms | 2.85ms | 100% |
| `praxis-go-epp` | 5,970 | 2.44ms | 4.49ms | 5.80ms | 100% |
| `envoy-go-epp` | 3,921 | 3.75ms | 6.94ms | 9.01ms | 100% |

**praxis-go-epp vs envoy-go-epp: 1.52x throughput, 1.55x lower p99.**
Same Go EPP, same backend, same session. This is the validated comparison.

**Not directly comparable to Python-mock rows above.** The Go backend and
Python backend have different performance characteristics, so cross-backend
throughput and latency comparisons are directional only.

The validated Track B comparison is the same-backend table above:
`praxis-simple`, `praxis-go-epp`, and `envoy-go-epp` ran in the same session
against the same Go backend. A four-profile table that also includes
`praxis-native` requires either the Track A Praxis binary or the native picker
merged into the Track B branch.

## GuideLLM: llm-d-inference-sim Echo Backend

GuideLLM provides LLM-specific metrics (TTFT, ITL, token throughput) that
Vegeta does not. No proxy config changes are needed: GuideLLM runs with
`--backend-kwargs '{"validate_backend": false}'` and explicit `--model`.

**Methodology:** GuideLLM concurrent profile (concurrency=4), 30s, 100
prompts from JSON dataset.

| Profile | RPS | TTFT median | ITL median | E2E latency median | Tokens/s (out) |
|---------|-----|-------------|------------|-------------------|----------------|
| `praxis-simple` | 656 | 2.97ms | 0.014ms | 3.9ms | 24,915 |
| `praxis-native` | 654 | 2.74ms | 0.014ms | 3.9ms | 25,037 |
| `envoy-go-epp` | 498 | 5.07ms | 0.020ms | 6.8ms | 18,797 |

GuideLLM RPS is lower than Vegeta because GuideLLM uses streaming mode
by default and processes token-by-token responses. The relative profile
ordering is consistent: praxis-native and praxis-simple are in the same
band, envoy-go-epp is materially slower.

TTFT and ITL are shallow in echo mode (the simulator returns instantly).
These metrics become meaningful with simulated inference latency or real
GPU backends.

### Track B GuideLLM (same session, concurrent profile, concurrency=4, 30s)

| Profile | RPS | TTFT median | ITL median | Tokens/s (out) |
|---------|-----|-------------|------------|----------------|
| `praxis-simple` | 529 | 2.92ms | 0.015ms | 10,854 |
| `praxis-go-epp` | 500 | 3.89ms | 0.017ms | 8,479 |
| `envoy-go-epp` | 391 | 5.58ms | 0.020ms | 8,560 |

**praxis-go-epp vs envoy-go-epp: 1.28x RPS, 1.44x lower TTFT.**
Same Go EPP, same simulator, same session.

Track A `praxis-simple` (656 RPS), `praxis-native` (654 RPS), and
`envoy-go-epp` (498 RPS) were measured in a separate Track A session.
Track B numbers are from a different Praxis binary/commit and should
not be directly compared to Track A GuideLLM numbers.

**GuideLLM command pattern:**
```
guidellm benchmark run \
  --target=http://127.0.0.1:18090 \
  --model=test-model \
  --data=benchmarks/llm-d/data/guidellm-prompts.json \
  --backend-kwargs '{"validate_backend": false}' \
  --profile=concurrent --rate=4 \
  --max-seconds=30 \
  --output-dir=<dir> --outputs=benchmark-results.json
```

For non-streaming (closer to raw RPS comparison with Vegeta):
```
  --backend-kwargs '{"validate_backend": false, "stream": false}'
```

### GuideLLM Matrix (concurrent + poisson, 10s each)

Generated from `benchmarks/llm-d/summarize-guidellm-results.py`:

| Profile | Stream | Conc | RPS | TTFT | ITL | E2E | Reqs |
|---------|--------|------|-----|------|-----|-----|------|
| `praxis-simple` | yes | 4 | 690 | 2.57ms | 0.014ms | 3.7ms | 100 |
| `praxis-simple` | yes | 16 | 860 | 4.61ms | 0.013ms | 5.6ms | 99 |
| `praxis-simple` | no | 4 | 758 | n/a | n/a | 1.7ms | 100 |
| `praxis-simple` | no | 16 | 890 | n/a | n/a | 2.5ms | 100 |
| `praxis-native` | yes | 4 | 672 | 2.91ms | 0.015ms | 4.2ms | 100 |
| `praxis-native` | yes | 16 | 885 | 6.97ms | 0.016ms | 8.4ms | 96 |
| `praxis-native` | yes | poisson | 666 | 6.04ms | 0.015ms | 8.1ms | 100 |
| `praxis-native` | no | 4 | 858 | n/a | n/a | 1.7ms | 98 |
| `praxis-native` | no | 16 | 1047 | n/a | n/a | 2.8ms | 98 |
| `envoy-go-epp` | yes | 4 | 507 | 5.32ms | 0.019ms | 6.9ms | 99 |
| `envoy-go-epp` | yes | 16 | 587 | 8.93ms | 0.020ms | 11.7ms | 98 |
| `envoy-go-epp` | yes | poisson | 580 | 14.25ms | 0.020ms | 19.2ms | 100 |
| `envoy-go-epp` | no | 4 | 700 | n/a | n/a | 3.2ms | 100 |
| `envoy-go-epp` | no | 16 | 810 | n/a | n/a | 4.6ms | 97 |

Non-streaming gives higher RPS because GuideLLM processes complete
responses rather than token-by-token. TTFT and ITL are only meaningful
in streaming mode. Use Vegeta for raw control-path throughput; use
GuideLLM streaming for TTFT/ITL/token behavior.

**Regenerate this table from result files:**
```
python3 benchmarks/llm-d/summarize-guidellm-results.py target/criterion/llmd-guidellm-matrix/
```

**Full matrix script:**
```
./benchmarks/llm-d/run-guidellm-matrix.sh [MAX_SECONDS]
```

Supported kinds: `concurrent-stream`, `concurrent-nostream`, `constant`,
`poisson`, `sweep`. Configurable via `GUIDELLM_KINDS` environment variable.

### Next Steps

- GuideLLM Kubernetes Job manifests for GPU-backed runs (planned).
- Longer matrix runs (30s/60s) with rates 1,4,16,32.
- Sweep profile for automatic saturation discovery.
- `llm-d-inference-sim` with simulated latency for meaningful TTFT/ITL.

## What These Results Can Claim

- The native Praxis path has substantially lower control-path overhead than
  Envoy + ext_proc + Go EPP in these benchmarks.
- The gap is consistent across both mock and simulator backends.
- `praxis-native` is within the same performance band as `praxis-simple`,
  meaning the `llmd_endpoint_picker` filter does not measurably degrade
  the Praxis data plane in this workload.
- The `envoy-go-epp` benchmark path is real: requests traverse Envoy,
  ext_proc gRPC, and the Go EPP process.
- The architecture-overhead gap narrows as prompt size grows, which is
  consistent with ext_proc overhead being a per-request fixed cost rather
  than proportional to body size.

## What These Results Cannot Claim

- Production throughput or latency (single machine, no resource isolation).
- GPU-backed inference performance.
- Full Go EPP scheduling parity (simplified single-endpoint random picker).
- Real KV-cache hit latency or TTFT improvements.
- NIXL/RDMA data movement performance.
- Load-aware scoring under real changing backend pressure.
- Fortio HTTP/TCP connection-stress results for the llm-d OpenAI chat path.
