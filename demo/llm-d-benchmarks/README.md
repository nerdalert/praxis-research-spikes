# llm-d Performance Benchmarks

> **Disclaimer:** All results are from a single-node development environment
> using `llm-d-inference-sim` in echo mode without GPU inference. These are
> not validated performance claims.

This is the single benchmark location for all llm-d proxy profiles:
Track A, Track B, the Envoy baseline, and the generic Praxis control.

- **[Benchmark Results](results.md)** — Full result tables with methodology and claim boundaries.
- **[Demo Outline](demo-outline.md)** — Slide-by-slide presentation script.

---

## Profiles

### `praxis-simple` — Control

**Role:** Generic Praxis proxy baseline. Not an llm-d scheduler.

```
Client -> Praxis router/load_balancer -> backend
```

Measures pure Praxis/Pingora forwarding overhead for the same request shape.
No body parsing, no model extraction, no scheduling. Use this to isolate the
incremental cost of adding llm-d scheduling.

---

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

### `praxis-go-epp` — Track B

**Role:** Praxis replaces Envoy but **keeps the Go EPP** as the scheduler.

```
Client -> Praxis llmd_external_epp -> Go EPP (gRPC) -> selected backend
```

Praxis buffers the request, sends headers and body to the Go EPP through an
ext_proc-compatible gRPC stream, reads the selected endpoint from the
response, sets `ctx.upstream`, and forwards. The Go EPP remains the
scheduling brain — Track B does **not** eliminate it.

> **Track B answers:** What happens if Praxis replaces Envoy while keeping the existing Go EPP?

---

### `envoy-go-epp` — Baseline

**Role:** Current llm-d architecture. Envoy calls the Go EPP through `ext_proc`.

```
Client -> Envoy ext_proc -> Go EPP -> Envoy ORIGINAL_DST -> backend
```

This is the comparison target. Envoy receives the request, calls the Go EPP
over `ext_proc` gRPC, applies the selected destination header, and forwards
via `ORIGINAL_DST` cluster.

> **Baseline answers:** What does the current Envoy + Go EPP architecture cost?

---

## Key Comparisons

| Comparison | What it isolates |
|---|---|
| **Track B vs Baseline** | Proxy cost (Praxis vs Envoy), same Go EPP |
| **Track A vs Baseline** | Full architecture cost (in-process vs external EPP) |
| **Control vs Track A** | Incremental cost of native llm-d scheduling |
| **Control vs Track B** | Cost of ext_proc gRPC round-trip to Go EPP |

---

## What Actually Runs

These are **local-process benchmarks**. Each run starts only:

- A load generator (Vegeta or GuideLLM)
- One proxy (Praxis or Envoy)
- The Go EPP process (for `envoy-go-epp` and `praxis-go-epp` only)
- One backend (Go mock, Python mock, or `llm-d-inference-sim` echo mode)

**Not running:** Full llm-d API Gateway, Gateway API controllers, Kubernetes
CRDs, `llm-d-deployer`, InferencePool reconciliation, real vLLM/SGLang
workers, GPU model serving, KV-cache transfer, or P/D data movement.

The Go EPP profiles run the **real Go EPP binary** from `llm-d-router` with
file discovery. They validate the proxy-to-EPP handoff, not the full
Kubernetes control plane.

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

### Track A (praxis-simple + praxis-native)

```bash
cd praxis   # Track A branch: e2e-llm-d-epp-benchmarking
./benchmarks/llm-d/run-smoke.sh 5 1
```

### Track B (praxis-simple + praxis-go-epp + envoy-go-epp)

```bash
cd praxis-track-b-benchmarking   # Track B branch: track-b-benchmarking

# Same-backend Go mock (validated comparison)
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-same-backend-benchmark.sh 30 5 3

# Simulator echo
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-track-b-sim-benchmark.sh 30 5 3

# Large-prompt body handling
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-track-b-large-prompt.sh 30 5 3

# GuideLLM
LLM_D_ROUTER_REPO=../llm-d-router \
  ./benchmarks/llm-d/run-track-b-guidellm-sim.sh 30 4
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
| `nerdalert/praxis:track-b` | Track B implementation (no benchmark scripts) |
| `nerdalert/praxis:track-b-benchmarking` | Track B benchmark branch |

```bash
# Track A
git clone https://github.com/nerdalert/praxis.git
cd praxis && git checkout e2e-llm-d-epp-benchmarking

# Track B benchmarks
git clone https://github.com/nerdalert/praxis.git praxis-track-b-benchmarking
cd praxis-track-b-benchmarking && git checkout track-b-benchmarking

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
