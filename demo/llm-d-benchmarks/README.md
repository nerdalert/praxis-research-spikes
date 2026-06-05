# llm-d Praxis Benchmark Demo

> **Disclaimer:** All results in this demo are from a single-node development
> environment using `llm-d-inference-sim` in echo mode without GPU inference.
> These are not validated performance claims. Results should not be referenced
> as production benchmarks until reproduced on properly sized and isolated
> hardware with real model serving backends.

This demo area is for public-facing benchmark instructions and presentation
material for the Praxis llm-d integration. It is separate from the internal
implementation planning docs in `llm-d-benchmarks/`.

Related files in this directory:
- [results.md](results.md) — Full result tables with run metadata and claim boundaries.
- [demo-outline.md](demo-outline.md) — Slide-by-slide demo script.

The benchmark story is focused on request-path cost:

- the current Envoy plus Go EPP scheduling path;
- the native Praxis `llmd_endpoint_picker` path;
- optional compatibility paths where Envoy remains at the edge.

The first benchmark target is the no-GPU control path. It uses a minimal mock
backend so the proxy and scheduler overhead can be measured without expensive
model serving infrastructure. Future iterations will add `llm-d-inference-sim`
for more realistic backend behavior.

## Demo Goals

- Show the request path being measured.
- Compare Envoy plus Go EPP against native Praxis scheduling.
- Keep mock-backend numbers honest: control-path only.
- Make clear which results are proxy/scheduler overhead and which require GPU
  validation later.

## Primary Profiles

| Profile | Request path | Status |
|---------|--------------|--------|
| `envoy-go-epp` | Client -> Envoy ext_proc -> Go EPP -> mock backend | Runnable (Docker Envoy, local EPP, file discovery) |
| `praxis-native` | Client -> Praxis `llmd_endpoint_picker` -> mock backend | Runnable |
| `praxis-simple` | Client -> Praxis generic proxy -> mock backend | Runnable |
| `envoy-praxis-native` | Client -> Envoy -> Praxis native picker -> backend | Planned |

The direct comparison to lead with is:

```text
envoy-go-epp  versus  praxis-native
```

That comparison isolates the cost of moving llm-d scheduling from an external
Envoy `ext_proc` service into the Praxis proxy process.

The two Praxis profiles answer different questions:

| Profile | Question it answers | What changes |
|---------|---------------------|--------------|
| `praxis-simple` | How fast is ordinary Praxis proxying for this request shape? | No llm-d scheduling; just route and forward. |
| `praxis-native` | What is the added cost of doing llm-d endpoint selection inside Praxis? | Adds body parsing, model extraction, endpoint scoring, and direct upstream selection. |

Use `praxis-simple` as the Praxis data-plane control. Use `praxis-native` as
the native llm-d implementation under test. The delta between them is the
incremental cost of the in-process `llmd_endpoint_picker` filter.

## Profile Details

### `praxis-simple`

`praxis-simple` is the generic Praxis data-plane baseline. It runs Praxis with
the normal router and load-balancer filters, then forwards `/v1/` traffic to the
backend on `127.0.0.1:18080`.

Request path:

```text
Client -> Praxis router/load_balancer -> mock backend
```

Purpose:

- Measures Praxis/Pingora proxy overhead without llm-d scheduling.
- Does not parse the OpenAI request body for model selection.
- Does not run `llmd_endpoint_picker`.
- Uses normal path routing and generic upstream forwarding.
- Provides the baseline for estimating the incremental cost of native llm-d
  endpoint selection inside Praxis.

Current benchmark status:

- Runnable with `benchmarks/llm-d/run-smoke.sh`.
- Uses the Python mock backend in the current smoke harness.

### `praxis-native`

`praxis-native` is the main implementation path for this spike. It runs the
native Praxis `llmd_endpoint_picker` HTTP filter in process and forwards directly
to the selected backend.

Request path:

```text
Client -> Praxis llmd_endpoint_picker -> selected backend
```

Purpose:

- Measures the native Praxis llm-d scheduling path.
- Buffers and parses the OpenAI-compatible request body.
- Extracts the requested model.
- Checks configured endpoints and endpoint health.
- Applies model-aware endpoint selection and static load/KV scoring.
- Sets the selected upstream directly inside Praxis.
- Replaces the scheduling decision that would otherwise be made by the external
  Go EPP process in the Envoy-based path.

Current benchmark status:

