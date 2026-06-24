# PR3 Integration Validation

Reviewer-facing validation evidence for the generic `ext_proc` +
`endpoint_selector` full-duplex request-routing integration.

This covers the hermetic Rust integration-test PR. The environment-backed
phase (vLLM, Go EPP, scheduler) is tracked separately under issue #295.

## Tested Checkout

- **Branch**: `test-ext-proc-full-duplex-routing-integration`
- **Base commit**: `feecb85` (upstream/main with PR1+PR2 merged, PR3 code as uncommitted changes)

## What Is Proved

The integration tests exercise the real Praxis proxy pipeline end-to-end:

```text
HTTP client -> Praxis listener -> StreamBuffer pre-read -> ext_proc Process stream
  -> processor response with trusted endpoint mutation -> endpoint_selector
  -> selected HTTP backend -> response to client
```

All tests use:
- Dynamically allocated ports (no fixed ports)
- In-process tonic `ExternalProcessor` mock (no Go EPP, no Docker)
- RAII shutdown guards (no leaked threads or ports)
- The documented `ext-proc-endpoint-selector.yaml` example config patched at runtime

## Assertion Checklist

Each claim maps to a specific integration test.

| Claim | Test | Assertion |
|-------|------|-----------|
| POST routes only after body EOS | `ext_proc_routes_after_eos` | Mock waits for EOS; backend echoes original body; HTTP 200 |
| Internal destination header stripped | `ext_proc_destination_header_stripped` | Header-echo backend body does not contain `x-gateway-destination-endpoint` |
| Client-supplied destination cannot select upstream | `ext_proc_client_header_cannot_select_upstream` | Client sets evil destination; processor routes to legit backend; response proves legit backend |
| Required missing destination rejects | `ext_proc_required_missing_destination_rejects` | Processor omits destination; HTTP 503 |
| Invalid destination rejects | `ext_proc_invalid_destination_rejects` | Client spoofs a reachable recording backend; processor returns `http://not-a-valid-authority:999/path`; HTTP 503; zero recording-backend requests |
| Ambiguous destination rejects | `ext_proc_ambiguous_destination_rejects` | Client spoofs a reachable recording backend; processor sets two distinct `x-gateway-destination-endpoint` values; HTTP 503; zero recording-backend requests |
| Processor failure uses status_on_error | `ext_proc_processor_failure_returns_status_on_error` | No processor running; HTTP 503 |
| ImmediateResponse reaches client | `ext_proc_immediate_response` | Processor sends 403 + body; client receives both |
| ImmediateResponse does not hit backend | `ext_proc_immediate_response_no_backend_hit` | Client spoofs a reachable recording backend; processor returns 403; recording backend count is zero |
| Bodyless request routes | `ext_proc_bodyless_request_routes` | Content-Length: 0 POST; mock sees terminal body EOS; backend responds |
| No crosstalk across requests | `ext_proc_repeated_requests_no_crosstalk` | 3 distinct markers; each echoed correctly; exactly 3 new Process streams |
| Ordered mutation precedence | `ext_proc_mutation_precedence_later_set_overrides` | Headers response Add(A), body response Remove+Set(B); final value B determines routing |
| Example config functional | `ext_proc_endpoint_selector_example_routes` | Uses `load_example_config`; POST body echoed through real pipeline |

## Output

See [sample-output.md](sample-output.md) for exact test and validation output.

## Track B Local/KIND Demo

Not run. The local KIND demo requires Go EPP, vLLM pods, and GPU/CPU model
serving infrastructure that is not available in this environment. The demo
scripts at `demo/llm-d-track-b/` are manual validation artifacts from the
earlier research spike. The hermetic integration tests above prove the same
request-routing behavior without those external dependencies.
