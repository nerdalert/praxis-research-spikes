# Track B Demo Scripts

## Setup

```bash
git clone -b track-b-benchmarking https://github.com/nerdalert/praxis.git praxis-track-b
cd praxis-track-b && cargo build --release -p praxis --features ext-proc
export TRACK_B_DIR="$(pwd)"
cd ..

# Go EPP and Simulator — clone and build, then export paths
export EPP_BIN=/path/to/llm-d-router/bin/epp
export SIM_BIN=/path/to/llm-d-inference-sim/bin/llm-d-inference-sim
```

See [deploy.md](../deploy.md) for full setup instructions.

> **Claim boundary:** Track B demos prove Praxis carries the Go EPP
> scheduling decision without Envoy. They do not prove Praxis-native
> scheduling features — those are Track A.

## Narrated Demos

| # | Script | What it proves |
|---|---|---|
| 01 | `01-praxis-to-go-epp-request-path/run-request-path.sh` | Client -> Praxis -> Go EPP -> backend. HTTP 200, EPP log proof, fail-closed 503. |
| 02 | `02-failure-behavior-and-recovery/run-failure-recovery.sh` | Oversize body 413 (no EPP call), EPP-down 503, EPP restart recovery. |
| 03 | `03-kubernetes-go-epp-load-aware-routing/run-kubernetes-load-aware.sh` | Two backends, asymmetric load. Go EPP scores by KV cache utilization, picks idle backend. Praxis applies the decision. |
| 04 | *(benchmark)* | Open [`demo/llm-d-benchmarks/results.md`](../../llm-d-benchmarks/results.md) for `praxis-go-epp` vs `envoy-go-epp`. |

## Running

```bash
# 01 - Praxis-to-Go-EPP request path
bash scripts/01-praxis-to-go-epp-request-path/run-request-path.sh

# 02 - Failure behavior and recovery
bash scripts/02-failure-behavior-and-recovery/run-failure-recovery.sh

# 03 - Kubernetes Go EPP load-aware routing (also needs TRACK_B_IMPL_DIR)
bash scripts/03-kubernetes-go-epp-load-aware-routing/run-kubernetes-load-aware.sh

# KIND cleanup
bash scripts/cleanup.sh
```

## Utility Scripts

| Script | Purpose |
|---|---|
| `common.sh` | Shared variables, helpers, process management (sourced, not run directly) |
| `check-prereqs.sh` | Verify required tools and paths |
| `run-01-request-path.sh` | Delegates to implementation tree's local request-path validation (non-narrated) |
| `run-03-kubernetes-load-aware.sh` | Delegates to narrated Demo 03 |
| `cleanup.sh` | Delete the Track B KIND cluster |

## Manual Curls

If you prefer to run the components yourself:

```bash
# Start simulator
<sim-binary> --model test-model --served-model-name test-model --port 18080 &

# Start Go EPP
<epp-binary> --pool-name bench-pool --config-file <config> \
  --grpc-port 9002 --secure-serving=false --health-checking=false &

# Start Praxis
PRAXIS_CONFIG=<config> <praxis-binary> &

# Send request through Praxis -> Go EPP -> backend
curl -s -X POST http://127.0.0.1:18091/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test-model","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'

# Verify Go EPP processed it
grep "EPP received request" /tmp/track-b-demo-epp.log

# Test fail-closed (kill EPP first)
curl -s -w "\n%{http_code}" -X POST http://127.0.0.1:18091/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test-model","messages":[{"role":"user","content":"fail"}]}'
# Expected: 503
```