- Runnable with `benchmarks/llm-d/run-smoke.sh`.
- Uses static configured endpoint state in the current smoke harness.
- Does not require Envoy, `ext_proc`, or the Go EPP process.

### `envoy-go-epp`

`envoy-go-epp` is the current-style llm-d baseline path. It runs Envoy with the
`ext_proc` filter and a local Go EPP process. The Go EPP uses file discovery for
this smoke benchmark, so no Kubernetes API or CRDs are required.

Request path:

```text
Client -> Envoy ext_proc -> Go EPP -> Envoy ORIGINAL_DST -> mock backend
```

Purpose:

- Measures the request-path overhead of Envoy plus the external Go EPP process.
- Keeps the benchmark local by using the Go EPP file-discovery plugin.
- Verifies that requests genuinely cross the Envoy `ext_proc` gRPC boundary.
- Provides the first baseline for comparing native Praxis scheduling against the
  existing EPP architecture.

Current benchmark status:

- Runnable with `benchmarks/llm-d/run-envoy-go-epp-smoke.sh`.
- Uses Docker for Envoy and a locally built or prebuilt Go EPP binary.
- Uses the same Python mock backend shape as the Praxis smoke profiles.
- Uses one static endpoint and a random picker, so it isolates Envoy/EPP process
  overhead rather than full Go EPP scoring behavior.

### `envoy-praxis-native`

`envoy-praxis-native` is a planned compatibility profile. Envoy remains at the
edge, but Praxis performs the native llm-d endpoint selection behind Envoy.

Request path:

```text
Client -> Envoy -> Praxis llmd_endpoint_picker -> selected backend
```

Purpose:

- Tests a migration or compatibility topology where Envoy remains deployed.
- Separates Envoy edge overhead from Praxis native scheduling overhead.
- Helps evaluate whether users can keep existing Envoy ingress while moving llm-d
  scheduling into Praxis.

Current benchmark status:

- Planned, not runnable in the current smoke harness.
- Should be added after the three runnable profiles are stable with longer
  repeated runs.

## Source

The benchmark framework lives on the Praxis `e2e-llm-d-epp-benchmarking` branch:

```console
git clone https://github.com/nerdalert/praxis.git
cd praxis
git checkout e2e-llm-d-epp-benchmarking
```

The llm-d router (Go EPP) is at:

```console
git clone https://github.com/llm-d/llm-d-router.git
```

## How To Run

### Prerequisites

