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

## Track B KIND Demo Output

Run from a fresh KIND cluster using the real Go EPP and inference simulator:

```
bash demo/llm-d-track-b/scripts/kind-request-routing/run-request-routing.sh
```

```console
=== preflight ===
tools: kind=kind v0.31.0 go1.25.5 linux/amd64, kubectl=Client Version: v1.34.3

=== building Praxis v2 image ===  (SKIP_BUILD=1 used cached image)
=== building Go EPP image ===     (SKIP_BUILD=1 used cached image)
=== building simulator image ===  (SKIP_BUILD=1 used cached image)
all images present

=== creating KIND cluster llmd-track-b-v2 ===
=== loading images into KIND ===
=== deploying to namespace llmd-track-b-v2 ===
namespace/llmd-track-b-v2 created
deployment "simulator" successfully rolled out
deployment "go-epp" successfully rolled out
deployment "praxis" successfully rolled out
all deployments ready

=== test 1: normal request routing (model=track-b-v2-model) ===
HTTP status: 200
PASS: request routed through EPP to simulator (HTTP 200)

=== test 2: repeated requests ===
  request 1: 200 OK
  request 2: 200 OK
  request 3: 200 OK
PASS: 3 repeated requests succeeded

=== test 3: spoofed destination header cannot select upstream ===
HTTP status with spoofed header: 200
PASS: spoofed client destination header ignored, real EPP routing succeeded

=== test 4: backend header stripping ===
PASS: no evidence of destination header forwarded to backend

=== test 5: EPP failure -> 503 -> recovery ===
HTTP status with EPP down: 503
PASS: EPP unavailable returns 503
waiting for EPP recovery...
deployment "go-epp" successfully rolled out
HTTP status after recovery: 200
PASS: EPP failure and recovery

=== test 6: no unexpected h2 errors ===
h2 reset/GOAWAY mentions in Praxis logs: 0
PASS: no unexpected h2 errors (0 mentions)

=== test 7: image identity ===
deployed image: praxis-track-b-v2:local
PASS: correct image deployed

=== all KIND request-routing checks passed ===
cluster: llmd-track-b-v2
namespace: llmd-track-b-v2
model: track-b-v2-model
composition: ext_proc (full_duplex_streamed) + endpoint_selector (required, 503)
```

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
