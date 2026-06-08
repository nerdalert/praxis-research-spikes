# Track B Deployment Guide

## Prerequisites

- Rust stable 1.94+ (for Praxis)
- Go 1.25+ (for Go EPP)
- Docker (for KIND images and Envoy baseline)
- KIND (for Kubernetes deployment)
- `llm-d-inference-sim` binary (for simulator backend)
- `vegeta` (for benchmarks)

## Local Process Deployment

The public demo scripts delegate to the Track B implementation checkout. Set
`TRACK_B_DIR` to that checkout before running the scripts.

### 1. Build Praxis with ext-proc

```bash
cd <praxis-checkout>
cargo build --release -p praxis --features ext-proc
```

### 2. Build Go EPP

```bash
cd <llm-d-router-checkout>
go build -o bin/epp ./cmd/epp
```

### 3. Run the local smoke

```bash
cd demo/llm-d-track-b
TRACK_B_DIR=<track-b-checkout> bash scripts/run-local-smoke.sh
```

This starts the simulator, Go EPP, and Praxis, then verifies:
- HTTP 200 with correct model
- HTTP 413 for oversized body (no EPP call)
- HTTP 503 for EPP unavailable

## KIND Deployment

### 1. Build container images

The KIND smoke builds all three images automatically:

```bash
cd demo/llm-d-track-b
TRACK_B_DIR=<track-b-checkout> bash scripts/run-kind-smoke.sh
```

Or build images manually:

```bash
# Praxis (Track B Containerfile, includes ext-proc)
docker build -t praxis-track-b:local \
  -f e2e/kind-go-epp/Containerfile.praxis-track-b \
  praxis/

# Go EPP (existing Dockerfile)
docker build -t go-epp-track-b:local \
  -f repos/llm-d-router/Dockerfile.epp \
  repos/llm-d-router/

# Simulator (existing Dockerfile)
docker build -t llmd-sim-track-b:local \
  -f ../llm-d-benchmarks/repos/llm-d-inference-sim/Dockerfile \
  ../llm-d-benchmarks/repos/llm-d-inference-sim/
```

### 2. Cluster policy

The KIND smoke requires the `llmd-track-b` cluster to be absent. Clean up first:

```bash
cd demo/llm-d-track-b
TRACK_B_DIR=<track-b-checkout> bash scripts/cleanup.sh
```

### 3. Manifests

| Manifest | Purpose |
|---|---|
| `manifests/namespace.yaml` | Namespace `llmd-track-b` |
| `manifests/simulator.yaml` | Simulator Deployment + Service |
| `manifests/go-epp.yaml` | EPP ConfigMaps + Deployment + Service |
| `manifests/praxis.yaml` | Praxis ConfigMap + Deployment + NodePort |

The EPP endpoints ConfigMap uses a `EPP_SIM_ADDRESS` placeholder that the smoke script patches with the simulator Service ClusterIP at deploy time.

### 4. Praxis configuration

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