- [Vegeta](https://github.com/tsenart/vegeta) v12.12.0+ (HTTP load generator)
- Python 3 (stdlib only, no pip packages)
- Rust toolchain (stable 1.94+) for building Praxis
- Docker (for the Envoy profile only)
- Go 1.25+ (for building Go EPP, or use a pre-built binary)

### Step 1: Run Praxis Profiles

From the Praxis benchmark repo root:

```console
./benchmarks/llm-d/run-smoke.sh [DURATION_SECS] [WARMUP_SECS]
```

Default: 5s duration, 1s warmup. This runs both `praxis-simple` and
`praxis-native` profiles with the `llmd-chat-small` workload. The script:

1. Starts a minimal Python mock backend on port 18080.
2. Builds or reuses the Praxis binary.
3. Runs each profile: starts Praxis, warms up, measures with Vegeta, saves
   results.

Results go to `target/criterion/llmd-smoke/`:
- `praxis-simple.{json,yaml,txt,bin}` — raw Vegeta data and reports
- `praxis-native.{json,yaml,txt,bin}`
- `logs/praxis-simple.log`, `logs/praxis-native.log` — Praxis stdout/stderr

### Step 2: Run Envoy + Go EPP Baseline

```console
./benchmarks/llm-d/run-envoy-go-epp-smoke.sh [DURATION_SECS] [WARMUP_SECS]
```

This runs the `envoy-go-epp` profile. Point the script at the llm-d-router
clone so it can build the Go EPP binary:

```console
LLM_D_ROUTER_REPO=../llm-d-router ./benchmarks/llm-d/run-envoy-go-epp-smoke.sh [DURATION_SECS] [WARMUP_SECS]
```

The script:

1. Starts the same mock backend on port 18080.
2. Builds or locates the Go EPP binary (set `LLM_D_EPP_BIN` to a pre-built
   binary to skip building).
3. Starts Go EPP with file-based discovery (no Kubernetes).
4. Starts Envoy in Docker (`--network host`) with ext_proc pointing at EPP.
5. Verifies end-to-end: sends a test request through Envoy -> EPP -> backend.
6. Warms up and measures with Vegeta against Envoy port 18091.

Results go to `target/criterion/llmd-smoke/`:
- `envoy-go-epp.{json,yaml,txt,bin}`
- `logs/envoy.log`, `logs/go-epp.log`

### Step 3: Run Extended Benchmark (Longer, Multiple Runs)

For more stable numbers, use the extended benchmark script. It runs all
three profiles with configurable duration and repetitions, then selects
the median result:

```console
LLM_D_ROUTER_REPO=../llm-d-router ./benchmarks/llm-d/run-extended-benchmark.sh [DURATION] [WARMUP] [RUNS]
```

Default: 30s duration, 5s warmup, 3 runs. Results go to
`target/criterion/llmd-extended/` with per-run files and
`{profile}-median.json` summaries.

### Step 4: Run with llm-d-inference-sim Backend

Replace the Python mock with the real llm-d-inference-sim for more realistic
backend behavior:

```console
LLM_D_ROUTER_REPO=../llm-d-router \
LLM_D_SIM_REPO=../llm-d-inference-sim \
  ./benchmarks/llm-d/run-sim-benchmark.sh [DURATION] [WARMUP] [RUNS]
```

The llm-d-inference-sim repo is at:

```console
git clone https://github.com/llm-d/llm-d-inference-sim.git
```

Default: 30s duration, 5s warmup, 3 runs. Same methodology as the extended
mock benchmark but with the simulator serving OpenAI-compatible responses.
Results go to `target/criterion/llmd-sim/`.

### Step 5: Compare

All scripts produce the same artifact shape. Compare the JSON throughput
and latency values directly, or use the text reports for a quick summary.
The benchmark scripts print a summary table at the end.

## Results

### llm-d-inference-sim Backend (median of 3 runs, 30s each)

| Profile | RPS | p50 | p95 | p99 | Success |
|---------|-----|-----|-----|-----|---------|
| `praxis-simple` | 12,709 | 1.01ms | 2.37ms | 3.41ms | 100% |
| `praxis-native` | 12,551 | 1.03ms | 2.37ms | 3.42ms | 100% |
| `envoy-go-epp` | 3,677 | 3.99ms | 7.46ms | 9.76ms | 100% |

**praxis-native vs envoy-go-epp:** 3.4x throughput, 2.9x lower p99 latency.

With `llm-d-inference-sim` (echo mode, zero simulated latency), the gap
between native Praxis and Envoy + ext_proc + Go EPP is consistent with the
mock-backend results. `praxis-native` is within the same performance band as
`praxis-simple` in this benchmark. The Envoy + Go EPP path shows materially
lower throughput and higher p99 latency due to ext_proc gRPC round-trips and
the separate Go EPP process.

The `envoy-go-epp` profile uses a real Envoy, real ext_proc, and the real Go
EPP process, but with simplified scheduling: one static endpoint, random
picker, no full plugin scoring stack. This isolates architecture overhead,
not complete scheduling-equivalence cost.

The simulator is running in echo mode with no simulated inference latency.
These numbers measure proxy and scheduler overhead, not model serving
performance.

### Large-Prompt Benchmark (llm-d-inference-sim, median of 3 runs, 30s each)

How the architecture-overhead gap changes with request body size:

| Prompt Size | praxis-native RPS | envoy-go-epp RPS | Throughput Ratio |
|-------------|-------------------|-------------------|-----------------|
| Small (100B) | 12,551 | 3,677 | 3.4x |
| 16 KiB | 2,821 | 1,504 | 1.9x |
| 64 KiB | 436 | 342 | 1.3x |
| 256 KiB | 113 | 95 | 1.2x |

The gap narrows as prompt size grows because body transfer time dominates.
The small-prompt benchmark is the clearest isolation of architecture overhead.
See [results.md](results.md) for full per-size tables.

Run: `./benchmarks/llm-d/run-sim-large-prompt-benchmark.sh 30 5 3`

### Mock Backend (median of 3 runs, 30s each)

| Profile | RPS | p50 | p95 | p99 | Success |
|---------|-----|-----|-----|-----|---------|
| `praxis-simple` | 5,183 | 0.97ms | 2.02ms | 2.85ms | 100% |
| `praxis-native` | 5,343 | 0.95ms | 1.97ms | 2.80ms | 100% |
| `envoy-go-epp` | 2,284 | 5.08ms | 9.92ms | 13.65ms | 100% |

**praxis-native vs envoy-go-epp:** 2.3x throughput, 4.9x lower p99 latency.

The mock backend numbers are lower overall because the Python mock is slower
than the Go simulator. The relative gap between profiles is consistent.

### Quick Smoke (single run, 5s)

For fast iteration, the smoke scripts run a single short measurement:

| Profile | RPS | p99 | Success | Script |
|---------|-----|-----|---------|--------|
| `praxis-simple` | ~4,200 | ~3.0ms | 100% | `run-smoke.sh` |
| `praxis-native` | ~5,100 | ~2.7ms | 100% | `run-smoke.sh` |
| `envoy-go-epp` | ~2,000 | ~12ms | 100% | `run-envoy-go-epp-smoke.sh` |

## GuideLLM Benchmark

GuideLLM provides LLM-specific metrics (TTFT, ITL, token throughput) that
Vegeta does not. It runs as a separate harness against the same profile
endpoints, with no proxy config changes:

```console
./benchmarks/llm-d/run-guidellm-sim-benchmark.sh [MAX_SECONDS]
```

The script uses `--backend-kwargs '{"validate_backend": false}'` and
explicit `--model test-model`. GuideLLM does not call `/v1/models` or
`/health` on the profiled endpoint. The script does its own curl preflight
against `/v1/chat/completions` before running GuideLLM.

Supported GuideLLM profiles: `concurrent`, `constant`, `poisson`, `sweep`.

See [results.md](results.md) for GuideLLM result tables.

### Harness Comparison

| Harness | What it measures | When to use |
|---------|-----------------|-------------|
| Vegeta | Control-path RPS, p50/p95/p99, architecture overhead | Comparing proxy paths, body handling, fixed-workload throughput |
| GuideLLM | TTFT, ITL, token throughput, OpenAI-client traffic patterns | LLM-shaped workloads, streaming behavior, future GPU validation |

## Configuration

Proxy configs live in `benchmarks/comparison/configs/llmd/`:

| File | Purpose |
|------|---------|
| `praxis-simple.yaml` | Praxis generic router + load balancer, backend on 18080 |
| `praxis-native.yaml` | Praxis `llmd_endpoint_picker`, static endpoint on 18080 |
| `envoy-go-epp.yaml` | Envoy listener on 18091, ext_proc to EPP on 9002, ORIGINAL_DST |
| `epp-config.yaml` | Go EPP scheduling config (file discovery, random picker) |
| `epp-endpoints.yaml` | Static endpoint list (127.0.0.1:18080) |

## Claims To Make

- Praxis can run llm-d-style endpoint selection in process.
- The benchmark harness can compare request parsing, scheduling, route
  selection, and forwarding overhead between architectures.
- Requests in the envoy-go-epp profile genuinely traverse Envoy, ext_proc
  gRPC, and the Go EPP process before reaching the backend.

## Claims Not To Make

- Do not claim mock-backend benchmarks prove real GPU throughput.
- Do not claim these numbers are production throughput.
- Do not claim the throughput gap is the final answer; say the gap justifies
  longer controlled benchmarks.
- Do not claim approximate prefix-affinity proves real vLLM KV-cache hits.
- Do not claim P/D role-routing benchmarks prove NIXL/RDMA data movement.
- Do not claim TTFT improvement until real or simulated KV-cache latency
  scenarios are explicitly measured.

## Proposed Demo Flow

1. Show the baseline request path:
   `Client -> Envoy -> ext_proc -> Go EPP -> mock backend`.
2. Show the Praxis native request path:
   `Client -> Praxis -> llmd_endpoint_picker -> mock backend`.
3. Run the Praxis smoke: `./benchmarks/llm-d/run-smoke.sh 10 2`.
4. Run the Envoy+EPP smoke: `./benchmarks/llm-d/run-envoy-go-epp-smoke.sh 10 2`.
5. Present the result table with throughput, p50, p95, p99, and error rate.
6. Close with the boundary: these numbers measure control-path cost against a
   mock backend, not production model-serving performance. The gap justifies
   deeper investigation with `llm-d-inference-sim` and longer benchmark runs.

## Future Work

- Replace mock backend with `llm-d-inference-sim` for realistic request/response
  latency.
- Run longer benchmarks with multiple repetitions and median selection.
- Add `envoy-praxis-native` profile (Envoy outer ingress, Praxis scheduling).
- Add load-aware scoring, prefix-affinity, and saturation workloads.
- Add KIND mode for Kubernetes-native comparisons.
- GPU-backed benchmarks for real vLLM/SGLang saturation, TTFT, KV-cache, and
  P/D data movement.
