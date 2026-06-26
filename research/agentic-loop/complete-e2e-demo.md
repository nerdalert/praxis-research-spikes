# Epic 354: Responses API Agentic Loop — Manual E2E Demo

This demo walks through the Praxis-owned Responses API orchestrator
running against mock backends. Each scenario proves a different
capability of the agentic loop.

**What is this?** Praxis sits between your application and the AI model.
When the model says "I need to call a tool," Praxis handles
that automatically — it calls the tool, feeds the result back to the
model, and returns the final answer to your app. Your app sends one
request and gets back a complete response, even if the model needed
multiple rounds of tool use behind the scenes.

---

## Setup

### Terminal 1 — Start mock backends

These simulate the model inference servers and a weather tool API.

```bash
cd <repo>/epic-354

python3 mock-scripts/responses-loop-mock.py 13101 &
python3 mock-scripts/responses-streaming-loop-mock.py 13102 &
python3 mock-scripts/responses-state-mock.py 13103 &
python3 mock-scripts/tool-http-mock.py 14101 get_weather &
```

### Terminal 2 — Start Praxis

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

cd <repo>/epic-354/e2e/praxis
RUST_LOG=praxis=info cargo run -p praxis --features ai-inference -- -c /tmp/e2e-demo.yaml
```

---

## Demo Scenarios

### 1. Non-Streaming Agentic Loop

**User story:** As a developer, I send one API request asking about the
weather. Behind the scenes, Praxis calls the model, the model asks for
the `get_weather` tool, Praxis calls the tool, feeds the result back to
the model, and the model gives me a final human-readable answer — all
in a single request/response.

**In plain terms:** You ask a question. The AI decides it needs to look
something up. Praxis does the lookup automatically and gives you the
complete answer. You never see the back-and-forth.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"loop-model","input":"What is the weather in Boston?","tools":[{"type":"function","name":"get_weather"}]}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200 with a final answer like "It is sunny and 72F in
Boston." Terminal 1 shows the model called twice (first returns a tool
request, second returns the answer) and the tool called once with
`{"city":"Boston"}`.

---

### 2. Unadvertised Tool — Fails Closed

**User story:** As a platform operator, I need to ensure Praxis only
executes tools the client explicitly opted into. If a client sends a
request without listing any tools, and the model still tries to call
one, Praxis must refuse — even though the tool exists in the config.

**In plain terms:** Just because a tool is available doesn't mean every
request should use it. The client has to say "I'm okay with these
tools." If it doesn't, Praxis blocks the tool call as a safety measure.

```bash
curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"loop-model","input":"What is the weather in Boston?"}'
```

**Expected:** HTTP 400 with `"tool 'get_weather' not advertised in
request"`. The tool mock receives no new request.

---

### 3. Buffered Streaming Loop

**User story:** As a developer, I send a streaming request. The model
responds with Server-Sent Events where the tool-call arguments arrive
in pieces across multiple chunks. Praxis buffers those pieces, waits
until the arguments are complete, calls the tool exactly once, then
calls the model again and returns the final answer as clean JSON.

**In plain terms:** Even when the AI streams its response in small
fragments, Praxis waits until it has the complete tool request before
acting. No partial data leaks through, and the tool only runs once.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"stream-model","input":"What is the weather in Boston?","stream":true,"tools":[{"type":"function","name":"get_weather"}]}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200 with a final JSON answer. Terminal 1 shows the
streaming mock sent SSE events on the first call and JSON on the second.
The tool mock shows one request with complete `{"city":"Boston"}`.

---

### 4. State Persistence

**User story:** As a developer, I want Praxis to remember what happened
in a conversation so I can continue it later. When I set `store:true`,
Praxis saves the full exchange — my input and the model's response — so
a follow-up request can pick up where it left off.

**In plain terms:** Praxis saves the conversation. You can come back
later and say "continue from where we left off" using a response ID.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"state-model","input":"Remember this demo context.","store":true}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200 with response `id: resp_mock_test_001`. Praxis
log shows `persisting response`.

---

### 5. Continue with previous_response_id

**User story:** As a developer, I reference a previous response by ID.
Praxis loads the saved conversation — including my original input and
the model's prior answer — prepends it before my new message, and sends
the full context to the model. The model sees the entire history.

**In plain terms:** You say "remember what we talked about" by passing
the old response's ID. Praxis replays the whole conversation so the
model has context.

```bash
curl -sS -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"state-model","input":"Use the previous context now.","previous_response_id":"resp_mock_test_001"}' \
  | python3 -m json.tool
```

**Expected:** HTTP 200. The state-model mock log (Terminal 1) shows
POST #2 with an input array containing the prior user message
("Remember this demo context."), the prior assistant response, and the
new input ("Use the previous context now.").

---

### 6. Missing previous_response_id — Fails Closed

**User story:** As a platform operator, I need Praxis to fail clearly
when a client references a response that doesn't exist. No model call
should happen, no side effects, just a clear error.

**In plain terms:** If you try to continue a conversation that was never
saved (or was deleted), Praxis tells you immediately instead of sending
garbage to the model.

```bash
curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -X POST http://127.0.0.1:18080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"state-model","input":"This should fail.","previous_response_id":"resp_missing"}'
```

**Expected:** HTTP 404 with `"previous response not found: resp_missing"`.
No new POST appears in the state-model mock log.

---

## What to Verify

| # | Scenario | Status | Terminal 1 evidence |
|---|----------|--------|---------------------|
| 1 | Agentic loop | 200 | loop-mock POST #1 + #2 (second has `function_call_output`), tool POST #1 |
| 2 | Unadvertised tool | 400 | loop-mock POST #3 only, no new tool POST |
| 3 | Streaming loop | 200 | streaming-mock POST #1 (SSE) + #2 (reinference), tool POST #2 |
| 4 | Store state | 200 | state-mock POST #1 |
| 5 | Replay state | 200 | state-mock POST #2 body has prior context + new input |
| 6 | Missing state | 404 | No new state-mock POST |

## One-Command Transcript

To generate a complete Markdown transcript automatically:

```bash
bash <repo>/epic-354/e2e/run-complete-e2e-demo.sh \
  <repo>/epic-354/e2e/complete-e2e-demo-output.md
```
