# Native `/v1/responses` Passthrough Demo

An operator deploys Praxis between their AI clients and inference backends,
then configures alias rules like `codex-mini-latest` → `llama-3.3-70b`. When a
user (or tool like Codex) sends a `/v1/responses` request asking for
`codex-mini-latest`, Praxis silently swaps the model name in the request body
before it reaches the backend. The client never knows. If a request arrives
with no model at all, the operator can configure a default to be injected
automatically.

The operator also gets routing headers (`x-praxis-ai-effective-model`) so they
can send different rewritten models to different backend clusters — e.g. llama
requests go to one GPU pool, qwen requests go to another. All other request
fields (tools, instructions, input, streaming flags) pass through untouched.

This demo validates that behavior end-to-end using the production
`openai_responses_model_rewrite` filter plus the merged upstream Responses
classifier, validator, response store, router, and load balancer.

## What It Proves

- A native `POST /v1/responses` request passes through Praxis.
- Unknown model names can pass through unchanged.
- A configured model alias is rewritten before reaching the backend.
- A missing model can receive a configured default.
- SSE response bytes pass through unchanged.
- Codex-shaped `tools` definitions are preserved.
- Follow-up `function_call_output` items and `call_id` values are preserved.
- `/v1/responses` and `/v1/chat/completions` can share one listener and route to
  separate backends.
- A real Codex CLI completes its client-owned tool loop through Praxis without
  any API key or external service.
- The benchmark harness can isolate classifier, rewrite, and full-flow request
  path overhead.

Praxis does not execute function tools in this passthrough profile. The client
continues to own its tool loop.

## Architecture

### Passthrough Pipeline

Praxis sits between the Responses API client and the inference backend. The
classifier identifies the request format, the model rewrite filter translates
client-facing model names to backend deployment names, and the router forwards
to the appropriate cluster.

```text
┌──────────────────────┐
│  Codex / AI client   │
│  model: "codex-mini" │
└─────────┬────────────┘
          │ POST /v1/responses
          ▼
┌──────────────────────────────────────────────────┐
│  Praxis                                          │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ openai_responses_format                    │  │
│  │  • classify body: Responses / Chat / other │  │
│  │  • promote: format, model, stream, mode    │  │
│  │  • headers: x-praxis-ai-format, ...        │  │
│  └────────────────┬───────────────────────────┘  │
│                   │                              │
│  ┌────────────────▼───────────────────────────┐  │
│  │ openai_responses_model_rewrite             │  │
│  │  • alias: "codex-mini" → "llama-3.3-70b"  │  │
│  │  • default: inject when model is absent    │  │
│  │  • header: x-praxis-ai-effective-model     │  │
│  │  • body mutated, content-length updated    │  │
│  └────────────────┬───────────────────────────┘  │
│                   │                              │
│  ┌────────────────▼───────────────────────────┐  │
│  │ router + load_balancer                     │  │
│  │  • route by format/effective-model headers  │  │
│  │  • select upstream cluster + endpoint      │  │
│  └────────────────┬───────────────────────────┘  │
│                   │                              │
└───────────────────┼──────────────────────────────┘
                    │ model: "llama-3.3-70b"
                    ▼
          ┌──────────────────┐
          │ Inference backend│
          │ (vLLM, llm-d,   │
          │  OpenAI, mock)   │
          └──────────────────┘
```

### Codex E2E Tool-Loop Flow

The Codex E2E test proves the full client-owned tool loop works through Praxis.
The mock backend returns a deterministic `exec_command` function call, Codex
executes it locally, then sends the result back through Praxis.

```text
┌────────────┐         ┌──────────┐         ┌──────────────────┐
│ Codex CLI  │         │  Praxis  │         │  Mock Backend    │
│            │         │ :18280   │         │  :18285          │
└─────┬──────┘         └────┬─────┘         └───────┬──────────┘
      │                     │                       │
      │  POST /v1/responses │                       │
      │  model: "codex-     │                       │
      │   demo-client-name" │                       │
      │  tools: [exec_cmd]  │                       │
      │────────────────────>│                       │
      │                     │  model: "llama-3.3-   │
      │                     │   70b" (rewritten)    │
      │                     │──────────────────────>│
      │                     │                       │
      │                     │  SSE: function_call   │
      │                     │  name: exec_command   │
      │                     │  cmd: printf '...'    │
      │                     │   > proof.txt         │
      │                     │<──────────────────────│
      │  SSE: function_call │                       │
      │<────────────────────│                       │
      │                     │                       │
      │  [executes locally] │                       │
      │  proof.txt created  │                       │
      │                     │                       │
      │  POST /v1/responses │                       │
      │  function_call_     │                       │
      │   output + call_id  │                       │
      │────────────────────>│                       │
      │                     │  (rewritten model)    │
      │                     │──────────────────────>│
      │                     │                       │
      │                     │  SSE: final text      │
      │                     │<──────────────────────│
      │  "Proof file        │                       │
      │   created."         │                       │
      │<────────────────────│                       │
      │                     │                       │
      │  exit 0             │                       │
```

### Mixed-Traffic Routing

The smoke tests prove that Responses and Chat Completions traffic can share a
single listener while routing to separate backend clusters.

