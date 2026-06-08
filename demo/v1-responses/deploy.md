# Deployment Guide

## Prerequisites

- **Rust stable 1.94+** (for building Praxis)
- **Python 3** (for mock backends)
- **Linux shell**
- **Git** (for cloning the repo)

Clone the Praxis repo and check out the e2e branch:

```bash
git clone https://github.com/nerdalert/praxis.git praxis-checkout
cd praxis-checkout
git checkout origin/brent-responses-api-e2e-not-for-merge
```

Build Praxis before starting the demo:

```bash
cd praxis-checkout
cargo build -p praxis --features ai-inference
```

---

## Terminal 1 — Mock Backends

Start four mock backends. Each one prints request logs to stdout.

```bash
cd praxis-research-spikes/demo/v1-responses

python3 mock-scripts/responses-loop-mock.py 13101 &
python3 mock-scripts/responses-streaming-loop-mock.py 13102 &
python3 mock-scripts/responses-state-mock.py 13103 &
python3 mock-scripts/tool-http-mock.py 14101 get_weather &
```

| Mock | Port | Behavior |
|------|------|----------|
| Loop model | 13101 | First call → `function_call(get_weather)`; second call (with `function_call_output`) → final text |
| Streaming model | 13102 | First call → SSE with argument deltas split across events; second call → final JSON |
| State model | 13103 | Returns `id: resp_mock_test_001` for state persistence tests |
| Weather tool | 14101 | Returns `{"weather":"sunny, 72F"}` for any POST to `/tool` |

---

## Terminal 2 — Praxis

Generate the config and start Praxis:

```bash
cat > /tmp/e2e-demo.yaml <<'YAML'
listeners:
  - name: gateway
    address: "127.0.0.1:18080"
    filter_chains: [orchestrator]

filter_chains:
  - name: orchestrator
    filters:
      - filter: responses_orchestrator
        timeout_ms: 5000
        max_iterations: 5
        models:
          loop-model:
            endpoint: "127.0.0.1:13101"
          stream-model:
            endpoint: "127.0.0.1:13102"
          state-model:
            endpoint: "127.0.0.1:13103"
        tools:
          get_weather:
            endpoint: "127.0.0.1:14101"
        conditions:
          - when:
              path: "/v1/responses"
              methods: [POST]
YAML

cd praxis-checkout
RUST_LOG=praxis=info cargo run -p praxis --features ai-inference -- -c /tmp/e2e-demo.yaml
```

Wait until you see `HTTP listener registered name=gateway address=127.0.0.1:18080`.

---

## Terminal 3 — Demo Curls

### 1. Non-Streaming Agentic Loop

The client sends a Responses request with `get_weather` advertised. Praxis calls the
model, the model asks for the tool, Praxis calls the tool, feeds the result back, and
the model returns the final answer.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"loop-model","input":"What is the weather in Boston?","tools":[{"type":"function","name":"get_weather"}]}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200, final answer "It is sunny and 72F in Boston."

**Check Terminal 1:** Loop model log shows POST #1 (original) and POST #2 (with
`function_call_output` and `call_weather_001`). Tool log shows POST #1 with
`{"city":"Boston"}`.

**Proves:** Full model → tool → model loop with `call_id` correlation.

---

### 2. Tool Not Advertised — Fails Closed

Same model returns `get_weather`, but the client did not advertise any tools.

```bash
curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"loop-model","input":"What is the weather in Boston?"}'
```

**Expected:** HTTP 400, `"tool 'get_weather' not advertised in request"`.

**Check Terminal 1:** Loop model receives one POST. Tool mock receives nothing new.

**Proves:** Request-scoped tool authorization — tools must be both advertised by
the client AND configured in Praxis.

---

### 3. Buffered Streaming Loop

The streaming mock returns SSE with function_call argument deltas split across
multiple events. Praxis buffers until arguments are complete, executes the tool
once, reinfers, and returns synthesized JSON.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"stream-model","input":"What is the weather in Boston?","stream":true,"tools":[{"type":"function","name":"get_weather"}]}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200, final JSON answer.

**Check Terminal 1:** Streaming mock shows POST #1 (SSE) and POST #2 (reinference).
Tool mock shows one POST with complete `{"city":"Boston"}`.

**Proves:** SSE argument buffering, single tool execution, synthesized JSON response.

---

### 4. Store State

Praxis persists the full conversation transcript (user input + model output) for
later continuation.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"state-model","input":"Remember this demo context.","store":true}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200, response `id: resp_mock_test_001`.

