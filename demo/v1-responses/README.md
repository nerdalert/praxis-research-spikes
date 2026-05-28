# Responses API Agentic Loop — Praxis PoC Demo

## What This Demo Proves

This demo validates the Praxis-owned Responses API agentic orchestration
loop from Epic #354. It shows Praxis acting as the orchestration engine
between the client and the model: when the model says "I need to call a
tool," Praxis executes the tool, feeds the result back, and continues
until the model produces a final answer.

The client sends one request. Praxis handles the entire model/tool loop
internally and returns the complete response.

The actual production architecture is still being firmed up. This demo
exists to prove what can be achieved with Praxis and to surface any
major blockers early — before committing to a final design.

## Why /v1/responses Matters

The OpenAI Responses API is the successor to Chat Completions. It was
designed for agentic workflows: built-in tools (web search, file search,
code interpreter), stateful conversations (the server remembers context
across requests), and a re-entrant loop (the model calls tools, gets
results, and keeps going until it has a final response).

For platform operators, owning this loop at the proxy layer means:

- Apply guardrails before and after every inference call.
- Route different tool calls to different backends.
- Rate-limit per tenant across the entire loop.
- Audit every step.
- Enforce cost budgets.
- All configurable via filter chains.

## What Praxis Owns

In this PoC, Praxis owns:

- **Model backend selection**: resolve model name to endpoint via config.
- **Inference subrequests**: POST the client body to the model backend.
- **Function call detection**: parse JSON and SSE responses for `function_call` items.
- **Tool execution**: call local HTTP tool backends with parsed arguments.
- **Reinference**: inject `function_call_output` items and call the model again.
- **Loop control**: max iterations, timeout, fail-closed on unknown tools.
- **Guardrails**: block tool output containing restricted content before reinference.
- **State**: persist completed responses, load prior context via `previous_response_id` and `conversation`.
- **Streaming**: buffer SSE argument deltas, assemble complete arguments, synthesize JSON final response.

## Two Modes

### Stateless Pass-Through

Praxis detects the Responses request format, routes it to the model
backend, and forwards the body byte-for-byte. The backend handles
everything. This is for deployments where the inference backend natively
supports the Responses API.

### Praxis-Owned Agentic Orchestration (This Demo)

Praxis owns the loop. The `responses_orchestrator` terminal filter
buffers the request body, calls the model backend, detects tool calls,
executes tools, reinjects results, and loops. The client receives a
single final response. The normal upstream proxy path is never entered.

## Why a Terminal Orchestrator

Praxis branch re-entry is request-phase only. It cannot currently inspect
a normal upstream model response and then re-enter inference.
Response-body hooks are synchronous and cannot currently perform async
tool/model subrequests.

The example `responses_orchestrator` solves both constraints: it runs in the
request-body phase, performs inference and tool calls as async HTTP
subrequests, and returns a local response via `FilterAction::Reject`
with status 200. This follows the existing `static_response` convention.

## Architecture

```
Client
  → POST /v1/responses
      → Praxis (responses_orchestrator)
          → Model subrequest (POST /v1/responses to backend)
          ← Model response (function_call or final)
          → [If function_call]:
              → Tool subrequest (POST /tool to tool backend)
              ← Tool result
              → Build reinference body with function_call_output
              → Model subrequest again
              ← Final response
          → [If final]:
              → Persist state if store:true
      ← Final Responses API JSON response
```

## Implementation Source

The implementation lives on the `brent-responses-api-e2e-not-for-merge`
branch of the Praxis repo:

```
https://github.com/nerdalert/praxis.git  (branch: brent-responses-api-e2e-not-for-merge)
```

This is not merged upstream. It is the validation branch used to prove
the implementation plan before splitting into stacked PRs.

## Mock Backends

This demo uses mock model and tool backends. It validates the
orchestration shape before integrating real model providers, MCP tools,
durable state, search, files, or vector stores.

| Mock | Script | Purpose |
|------|--------|---------|
| Loop model | `responses-loop-mock.py` | Returns `function_call` on first request, final text on second |
| Streaming model | `responses-streaming-loop-mock.py` | Returns SSE with split argument deltas on first request |
| State model | `responses-state-mock.py` | Returns deterministic response IDs for state tests |
| Weather tool | `tool-http-mock.py` | Returns mock weather data for `get_weather` calls |

## Quick Start

See [deploy.md](deploy.md) for copy/paste instructions.

See [demo-slides.md](demo-slides.md) for a slide-ready walkthrough.

See [sample-output.md](sample-output.md) for a pre-generated transcript.