```text
                ┌──────────────────────────────────────┐
                │              Praxis :18280            │
                │                                      │
                │  openai_responses_format              │
                │         │                            │
                │    ┌────┴─────┐                      │
                │    ▼          ▼                      │
                │ Responses  Chat Completions          │
                │    │          │                      │
                │    ▼          ▼                      │
                │ model_    (skip rewrite)             │
                │ rewrite       │                      │
                │    │          │                      │
                │    ▼          ▼                      │
                │  router: by format + stream headers  │
                │    │       │        │                │
                └────┼───────┼────────┼────────────────┘
                     ▼       ▼        ▼
              ┌──────────┐ ┌────┐ ┌─────────┐
              │Responses │ │Chat│ │ Default  │
              │JSON / SSE│ │back│ │ backend  │
              │ backends │ │end │ │          │
              └──────────┘ └────┘ └─────────┘
```

## Quick Start

The default `PRAXIS_DIR` is the sibling checkout at `../praxis`.

```bash
cd demo/v1-responses-passthrough
./scripts/run-smoke.sh
```

### Codex E2E Test

Prove a real Codex CLI completes its tool loop through Praxis with no API key:

```bash
./scripts/run-codex-e2e.sh
```

Or start the backend manually and run Codex yourself:

```bash
./scripts/start-codex-e2e-backend.sh
# paste the printed codex command
# then: cat ~/codex-e2e-manual/workspace/proof.txt
```

### Regenerate Transcript

```bash
./run-complete-e2e-demo.sh
```

### Full Benchmark Matrix

```bash
./scripts/run-benchmark.sh
```

See [deploy.md](deploy.md) for environment overrides and reduced validation
runs.

## Demo Scenarios

### Smoke Scenarios (7)

| # | Scenario | Assertion |
|---:|---|---|
| 1 | No-op passthrough | Backend receives the original Responses body unchanged |
| 2 | Model alias rewrite | `codex-mini-latest` reaches the backend as `llama-3.3-70b` |
| 3 | Default model injection | Missing model reaches the backend as `llama-3.3-70b` |
| 4 | Streaming SSE passthrough | Direct-backend and proxied SSE response bytes match |
| 5 | Codex-shaped tools request | Tool definitions remain semantically identical |
| 6 | Function-call follow-up | `function_call_output` and `call_id` remain intact |
| 7 | Mixed traffic | Chat Completions reaches the separate chat backend |

### Codex E2E Scenario

| Step | What happens |
|---:|---|
| 1 | Codex sends `model: "codex-demo-client-name"` to Praxis |
| 2 | Praxis rewrites model to `llama-3.3-70b` |
| 3 | Mock backend returns SSE `exec_command` function call |
| 4 | Codex executes command locally, creates `proof.txt` |
| 5 | Codex sends `function_call_output` with matching `call_id` through Praxis |
| 6 | Mock returns final text response |
| 7 | Verifier checks: 2 requests, rewritten model, proof content, JSONL events |

The generated evidence is in [sample-output.md](sample-output.md).

## Benchmark Profiles

| Profile | Pipeline |
|---|---|
| `direct-backend` | client -> mock backend |
| `praxis-format-route` | format -> router -> load balancer |
| `praxis-model-rewrite-noop` | format -> model rewrite no-op -> router -> load balancer |
| `praxis-model-rewrite-alias` | format -> model alias rewrite -> router -> load balancer |
| `praxis-full-flow` | format -> validate -> SQLite response store -> router -> load balancer |

Each profile runs:

- Small JSON request.
- Streaming SSE request.
- 16 KiB, 64 KiB, and 256 KiB inputs.
- Codex-shaped request with tools.
- Follow-up request with `function_call_output`.

Raw runs are written under `artifacts/<UTC-run-id>/raw/`. Every JSON artifact
contains p50, p95, p99, RPS, success rate, and streaming TTFE where applicable.
The generated markdown summary reports the median across runs.

## Files

| Path | Purpose |
|---|---|
| `run-complete-e2e-demo.sh` | Regenerates the complete smoke transcript |
| `scripts/run-smoke.sh` | Starts the local stack and asserts all 7 smoke scenarios |
| `scripts/run-codex-e2e.sh` | Automated Codex CLI E2E: build, mock, Praxis, Codex exec, verify |
| `scripts/start-codex-e2e-backend.sh` | Start mock + Praxis for manual Codex validation |
| `scripts/codex_e2e_verifier.py` | Structural verifier for Codex E2E artifacts (14 checks) |
| `scripts/test_codex_e2e.py` | 37 unit tests for the mock and verifier |
| `scripts/run-benchmark.sh` | Runs all benchmark profiles and workloads |
| `scripts/common.sh` | Shared process lifecycle and generated-config helpers |
| `scripts/smoke_client.py` | Scenario assertions and transcript rendering |
| `scripts/benchmark_client.py` | Stdlib load generator, metadata capture, and summarizer |
| `mock-scripts/responses-echo-mock.py` | Deterministic JSON backend |
| `mock-scripts/responses-streaming-echo-mock.py` | Deterministic SSE backend |
| `mock-scripts/codex-tool-loop-mock.py` | Deterministic SSE backend for Codex E2E (2-request tool loop) |
| `results.md` | Publishable-results template and claim boundaries |
| `demo-outline.md` | Presentation walkthrough |

## Claim Boundaries

- Mock-backend benchmarks measure local request-path overhead, not GPU inference
  or model-serving performance.
- Streaming TTFE is time to the first mock SSE event, not real model
  time-to-first-token.
- Results from fewer than three raw runs per profile/workload are validation
  evidence only and must not be published as benchmark conclusions.
- The Codex E2E test uses `--dangerously-bypass-approvals-and-sandbox` because
  bubblewrap does not work in container/CI environments without `CAP_NET_ADMIN`.
- This demo does not claim deployable token-usage extraction.
