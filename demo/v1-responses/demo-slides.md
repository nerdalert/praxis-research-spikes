# Epic 354: Responses API Agentic Loop — Demo Slides

---

## Slide 1: What We Built

**Praxis-owned Responses API orchestration**

- Client sends one `/v1/responses` request.
- Praxis manages the full model/tool loop internally.
- Model calls tools → Praxis executes tools → feeds results back → repeats until done.
- Client receives one complete response.

**Status:** E2E validation complete. 62 integration tests, 36 unit tests.
Not yet merged upstream — this is the proving ground for stacked PRs.

---

## Slide 2: Architecture

```
Client
  → POST /v1/responses
      → Praxis (responses_orchestrator)
          ┌─────────────────────────────────┐
          │  1. Call model backend           │
          │  2. Parse response               │
          │  3. If function_call detected:   │
          │     a. Validate tool (advertised  │
          │        in request + configured)   │
          │     b. Execute tool via HTTP      │
          │     c. Check guardrails           │
          │     d. Inject function_call_output│
          │     e. Call model again           │
          │  4. If final response:            │
          │     a. Persist state if store:true│
          │     b. Return to client           │
          └─────────────────────────────────┘
      ← Final Responses API JSON
```

**Key decision:** Terminal request-phase filter, not response-phase
branch-chain re-entry. The orchestrator owns the loop and returns a
local response. The normal upstream proxy path is never used.

---

## Slide 3: Non-Streaming Agentic Loop

**Scenario:** "What is the weather in Boston?"

1. Client sends request with `tools: [get_weather]`.
2. Model mock returns `function_call(get_weather, {"city":"Boston"})`.
3. Praxis calls tool mock → gets `{"weather":"sunny, 72F"}`.
4. Praxis injects `function_call_output` with matching `call_id`.
5. Model mock sees full context → returns "It is sunny and 72F in Boston."
6. Client gets one final answer.

**Model called:** 2 times. **Tool called:** 1 time. **Client calls:** 1.

---

## Slide 4: Request-Scoped Tool Authorization

**Scenario:** Same model, but client does not advertise any tools.

- Model still tries to call `get_weather`.
- Praxis rejects: *"tool 'get_weather' not advertised in request."*
- Tool backend never contacted.

**Why it matters:** Just because a tool exists in Praxis config does
not mean every request should use it. The client must explicitly opt
in. This prevents the model from executing tools the application
did not intend.

---

## Slide 5: Buffered Streaming

**Scenario:** Model responds with Server-Sent Events (SSE).

- Function call arguments arrive in pieces: `{"cit` → `y":"Bos` → `ton"}`.
- Praxis buffers partial chunks until `arguments.done` event.
- Tool executes once with complete `{"city":"Boston"}`.
- Second model call returns final text.
- Client receives synthesized JSON (not raw SSE).

**What it proves:** No partial arguments leak. No duplicate tool calls.
Streaming model backends work with the same orchestration loop.

---

## Slide 6: Conversation State

**Scenario:** Multi-turn conversation via `previous_response_id`.

1. First request: `"Remember this demo context."` → stored with `id: resp_001`.
2. Second request: `previous_response_id: "resp_001"` + `"Use the previous context."`
3. Praxis loads stored transcript, prepends prior user input + model output.
4. Model sees full conversation history.

**Also validated:**
- `store: false` → not persisted.
- Missing `previous_response_id` → 404, no backend call.
- `conversation` ID → latest response auto-resolved.

---

## Slide 7: Safety Boundaries

| Boundary | Behavior |
|----------|----------|
| Unknown tool | 400 error, no tool execution |
| Unadvertised tool | 400 error, no tool execution |
| Max iterations | Responses-shaped `incomplete` response |
| Tool output guardrail | Blocked content not reinjected into model |
| Missing previous_response_id | 404, no backend call |
| Incomplete SSE function call | 502, no tool execution |
| Tool backend non-2xx | 502, loop stops |

---

## Slide 8: Takeaways

1. **The orchestrator architecture works.** Terminal request-phase filter
   with internal HTTP subrequests is the right pattern for Praxis.

2. **Request-scoped tool policy is load-bearing.** Without it, the model
   can execute tools the client never intended.

3. **SSE buffering is viable.** Streaming responses can be buffered and
   parsed for tool calls without live pass-through (yet).

4. **State persistence works for the simple case.** Full transcript
   storage enables `previous_response_id` continuations. External
   backends and tenant scoping are next.

5. **Next steps:** Split the validation branch into stacked upstream PRs.
   First blocker: isolate `reqwest` behind a `SubRequestClient` trait
   to resolve the TLS crypto provider conflict.
