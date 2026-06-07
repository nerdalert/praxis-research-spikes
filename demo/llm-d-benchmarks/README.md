# llm-d Track A and Track B Benchmark Demo

> **Disclaimer:** All results in this demo are from a single-node development
> environment using `llm-d-inference-sim` in echo mode without GPU inference.
> These are not validated performance claims. Results should not be referenced
> as production benchmarks until reproduced on properly sized and isolated
> hardware with real model serving backends.

This demo area is for public-facing benchmark instructions, result tables, and
presentation material for the Praxis llm-d integration tracks. It is the single
benchmark location for Track A, Track B, `praxis-simple`, and the
`envoy-go-epp` baseline.

- Track A is `praxis-native`: Praxis runs the in-process
  `llmd_endpoint_picker` and removes Envoy `ext_proc` plus the external Go EPP
  process from the request path.
- Track B is `praxis-go-epp`: Praxis replaces Envoy as the proxy/runtime while
  the existing Go EPP remains the scheduling brain through
  `llmd_external_epp`.
- Baseline is `envoy-go-epp`: Envoy calls the existing Go EPP through
  `ext_proc`.

Related files in this directory:
- [Consolidated Track A and Track B benchmark results](results.md) — Full result tables with run metadata and claim boundaries.
- [Track A and Track B benchmark demo outline](demo-outline.md) — Slide-by-slide demo script.

The benchmark story is focused on request-path cost across Track A, Track B,
and the current Envoy plus Go EPP baseline:

- Track A: the native Praxis `llmd_endpoint_picker` path, where Praxis performs
  endpoint picking in process and removes Envoy `ext_proc` plus the external Go
  EPP process from the request path;
- Track B: the `praxis-go-epp` path, where Praxis replaces Envoy as the proxy
  but keeps the existing Go EPP scheduling brain through the
  `llmd_external_epp` ext_proc-compatible client filter;
- the current `envoy-go-epp` baseline, where Envoy calls the Go EPP through
  `ext_proc`;
- optional compatibility paths where Envoy remains at the edge.

The benchmark set has two no-GPU targets. Mock-backend runs isolate proxy and
scheduler overhead with minimal Python or Go backends. Simulator runs use
`llm-d-inference-sim` in echo mode for OpenAI-compatible responses without real
GPU inference.

## What Actually Runs

These are local-process benchmark runs unless a section explicitly says KIND.
They do not run a full llm-d Kubernetes deployment.

Each local run starts only the components needed for the profile under test:

- A load generator: Vegeta for raw request-path throughput, or GuideLLM for
  OpenAI/LLM-shaped client behavior.
- One proxy path: Praxis, Envoy, or both depending on the profile.
- The Go EPP process only for `envoy-go-epp` and `praxis-go-epp`.
- One backend: a minimal mock backend, a Go mock backend, or
  `llm-d-inference-sim` in echo mode.

What is not running in these local benchmarks:

- The full llm-d API Gateway or Gateway API controller stack.
- llm-d Kubernetes CRDs, `llm-d-deployer`, InferencePool reconciliation, or
  Kubernetes service discovery unless a KIND-specific scenario says so.
- Real vLLM/SGLang workers, GPU model serving, KV-cache transfer, or P/D data
  movement.

For the Go EPP profiles, the benchmark runs the real Go EPP binary from
`llm-d-router`, but with file discovery pointing at benchmark backends. That
proves the Envoy/Praxis to Go EPP request path and endpoint-selection handoff;
it does not prove the full llm-d control-plane deployment.

## Why This Should Carry Over To Full llm-d

The local benchmarks exercise the same request-path contract that a full llm-d
deployment depends on:

- The proxy receives an OpenAI-compatible `/v1/chat/completions` request.
- The proxy sends request headers and body to the Go EPP over the ext_proc
  protocol, or an ext_proc-compatible Praxis client in Track B.
- The Go EPP returns a selected endpoint through the same response metadata.
- The proxy forwards the original request to the selected model backend.

In a full llm-d deployment, the API Gateway, Gateway API resources,
`ModelService` controller, `InferencePool` resources, Services, and CRDs create
and maintain that topology. They decide what proxy and EPP Services exist, how
routes attach, how model backends are discovered, and how deployment lifecycle
is reconciled. They are important, but they are not expected to change the
per-request ext_proc contract once traffic reaches Envoy or Praxis.

