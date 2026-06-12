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

**Automated:**

```bash
./scripts/run-codex-e2e.sh
```

**Manual** — start the backend, then paste the printed Codex command:

```bash
./scripts/start-codex-e2e-backend.sh
```

**Verify:**

```bash
cat ~/codex-e2e-manual/workspace/proof.txt
python3 -c "import json; print('req1 model:', json.load(open('$HOME/codex-e2e-manual/logs/backend-req-1.json'))['model'])"
python3 -c "import json; print('req2 model:', json.load(open('$HOME/codex-e2e-manual/logs/backend-req-2.json'))['model'])"
```

**What happens:**

1. Codex sends `model: "codex-demo-client-name"` to Praxis.
2. Praxis rewrites model to `llama-3.3-70b`.
3. Mock backend returns SSE `exec_command` function call.
4. Codex executes command locally, creates `proof.txt`.
5. Codex sends `function_call_output` with matching `call_id` through Praxis.
6. Mock returns final text response.
7. Verifier confirms: 2 requests, rewritten model, proof content, JSONL events.

**14 structural checks** verify request count, model rewrite, tool
advertisement, call\_id correlation, proof file content, and Codex JSONL
events.

See [demo-output.md](demo-output.md) for the full command-by-command
transcript with verbatim output.

---

## Integration Tests

Seven scenarios validating individual filter behaviors with deterministic
mock backends. These run without Codex — pure HTTP assertions.

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

Regenerate the transcript:

```bash
./run-complete-e2e-demo.sh
```

See [integration-test-output.md](integration-test-output.md) for the full
generated transcript.

---

## Benchmarks

```bash
./scripts/run-benchmark.sh
```

Five pipeline profiles, each tested with seven workloads (small JSON,
streaming SSE, 16/64/256 KiB payloads, tools, function-call follow-up).
Raw JSON artifacts are written under `artifacts/<UTC-run-id>/raw/`.

See [results.md](results.md) for the latest benchmark results and
interpretation guardrails.

See [deploy.md](deploy.md) for environment overrides, port configuration,
and reduced validation runs.

---

## Claim Boundaries

- Mock-backend benchmarks measure local request-path overhead, not GPU
  inference or model-serving performance.
- Streaming TTFE is time to the first mock SSE event, not real model
  time-to-first-token.
- Results from fewer than three raw runs per profile/workload are
  validation evidence only, not publishable benchmark conclusions.
- The Codex E2E test uses `--dangerously-bypass-approvals-and-sandbox`
  because bubblewrap does not work in container/CI environments without
  `CAP_NET_ADMIN`.
- This demo does not claim deployable token-usage extraction.
