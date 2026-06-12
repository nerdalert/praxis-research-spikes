# Demo Outline

## 1. Problem

Codex-style clients send native `/v1/responses` requests using client-facing
model names. A backend behind Praxis may require a different local deployment
name.

## 2. Existing Upstream Capability

- `openai_responses_format` recognizes and classifies the request.
- The router and load balancer can forward it to a native Responses backend.
- `openai_responses_validate` and `openai_response_store` support the broader
  full-flow pipeline.

Upstream classification does not rewrite the top-level request-body model.

## 3. PR 1 Capability

`openai_responses_model_rewrite` changes only the top-level `model` when an
alias or default applies. It preserves input, tools, function outputs, streaming
flags, and unknown fields.

## 4. Live Smoke Walkthrough

Run:

```bash
./run-complete-e2e-demo.sh
```

Show:

1. Native model request passes through unchanged.
2. `codex-mini-latest` reaches the backend as `llama-3.3-70b`.
3. Missing model receives the configured default.
4. Direct and proxied SSE bytes match.
5. Tool definitions are preserved without Praxis executing them.
6. `function_call_output` follow-up is preserved.
7. Chat Completions traffic still routes separately.

## 5. Benchmark Walkthrough

Compare:

```text
direct backend
format + route
format + rewrite no-op + route
format + rewrite alias + route
format + validate + response store + route
```

Show raw JSON artifacts first, then the generated median summary. Emphasize
that these are mock-backend request-path measurements.

## 6. Conclusion

Praxis can transparently adapt Codex-facing model names to backend deployment
names while preserving the native Responses protocol and the client-owned tool
loop.

