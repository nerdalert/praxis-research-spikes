# llm-d Performance Benchmarks

> **Disclaimer:** These are early fuzzing results from a single-node
> development environment using `llm-d-inference-sim` in echo mode without GPU
> inference. They compare request-path behavior and relative overhead; they are
> not production performance claims.

This is the single benchmark location for all llm-d proxy profiles:
Track A, Track B, and the existing upstream llm-d Envoy+Go EPP baseline.

- **[Benchmark Results](results.md)** — Full result tables, graphs, and claim boundaries.
- **[Demo Outline](demo-outline.md)** — Slide-by-slide presentation script.

---

## Profiles

### `praxis-native` — Track A

**Role:** Praxis replaces Envoy **and** the Go EPP with in-process scheduling.

```
Client -> Praxis llmd_endpoint_picker -> selected backend
```

Praxis buffers the request, extracts the model, evaluates endpoint state,
selects the upstream, and forwards directly. No Envoy, no `ext_proc` hop,
no external Go EPP process. This is the fastest llm-d path because
everything runs in one process.

> **Track A answers:** What happens if Praxis becomes the native llm-d scheduler?

---

### `praxis-ext-proc-full-duplex-go-epp` — Track B

**Role:** Praxis replaces Envoy but **keeps the Go EPP** as the scheduler.

```
Client -> Praxis ext_proc (full-duplex) -> Go EPP (gRPC) -> endpoint_selector -> selected backend
```

Praxis buffers the request, sends headers and body to the Go EPP through an
ext_proc-compatible gRPC stream, reads the selected endpoint from the
response, sets `ctx.upstream`, and forwards. The Go EPP remains the
scheduling brain — Track B does **not** eliminate it.

> **Track B answers:** What happens if Praxis replaces Envoy while keeping the existing Go EPP?

---

### `envoy-go-epp` — Baseline

**Role:** Existing upstream llm-d data-plane architecture today. Envoy calls
the Go EPP through `ext_proc`.

```
Client -> Envoy ext_proc -> Go EPP -> Envoy ORIGINAL_DST -> backend
```

This is the comparison target for both tracks. Envoy receives the request,
calls the Go EPP over `ext_proc` gRPC, applies the selected destination header,
and forwards via `ORIGINAL_DST` cluster. In these docs, **Baseline** always
means this existing upstream llm-d Envoy+Go EPP request path.

> **Baseline answers:** What does the current Envoy + Go EPP architecture cost?

---

## Key Comparisons

| Comparison | What it isolates |
|---|---|
| **Track B vs Baseline** | Proxy/runtime cost (Praxis vs Envoy), with the same Go EPP scheduler |
| **Track A vs Baseline** | Full request-path architecture cost (in-process scheduling vs Envoy + external EPP) |
| **Track A vs Track B** | Cost of preserving the external Go EPP hop rather than moving scheduling into Praxis |

---

## What Actually Runs

These are **local-process benchmarks**. Each run starts only:

- A load generator (Vegeta or GuideLLM)
- One proxy (Praxis or Envoy)
- The Go EPP process (for `envoy-go-epp` and `praxis-ext-proc-full-duplex-go-epp` only)
- One backend (`llm-d-inference-sim` echo mode for the published comparison)

**Not running:** Full llm-d API Gateway, Gateway API controllers, Kubernetes
CRDs, `llm-d-deployer`, InferencePool reconciliation, real vLLM/SGLang
workers, GPU model serving, KV-cache transfer, or P/D data movement.

The Go EPP profiles run the **real Go EPP binary** from `llm-d-router` with
file discovery. They validate the proxy-to-EPP handoff, not the full
Kubernetes control plane.

> **No KIND manifests here.** These benchmarks are local-process runs — they
> start Praxis, Go EPP, and the simulator as local processes, not Kubernetes
> pods. KIND deployment manifests live in the track demo directories:
> - Track A: [`demo/llm-d-track-a/manifests/`](../llm-d-track-a/manifests/)
> - Track B: [`demo/llm-d-track-b/manifests/`](../llm-d-track-b/manifests/)

---

## Results

> **Do not duplicate tables here.** The source of truth is
> **[results.md](results.md)**.

| Workload | Link |
|---|---|
| Vegeta simulator echo | [results.md#vegeta-simulator-echo](results.md#vegeta-simulator-echo) |
| Vegeta large-prompt body handling | [results.md#vegeta-large-prompt-body-handling](results.md#vegeta-large-prompt-body-handling) |
| GuideLLM simulator echo | [results.md#guidellm-simulator-echo](results.md#guidellm-simulator-echo) |

---

## How To Run

### Prerequisites

- [Vegeta](https://github.com/tsenart/vegeta) v12.12.0+
- Python 3 (stdlib only)
- Rust stable 1.94+
- Docker (for Envoy baseline)
- Go 1.25+ (for Go EPP)

### Track A (`praxis-native`)

```bash
cd praxis   # Track A branch: e2e-llm-d-epp-benchmarking
./benchmarks/llm-d/run-smoke.sh 5 1
```

### Track B Full-Duplex (`praxis-ext-proc-full-duplex-go-epp` + `envoy-go-epp`)

```bash
# Use the ext_proc Praxis/llm-d POC branch
git clone -b ext-proc-llm-d-praxis-poc-v2 https://github.com/nerdalert/praxis.git
cd praxis

# Simulator echo
PRAXIS_BIN=./target/release/praxis \
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-full-duplex-sim-benchmark.sh 30 5 3

# Large-prompt body handling
PRAXIS_BIN=./target/release/praxis \
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-full-duplex-large-prompt.sh 30 5 3
```

### Envoy + Go EPP Baseline

```bash
cd praxis   # Either branch
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-envoy-go-epp-smoke.sh 5 1
```

---

## Source Branches

| Branch | Purpose |
|---|---|
| `nerdalert/praxis:e2e-llm-d-epp-benchmarking` | Track A benchmark branch |
| `nerdalert/praxis:ext-proc-llm-d-praxis-poc-v2` | ext_proc Praxis/llm-d POC branch (Track B full-duplex) |

```bash
# Track A (unchanged)
git clone https://github.com/nerdalert/praxis.git
cd praxis && git checkout e2e-llm-d-epp-benchmarking

# Track B full-duplex
git clone -b ext-proc-llm-d-praxis-poc-v2 https://github.com/nerdalert/praxis.git

# Go EPP
git clone https://github.com/llm-d/llm-d-router.git

# Simulator
git clone https://github.com/llm-d/llm-d-inference-sim.git
```

---

## Claim Boundaries

**Can claim:**
- Track B proves Praxis can replace Envoy while keeping the Go EPP.
- Track A proves Praxis can run llm-d scheduling in-process.
- Requests genuinely traverse the ext_proc gRPC path in both EPP profiles.
- The benchmark harness compares proxy and scheduler overhead.

**Cannot claim:**
- These numbers are not production throughput.
- Mock/simulator benchmarks do not prove GPU inference performance.
- The throughput gap justifies further testing — it is not a final answer.
- TTFT improvement is not proven until real inference latency is measured.
- Track B does **not** eliminate the Go EPP.
