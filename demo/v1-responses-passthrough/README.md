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

Praxis does not execute function tools in this passthrough profile. The client
continues to own its tool loop.

## Demo: Codex Tool Loop Through Praxis

The primary demo. A real Codex CLI completes its tool loop through Praxis
with no API key, no external service, and a deterministic mock backend.

### Automated

```bash
./scripts/run-codex-e2e.sh
```

### Manual

Start the mock backend and Praxis, then paste the printed Codex command:

```bash
./scripts/start-codex-e2e-backend.sh
```

After Codex finishes, check the proof file and backend request logs:

```bash
cat ~/codex-e2e-manual/workspace/proof.txt
python3 -c "import json; print('req1 model:', json.load(open('$HOME/codex-e2e-manual/logs/backend-req-1.json'))['model'])"
python3 -c "import json; print('req2 model:', json.load(open('$HOME/codex-e2e-manual/logs/backend-req-2.json'))['model'])"
```

### What Happens

| Step | What happens |
|---:|---|
| 1 | Codex sends `model: "codex-demo-client-name"` to Praxis |
| 2 | Praxis rewrites model to `llama-3.3-70b` |
| 3 | Mock backend returns SSE `exec_command` function call |
| 4 | Codex executes command locally, creates `proof.txt` |
| 5 | Codex sends `function_call_output` with matching `call_id` through Praxis |
| 6 | Mock returns final text response |
| 7 | Verifier confirms: 2 requests, rewritten model, proof content, JSONL events |

### Verification (14 structural checks)

| Check | What it proves |
|---|---|
| Exactly two backend requests | No unexpected retries or third request |
| Both models are `llama-3.3-70b` | Praxis rewrote `codex-demo-client-name` |
| Request 1 advertises `exec_command` | Codex tool definitions forwarded through Praxis |
| Request 2 has `function_call_output` | Codex executed the tool and sent the result back |
| `call_id` matches | Correlation preserved across the round trip |
| `proof.txt` exists with exact content | The command actually ran and produced the right output |
| JSONL has `command_execution` | Codex parsed and executed the function call |
| JSONL has `turn.completed` | Codex finished successfully |

The generated demo output is in [demo-output.md](demo-output.md).

## Integration Tests

Seven scenarios validating individual filter behaviors with deterministic
mock backends. These run without Codex — pure HTTP assertions via curl.

```bash
./scripts/run-smoke.sh
```

| # | Scenario | Assertion |
|---:|---|---|
| 1 | No-op passthrough | Backend receives the original Responses body unchanged |
| 2 | Model alias rewrite | `codex-mini-latest` reaches the backend as `llama-3.3-70b` |
| 3 | Default model injection | Missing model reaches the backend as `llama-3.3-70b` |
| 4 | Streaming SSE passthrough | Direct-backend and proxied SSE response bytes match |
| 5 | Codex-shaped tools request | Tool definitions remain semantically identical |
| 6 | Function-call follow-up | `function_call_output` and `call_id` remain intact |
| 7 | Mixed traffic | Chat Completions reaches the separate chat backend |

Regenerate the integration test transcript:

```bash
./run-complete-e2e-demo.sh
```

The generated output is in [integration-test-output.md](integration-test-output.md).

## Benchmarks

```bash
./scripts/run-benchmark.sh
```

| Profile | Pipeline |
|---|---|
| `direct-backend` | client -> mock backend |
| `praxis-format-route` | format -> router -> load balancer |
| `praxis-model-rewrite-noop` | format -> model rewrite no-op -> router -> load balancer |
| `praxis-model-rewrite-alias` | format -> model alias rewrite -> router -> load balancer |
| `praxis-full-flow` | format -> validate -> SQLite response store -> router -> load balancer |

Each profile runs small JSON, streaming SSE, 16/64/256 KiB payloads,
Codex-shaped tools, and function-call follow-up workloads. Raw JSON artifacts
are written under `artifacts/<UTC-run-id>/raw/`.

See [deploy.md](deploy.md) for environment overrides and reduced validation
runs.

## Files

| Path | Purpose |
|---|---|
| **Demo** | |
| `scripts/run-codex-e2e.sh` | Automated Codex CLI E2E: build, mock, Praxis, Codex exec, verify |
| `scripts/start-codex-e2e-backend.sh` | Start mock + Praxis for manual Codex validation |
| `scripts/codex_e2e_verifier.py` | Structural verifier for Codex E2E artifacts (14 checks) |
| `scripts/test_codex_e2e.py` | 37 unit tests for the mock and verifier |
| `mock-scripts/codex-tool-loop-mock.py` | Deterministic SSE backend for Codex E2E (2-request tool loop) |
| `demo-output.md` | Generated Codex E2E demo output |
| **Integration Tests** | |
| `scripts/run-smoke.sh` | Starts the local stack and asserts all 7 IT scenarios |
| `run-complete-e2e-demo.sh` | Regenerates the IT transcript |
| `scripts/smoke_client.py` | IT scenario assertions and transcript rendering |
| `integration-test-output.md` | Generated IT transcript |
| **Benchmarks** | |
| `scripts/run-benchmark.sh` | Runs all benchmark profiles and workloads |
| `scripts/benchmark_client.py` | Stdlib load generator, metadata capture, and summarizer |
| `results.md` | Publishable-results template and claim boundaries |
| **Shared** | |
| `scripts/common.sh` | Shared process lifecycle and generated-config helpers |
| `mock-scripts/responses-echo-mock.py` | Deterministic JSON backend |
| `mock-scripts/responses-streaming-echo-mock.py` | Deterministic SSE backend |
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