**Check Terminal 2 (Praxis log):** `persisting response response_id=resp_mock_test_001`.

**Proves:** `store:true` persistence with deterministic response IDs.

---

### 5. Continue with previous_response_id

References the stored response. Praxis loads the prior transcript and prepends it
before the new input.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"state-model","input":"Use the previous context now.","previous_response_id":"resp_mock_test_001"}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200.

**Check Terminal 1:** State mock POST #2 body contains an `input` array with the prior
user message ("Remember this demo context."), the prior assistant response, and the
new input ("Use the previous context now."). `previous_response_id` is removed from
the upstream model request.

**Proves:** Conversation continuation via `previous_response_id` with full transcript
replay.

---

### 6. Missing previous_response_id — Fails Closed

```bash
curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"state-model","input":"This should fail.","previous_response_id":"resp_missing"}'
```

**Expected:** HTTP 404, `"previous response not found: resp_missing"`.

**Check Terminal 1:** No new POST to state mock.

**Proves:** Missing state fails clearly without backend calls.

---

## One-Command Transcript

To generate a complete Markdown transcript automatically:

```bash
bash praxis-research-spikes/demo/v1-responses/run-complete-e2e-demo.sh \
  praxis-research-spikes/demo/v1-responses/sample-output.md
```

---

## AI-Assisted Setup

Copy the prompt below into an AI coding assistant (e.g. Claude Code) to have it
clone, build, and run the full demo automatically.

````text
Set up and run the Praxis Responses API agentic loop demo. Follow these steps:

1. Clone the Praxis repo and check out the e2e branch:

   git clone https://github.com/nerdalert/praxis.git <praxis-checkout>
   cd <praxis-checkout>
   git checkout origin/brent-responses-api-e2e-not-for-merge

2. Clone the research spikes repo (contains the mock scripts):

   git clone https://github.com/nerdalert/praxis-research-spikes.git <spike-checkout>

3. Build Praxis with the ai-inference feature:

   cd <praxis-checkout>
   cargo build -p praxis --features ai-inference

4. Start the four mock backends in the background:

   python3 <spike-checkout>/demo/v1-responses/mock-scripts/responses-loop-mock.py 13101 &
   python3 <spike-checkout>/demo/v1-responses/mock-scripts/responses-streaming-loop-mock.py 13102 &
   python3 <spike-checkout>/demo/v1-responses/mock-scripts/responses-state-mock.py 13103 &
   python3 <spike-checkout>/demo/v1-responses/mock-scripts/tool-http-mock.py 14101 get_weather &

5. Write the demo config to /tmp/e2e-demo.yaml:

   listeners:
     - name: gateway
       address: "127.0.0.1:18080"
       filter_chains: [orchestrator]
   filter_chains:
     - name: orchestrator
       filters:
         - filter: responses_orchestrator
           timeout_ms: 5000
           max_iterations: 5
           models:
             loop-model:
               endpoint: "127.0.0.1:13101"
             stream-model:
               endpoint: "127.0.0.1:13102"
             state-model:
               endpoint: "127.0.0.1:13103"
           tools:
             get_weather:
               endpoint: "127.0.0.1:14101"
           conditions:
             - when:
                 path: "/v1/responses"
                 methods: [POST]

6. Start Praxis with the config:

   cd <praxis-checkout>
   RUST_LOG=praxis=info cargo run -p praxis --features ai-inference -- -c /tmp/e2e-demo.yaml

   Wait for "HTTP listener registered" in the output before proceeding.

7. Run all six demo curls against http://127.0.0.1:18080/v1/responses and show
   the results. The six scenarios are:

   a) Non-streaming agentic loop (model=loop-model, tools=[get_weather])
   b) Tool not advertised — fails closed (model=loop-model, no tools)
   c) Buffered streaming loop (model=stream-model, stream=true, tools=[get_weather])
   d) Store state (model=state-model, store=true)
   e) Continue with previous_response_id=resp_mock_test_001
   f) Missing previous_response_id=resp_missing — fails closed

   See deploy.md in praxis-research-spikes/demo/v1-responses/ for the exact
   curl commands and expected outputs.

8. After running all curls, show a summary of which scenarios passed or failed,
   then clean up by killing the background mock processes.
````

---

## Cleanup

Kill background processes:

```bash
kill %1 %2 %3 %4  # mock backends from Terminal 1
# Ctrl+C in Terminal 2 to stop Praxis
```