The main difference is discovery and environment. These benchmarks use static
file discovery for the Go EPP and local mock or simulator backends. A full llm-d
deployment usually uses Kubernetes resources, Services, pod discovery, metrics
scraping, and real vLLM/SGLang workers. That can change absolute throughput and
enable richer scheduling behavior, so full deployment smoke and GPU-backed
tests are still required. The local benchmark gives confidence in the proxy/EPP
hot path, not in every Kubernetes controller or production model-serving path.

What would make the local result fail to carry over:

- Full llm-d enables EPP plugins that require Kubernetes-only state not present
  in file discovery, such as `InferenceModelRewrite`, `InferenceObjective`,
  richer endpoint subsets, or metrics-driven policy inputs.
- The deployed Gateway/Envoy path relies on Envoy-specific metadata or filter
  behavior that Track B's Praxis ext_proc client does not yet reproduce.
- The production route uses TLS, mTLS, authn/authz, service mesh filters,
  retries, or timeout behavior that is not in the local benchmark.
- Kubernetes networking, Service routing, pod placement, or sidecars dominate
  the latency profile.
- Real vLLM/SGLang behavior, GPU saturation, KV-cache pressure, P/D routing, or
  autoscaling becomes the bottleneck instead of proxy/EPP overhead.

Those are the next validation targets. The current benchmark says the basic
Praxis/Envoy to Go EPP handoff is real and measurable; it does not say every
full-deployment feature is already covered.

## Demo Goals

- Show the request path being measured.
- Compare Envoy plus Go EPP against Track A native Praxis scheduling.
- Compare Envoy plus Go EPP against Track B Praxis plus Go EPP scheduling.
- Keep mock-backend numbers honest: control-path only.
- Make clear which results are proxy/scheduler overhead and which require GPU
  validation later.

## Primary Profiles

| Profile | Request path | Status |
|---------|--------------|--------|
| `envoy-go-epp` | Client -> Envoy ext_proc -> Go EPP -> backend | Runnable (Docker Envoy, local EPP, file discovery) |
| `praxis-go-epp` | Client -> Praxis `llmd_external_epp` ext_proc -> Go EPP -> backend | Runnable (Track B) |
| `praxis-native` | Client -> Praxis `llmd_endpoint_picker` -> backend | Runnable |
| `praxis-simple` | Client -> Praxis generic proxy -> backend | Runnable |
| `envoy-praxis-native` | Client -> Envoy -> Praxis native picker -> backend | Planned |

Track naming:

| Track | Profile | Components |
|-------|---------|------------|
| Track A | `praxis-native` | Praxis + in-process `llmd_endpoint_picker`; no Envoy, no `ext_proc`, no Go EPP process. |
| Track B | `praxis-go-epp` | Praxis + `llmd_external_epp` + existing Go EPP; Praxis replaces Envoy, Go EPP remains the scheduler. |
| Baseline | `envoy-go-epp` | Envoy + `ext_proc` + existing Go EPP. |

There are two direct comparisons to lead with:

```text
Track A: envoy-go-epp  versus  praxis-native
Track B: envoy-go-epp  versus  praxis-go-epp
```

Track A isolates the cost of moving llm-d scheduling from an external Envoy
`ext_proc` service into the Praxis proxy process. Track B isolates the
Envoy-vs-Praxis proxy cost while keeping the same external Go EPP scheduling
process.

The Praxis profiles answer different questions:

| Profile | Question it answers | What changes |
|---------|---------------------|--------------|
| `praxis-simple` | How fast is ordinary Praxis proxying for this request shape? | No llm-d scheduling; just route and forward. |
| `praxis-native` | What is the added cost of doing llm-d endpoint selection inside Praxis? | Adds body parsing, model extraction, endpoint scoring, and direct upstream selection. |
| `praxis-go-epp` | What is the cost of Praxis calling the external Go EPP? | Same Go EPP as envoy-go-epp, but Praxis replaces Envoy at the edge. |

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

The Praxis branches used by this demo are:

| Branch | Purpose |
|--------|---------|
| [`nerdalert/praxis:e2e-llm-d-epp-benchmarking`](https://github.com/nerdalert/praxis/tree/e2e-llm-d-epp-benchmarking) | Track A benchmark branch with `praxis-simple`, `praxis-native`, and `envoy-go-epp` scripts. |
| [`nerdalert/praxis:track-b`](https://github.com/nerdalert/praxis/tree/track-b) | Track B implementation branch without custom benchmark scripts. Use this to inspect the upstreamable Praxis changes. |
| [`nerdalert/praxis:track-b-benchmarking`](https://github.com/nerdalert/praxis/tree/track-b-benchmarking) | Track B benchmark branch with the Track B implementation plus benchmark configs/scripts for `praxis-go-epp`. Use this to reproduce Track B numbers. |

Clone the Track A benchmark branch when reproducing the original Track A
numbers:

```console
git clone https://github.com/nerdalert/praxis.git
cd praxis
git checkout e2e-llm-d-epp-benchmarking
```

Clone the Track B benchmark branch when reproducing Track B numbers:

```console
git clone https://github.com/nerdalert/praxis.git praxis-track-b-benchmarking
cd praxis-track-b-benchmarking
git checkout track-b-benchmarking
```

Clone the Track B implementation-only branch when reviewing the Praxis code
without benchmark-specific files:

```console
git clone https://github.com/nerdalert/praxis.git praxis-track-b
cd praxis-track-b
git checkout track-b
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

### Step 5: Run Track B Benchmarks

Use the `track-b-benchmarking` Praxis branch for these commands:

```console
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-same-backend-benchmark.sh 30 5 3

LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-track-b-sim-benchmark.sh 30 5 3

LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-track-b-large-prompt.sh 30 5 3

LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-track-b-guidellm-sim.sh 30 4
```

Track B scripts run `praxis-simple`, `praxis-go-epp`, and `envoy-go-epp`.
They do not run `praxis-native`; that filter is Track A-only in the current
branches. Use the existing Track A results for `praxis-native` comparisons and
keep cross-branch comparisons labeled as directional unless the profiles were
run in the same session.

### Step 6: Compare

All scripts produce the same artifact shape. Compare the JSON throughput
and latency values directly, or use the text reports for a quick summary.
The benchmark scripts print a summary table at the end.

## Results

`README.md` intentionally does not duplicate benchmark tables. The source of
truth for numbers is [the consolidated Track A and Track B benchmark results](results.md).

Use these result sections:

| Result set | Link |
|------------|------|
| Track B same-backend Go mock comparison | [results.md: Track B Vegeta Same-Backend Go Mock](results.md#track-b-vegeta-same-backend-go-mock) |
| Track B simulator echo comparison | [results.md: Track B Vegeta Simulator Echo](results.md#track-b-vegeta-simulator-echo) |
| Track B large-prompt body handling | [results.md: Track B Vegeta Large-Prompt Body Handling](results.md#track-b-vegeta-large-prompt-body-handling) |
| Track B GuideLLM streaming benchmark | [results.md: Track B GuideLLM Simulator Echo](results.md#track-b-guidellm-simulator-echo) |
| Track A simulator echo comparison | [results.md: Track A Vegeta Simulator Echo](results.md#track-a-vegeta-simulator-echo) |
| Track A minimal mock comparison | [results.md: Track A Vegeta Minimal Mock Backend](results.md#track-a-vegeta-minimal-mock-backend) |
| Track A GuideLLM comparison | [results.md: Track A GuideLLM Simulator Echo](results.md#track-a-guidellm-simulator-echo) |

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

See [Track B GuideLLM results](results.md#track-b-guidellm-simulator-echo)
and the [Track A GuideLLM comparison](results.md#track-a-guidellm-simulator-echo)
for the result tables.

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
| `praxis-go-epp.yaml` | Track B Praxis `llmd_external_epp`, ext_proc-compatible callout to Go EPP |
| `envoy-go-epp.yaml` | Envoy listener on 18091, ext_proc to EPP on 9002, ORIGINAL_DST |
| `epp-config.yaml` | Go EPP scheduling config (file discovery, random picker) |
| `epp-endpoints.yaml` | Static endpoint list (127.0.0.1:18080) |

## Claims To Make

- Track A proves Praxis can run llm-d-style endpoint selection in process with
  `llmd_endpoint_picker`.
- Track B proves Praxis can replace Envoy while still using the existing Go EPP
  through `llmd_external_epp`.
- The benchmark harness compares request parsing, EPP callout, route selection,
  and forwarding overhead between `praxis-native`, `praxis-go-epp`, and
  `envoy-go-epp`.
- Requests in `envoy-go-epp` genuinely traverse Envoy, ext_proc gRPC, and the
  Go EPP process before reaching the backend.
- Requests in `praxis-go-epp` genuinely traverse Praxis, the
  `llmd_external_epp` filter, ext_proc-compatible gRPC, and the Go EPP process
  before reaching the backend.

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

1. Show the Track A request path:
   `Client -> Praxis -> llmd_endpoint_picker -> backend`.
2. Show the Track B request path:
   `Client -> Praxis -> llmd_external_epp -> Go EPP -> backend`.
3. Show the baseline request path:
   `Client -> Envoy -> ext_proc -> Go EPP -> mock backend`.
4. Run or cite the Track A smoke: `./benchmarks/llm-d/run-smoke.sh 10 2`.
5. Run the Track B same-backend benchmark:
   `./benchmarks/llm-d/run-same-backend-benchmark.sh 30 5 3`.
6. Present the result links in [results.md](results.md), not duplicated tables
   in this README.
7. Close with the boundary: these numbers measure control-path cost against
   mock or simulator backends, not production model-serving performance.

## Deployment Scenarios

| Scenario | Environment | Request Path | Status | GPU Required |
|----------|-------------|--------------|--------|--------------|
| Local praxis-native | Process | Client -> Praxis -> simulator | Runnable | No |
| Local praxis-simple | Process | Client -> Praxis proxy -> simulator | Runnable | No |
| Local praxis-go-epp | Process | Client -> Praxis -> Go EPP -> simulator | Runnable | No |
| Local envoy-go-epp | Process + Docker | Client -> Envoy -> EPP -> simulator | Runnable | No |
| KIND praxis-native-static | KIND | Client -> Praxis (NodePort) -> simulator pod | Validated | No |
| KIND envoy-to-praxis-native | KIND | Client -> Envoy edge -> Praxis native -> simulator pod | Validated | No |
| KIND envoy-go-epp | KIND | Client -> Envoy -> EPP -> simulator pod | Blocked (EPP container exits in KIND) | No |
| KIND praxis-native-inferencepool | KIND | Client -> Praxis (InferencePool discovery) -> simulator pods | Scaffolded, not run | No |
| KIND GuideLLM Job | KIND | GuideLLM Job -> profile Service -> simulator pod | Scaffolded, not run | No (client-side only) |
| GPU cluster | Real cluster | Any profile -> real vLLM/SGLang | Future | Yes |

### KIND Results (deployment validation, not production benchmarks)

> KIND results are deployment-path validation. KIND networking, Docker
> bridge, shared CPU, and pod scheduling add overhead. These numbers
> should not be compared directly to local-process results.

| KIND Scenario | RPS | p99 | Success |
|---------------|-----|-----|---------|
| praxis-native-static | 2,116 | 14.63ms | 100% |
| envoy-to-praxis-native | 1,858 | 16.10ms | 100% |

KIND manifests live in `benchmarks/llm-d/kind/manifests/`.
Run scripts: `benchmarks/llm-d/run-kind-*.sh`.

### KIND Blockers

- **envoy-go-epp in KIND**: The Go EPP container image exits immediately
  after "EPP starting" with exit code 1 in KIND. The same binary works
  locally and the same image works in local Docker. The issue appears to
  be in the EPP's gRPC server startup within the KIND container runtime.
  The local-process envoy-go-epp benchmark remains the valid baseline for
  this profile.

## Future Work

- Fix EPP container crash in KIND for the envoy-go-epp deployment scenario.
- Add KIND praxis-native-inferencepool with dynamic pod discovery.
- Run GuideLLM as a Kubernetes Job inside the cluster.
- Add load-aware scoring, prefix-affinity, and saturation workloads.
- GPU-backed benchmarks for real vLLM/SGLang TTFT, throughput, KV-cache,
  and P/D data movement.
- GPU-backed benchmarks for real vLLM/SGLang saturation, TTFT, KV-cache, and
  P/D data movement.
