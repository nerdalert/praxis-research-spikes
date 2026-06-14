# Track B Deployment Guide

## Prerequisites

- Rust stable 1.94+ (for Praxis)
- Go 1.25+ (for Go EPP)
- Docker (for KIND images)
- KIND (for Kubernetes deployment)
- kubectl

## Source Repos

```bash
# Praxis ext_proc/llm-d POC branch
git clone -b ext-proc-llm-d-praxis-poc-v2 https://github.com/nerdalert/praxis.git
cd praxis
cargo build --release -p praxis --features ext-proc
export PRAXIS_BIN="$(pwd)/target/release/praxis"

# Go EPP
git clone https://github.com/llm-d/llm-d-router.git
cd llm-d-router && go build -o bin/epp ./cmd/epp && cd ..
export EPP_BIN="$(pwd)/llm-d-router/bin/epp"

# Simulator
git clone https://github.com/llm-d/llm-d-inference-sim.git
cd llm-d-inference-sim && make build && cd ..
export SIM_BIN="$(pwd)/llm-d-inference-sim/bin/llm-d-inference-sim"
```

## Required Praxis Base

Track B builds on [Praxis PR #428](https://github.com/praxis-proxy/praxis/pull/428)
which adds the ext_proc tonic client foundations. The full-duplex
implementation extends PR #428 with the duplex exchange core,
`endpoint_selector`, and request-routing integration.

The current implementation is on the
[ext_proc Praxis/llm-d POC branch](https://github.com/nerdalert/praxis/tree/ext-proc-llm-d-praxis-poc-v2)
at commit `d2ca1f1`.

## Praxis Configuration

Track B uses the generic `ext_proc` filter with full-duplex streaming
and the `endpoint_selector` filter for trusted upstream selection:

```yaml
listeners:
  - name: llmd
    address: "0.0.0.0:8080"
    filter_chains: [full-duplex-epp]

filter_chains:
  - name: full-duplex-epp
    filters:
      - filter: ext_proc
        target: "http://go-epp:9002"
        message_timeout_ms: 5000
        lifecycle_timeout_ms: 10000
        status_on_error: 503
        processing_mode:
          request_header_mode: send
          response_header_mode: skip
          request_body_mode: full_duplex_streamed
          response_body_mode: none
          request_trailer_mode: skip
          response_trailer_mode: skip
      - filter: endpoint_selector
        source_header: x-gateway-destination-endpoint
        required: true
        status_on_required_failure: 503
        strip_header: true
```

## Local Process Deployment

### Run the full-duplex request-routing suite (8 assertions)

```bash
cd demo/llm-d-track-b
bash scripts/local-request-routing/run-request-routing.sh
```

This starts the simulator, Go EPP, and Praxis, then verifies:
- Correct backend/model selection
- Malicious client destination header ignored
- Internal destination header stripped at backend
- Request body semantics preserved without duplication
- Exactly one Process invocation per HTTP request
- Repeated requests without crosstalk
- Exact HTTP 503 when EPP unavailable
- EPP restart recovery

## KIND Deployment

### Run the KIND request-routing suite (5 assertions)

```bash
bash scripts/kind-request-routing/run-request-routing.sh
```

The script will:
1. Build three container images (Praxis, Go EPP, Simulator)
2. Create a `llmd-track-b-v2` KIND cluster
3. Deploy the full-duplex composition
4. Run routing, repeated requests, EPP failure/recovery, h2 checks
5. Delete the cluster on exit

Set `SKIP_BUILD=1` to skip image builds.
Set `KEEP_CLUSTER=1` to preserve the cluster for debugging.

### Container Images

| Image | Source | Purpose |
|---|---|---|
| `praxis-track-b-v2:local` | `Containerfile.praxis-track-b-v2` | Praxis with ext-proc full-duplex |
| `go-epp-track-b-v2:local` | `llm-d-router/Dockerfile.epp` | Go EPP |
| `llmd-sim-track-b-v2:local` | `llm-d-inference-sim/Dockerfile` | Simulator |

## Benchmark Deployment

See [benchmark docs](../llm-d-benchmarks/README.md) for benchmark scripts
and methodology. The benchmark profile is
`praxis-ext-proc-full-duplex-go-epp`.
