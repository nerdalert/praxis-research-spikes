# PR3 Integration Validation Output

## Branch and Commit

- **Branch**: `test-ext-proc-full-duplex-routing-integration`
- **Base commit**: `feecb85 refactor(filter): extract shared JSON-RPC parser`

## Focused Integration Test Output

```console
$ cargo test -p praxis-tests-integration --test suite -- ext_proc

running 13 tests
test ext_proc::ext_proc_invalid_destination_rejects ... ok
test ext_proc::ext_proc_immediate_response ... ok
test examples::ext_proc_endpoint_selector::ext_proc_endpoint_selector_example_routes ... ok
test ext_proc::ext_proc_destination_header_stripped ... ok
test ext_proc::ext_proc_immediate_response_no_backend_hit ... ok
test ext_proc::ext_proc_ambiguous_destination_rejects ... ok
test ext_proc::ext_proc_processor_failure_returns_status_on_error ... ok
test ext_proc::ext_proc_mutation_precedence_later_set_overrides ... ok
test ext_proc::ext_proc_required_missing_destination_rejects ... ok
test ext_proc::ext_proc_routes_after_eos ... ok
test ext_proc::ext_proc_repeated_requests_no_crosstalk ... ok
test ext_proc::ext_proc_bodyless_request_routes ... ok
test ext_proc::ext_proc_client_header_cannot_select_upstream ... ok

test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 598 filtered out
```

## Validation Summary

```
make lint                                                    PASS
  clippy --workspace --all-targets -- -D warnings            PASS
  +nightly fmt --all -- --check                              PASS
  cargo machete                                              PASS
  xtask lint-deps                                            PASS
  xtask lint-example-tests    65 configs, 32 skipped         PASS
  xtask sync-example-readme                                  up to date
  xtask lint-filter-docs                                     up to date

make test-integration         609 passed, 0 failed           PASS

make test-unit
  core                        461 passed                     PASS
  schema                       93 passed                     PASS
  filter                     2143 passed                     PASS
  protocol                    367 passed                     PASS
  server                       43 passed                     PASS

cargo doc --workspace --no-deps --document-private-items     PASS
git diff --check                                             PASS
```

## Track B Local/KIND Demo Output

**Not run.** The local KIND demo at `demo/llm-d-track-b/` requires:
- Go EPP binary (`llm-d` inference gateway)
- vLLM model-serving pods with GPU or CPU test profile
- Kubernetes cluster (KIND or remote)
- Scheduler and `InferencePool` CRD resources

These dependencies are not available in this development environment. The
hermetic Rust integration tests prove the identical request-routing behavior
(deferred EOS routing, SSRF prevention, header stripping, failure modes,
mutation precedence) without external infrastructure.

## Assertion Checklist

| # | Claim | Proving Test | Evidence |
|---|-------|-------------|----------|
| 1 | POST routes only after EOS | `ext_proc_routes_after_eos` | Mock waits for EOS; backend echoes body; 200 |
| 2 | Destination header stripped | `ext_proc_destination_header_stripped` | Header-echo backend body lacks `x-gateway-destination-endpoint` |
| 3 | Client SSRF prevented | `ext_proc_client_header_cannot_select_upstream` | Evil header ignored; legit backend response |
| 4 | Missing destination rejected | `ext_proc_required_missing_destination_rejects` | Processor omits destination; 503 |
| 5 | Invalid destination rejected | `ext_proc_invalid_destination_rejects` | Client spoofs reachable backend; URI value rejected; 503; recording backend count == 0 |
| 6 | Ambiguous destination rejected | `ext_proc_ambiguous_destination_rejects` | Client spoofs reachable backend; dual distinct values; 503; recording backend count == 0 |
| 7 | Processor failure uses status_on_error | `ext_proc_processor_failure_returns_status_on_error` | No processor; 503 |
| 8 | ImmediateResponse reaches client | `ext_proc_immediate_response` | 403 + body from processor |
| 9 | ImmediateResponse skips backend | `ext_proc_immediate_response_no_backend_hit` | Client spoofs reachable backend; processor returns 403; recording backend count == 0 |
| 10 | Bodyless request routes | `ext_proc_bodyless_request_routes` | Content-Length: 0; routes; 200 |
| 11 | No crosstalk | `ext_proc_repeated_requests_no_crosstalk` | 3 markers; 3 streams; each echoed |
| 12 | Mutation precedence | `ext_proc_mutation_precedence_later_set_overrides` | Headers response Add(A), body response Remove+Set(B); routes to B |
| 13 | Example config functional | `ext_proc_endpoint_selector_example_routes` | `load_example_config`; end-to-end |
