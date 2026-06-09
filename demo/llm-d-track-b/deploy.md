# Track B Deployment Guide

## Prerequisites

- Rust stable 1.94+ (for Praxis)
- Go 1.25+ (for Go EPP)
- Docker (for KIND images and Envoy baseline comparison)
- KIND (for Kubernetes deployment)
- `vegeta` (for benchmarks, optional)

## Source Repos

```bash
# Praxis (Track B benchmarking branch — includes implementation + benchmark scripts)
git clone -b track-b-benchmarking https://github.com/nerdalert/praxis.git praxis-track-b
cd praxis-track-b
cargo build --release -p praxis --features ext-proc
export TRACK_B_DIR="$(pwd)"
cd ..

# Go EPP
git clone https://github.com/llm-d/llm-d-router.git
cd llm-d-router && go build -o bin/epp ./cmd/epp && cd ..
export EPP_BIN="$(pwd)/llm-d-router/bin/epp"

# Simulator
git clone https://github.com/llm-d/llm-d-inference-sim.git
cd llm-d-inference-sim && make build && cd ..
export SIM_BIN="$(pwd)/llm-d-inference-sim/bin/llm-d-inference-sim"
```

## Required Praxis PR

Track B depends on [Praxis PR #428](https://github.com/praxis-proxy/praxis/pull/428)
which adds the ext_proc tonic client foundations. The `track-b-benchmarking` branch
includes PR #428 plus the Track B implementation on top.

## Local Process Deployment

### 1. Run the Praxis-to-Go-EPP request path demo

```bash
cd demo/llm-d-track-b
bash scripts/01-praxis-to-go-epp-request-path/run-request-path.sh
```

This starts the simulator, Go EPP, and Praxis, then verifies:
- HTTP 200 with correct model
- HTTP 413 for oversized body (no EPP call)
- HTTP 503 for EPP unavailable

### 2. Run the failure behavior and recovery demo

```bash
bash scripts/02-failure-behavior-and-recovery/run-failure-recovery.sh
```

## KIND Deployment (Demo 03: Load-Aware Routing)

Demo 03 deploys two simulator backends with asymmetric load in a KIND
cluster. The Go EPP scores both by KV cache utilization and routes to
the idle backend. Praxis applies the Go EPP decision.

### Prerequisites

- Docker
- KIND
- kubectl
- The Go EPP and simulator source repos (for image builds)

### 1. Clone the implementation branch

The KIND scripts live on the `track-b` implementation branch:

```bash
git clone -b track-b https://github.com/nerdalert/praxis.git praxis-track-b-impl
export TRACK_B_IMPL_DIR="$(pwd)/praxis-track-b-impl"
```

### 2. Run the demo

```bash
cd demo/llm-d-track-b
bash scripts/03-kubernetes-go-epp-load-aware-routing/run-kubernetes-load-aware.sh
```

Or run the implementation script directly:

```bash
bash praxis-track-b-impl/e2e/kind-go-epp/run-03-kubernetes-load-aware-routing.sh
```

The script will:
1. Build three container images (Praxis, Go EPP, Simulator)
2. Create a `llmd-track-b` KIND cluster with NodePort 30092
3. Deploy two simulators with fake-metrics (sim-a idle, sim-b busy)
4. Deploy Go EPP with `kv-cache-utilization-scorer` + `max-score-picker`
5. Deploy Praxis with `llmd_external_epp` filter
6. Send requests and verify the idle backend was selected

Set `SKIP_BUILD=1` to skip image builds (reuse existing images).
Set `CLEANUP=delete` to delete the cluster after the demo.

### 3. Cluster policy

The script requires the `llmd-track-b` cluster to be absent. Clean up
a previous run first:

```bash
kind delete cluster --name llmd-track-b
```

### 4. Container images

| Image | Source | Purpose |
|---|---|---|
| `praxis-track-b:local` | `Containerfile.praxis-track-b` | Praxis with ext-proc |
| `go-epp-track-b:local` | `llm-d-router/Dockerfile.epp` | Go EPP |
| `llmd-sim-track-b:local` | `llm-d-inference-sim/Dockerfile` | Simulator (x2, same image) |

### 5. Components

| Component | Config | Role |
|---|---|---|
| `sim-a` | kv-cache 10%, 0 running, 0 waiting | Idle backend |
| `sim-b` | kv-cache 90%, 8 running, 3 waiting | Busy backend |
| Go EPP | file-discovery + kv-cache scorer + max-score picker | Scores and selects endpoints |
| Praxis | `llmd_external_epp` → Go EPP ClusterIP:9002 | Calls Go EPP, applies decision |

Both simulators serve the same model. The Go EPP scrapes Prometheus
`/metrics` from each endpoint and uses the `kv-cache-utilization-scorer`
to score `1 - kv_usage`. The `max-score-picker` selects the highest score
(the idle backend).

### 6. EPP scheduling config

```yaml
plugins:
  - name: file-disc
    type: file-discovery
    parameters:
      path: /etc/epp/endpoints.yaml
  - name: kv-scorer
    type: kv-cache-utilization-scorer
  - name: best-picker
    type: max-score-picker
  - name: load-aware-profile
    type: single-profile-handler

schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: best-picker
      - pluginRef: kv-scorer

dataLayer:
  discovery:
    pluginRef: file-disc
```

The scorer and picker must be listed in `schedulingProfiles[].plugins` —
they are not inherited from the `single-profile-handler` parameters.
The EPP also auto-creates `metrics-data-source` and `core-metrics-extractor`
to scrape Prometheus `/metrics` from each endpoint.

### 7. Praxis configuration

```yaml
listeners:
  - name: llmd
    address: "0.0.0.0:8080"
    filter_chains: [epp]

filter_chains:
  - name: epp
    filters:
      - filter: llmd_external_epp
        target: "http://go-epp.llmd-track-b.svc.cluster.local:9002"
        request_timeout_ms: 10000
        max_request_body_bytes: 4194304
        status_on_error: 503

admin:
  address: "0.0.0.0:9901"

insecure_options:
  allow_public_admin: true
```

## Benchmark Deployment

The benchmark scripts are on the `track-b-benchmarking` branch (same as the
demo scripts):

```bash
git clone -b track-b-benchmarking https://github.com/nerdalert/praxis.git praxis-track-b
cd praxis-track-b
cargo build --release -p praxis --features ext-proc
```

See [benchmark docs](../llm-d-benchmarks/README.md) for benchmark scripts
and methodology.
