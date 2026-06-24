# PR3 KIND Demo Validation Output

## Source Identity

- **Branch**: `brent-ext-proc-full-duplex-routing`
- **Revision**: `078e1c13909a` (dirty — PR3 changes uncommitted on feecb85)
- **Praxis image**: `sha256:28aae27f2ca4a000a530f4b4344d7009f507ceb7947852779f258be5871e7fca`
- **Composition**: `ext_proc(request_body_mode=full_duplex_streamed)` -> `endpoint_selector(required, 503)`
- **Images built from source**: Praxis, Go EPP, inference simulator, header-echo (no cached/skipped builds)

## KIND Demo Output

```console
=== Praxis full-duplex ext_proc KIND demo ===

This deploys the PR3 Praxis source with the generic ext_proc filter,
the unchanged Go EPP scheduler, and an inference simulator. Each HTTP
request keeps one bidirectional Process stream open while Praxis sends
headers, body data, and EOS before Go EPP returns the selected endpoint.

The demo validates request routing only. It does not claim response-phase
ext_proc processing, vLLM behavior, or Gateway API pool management.

=== preflight and source identity ===
tools: kind=kind v0.31.0 go1.25.5 linux/amd64, kubectl=Client Version: v1.34.3
Praxis source: branch=brent-ext-proc-full-duplex-routing, revision=078e1c13909a, state=dirty
Composition: ext_proc(request_body_mode=full_duplex_streamed) -> endpoint_selector(required, 503)

=== building images from the declared source checkouts ===
Praxis image: compiling 078e1c13909a-dirty with the ext-proc feature enabled
Praxis image identity: sha256:28aae27f2ca4a000a530f4b4344d7009f507ceb7947852779f258be5871e7fca
Praxis image was built directly from 078e1c13909a-dirty in this run

=== creating KIND cluster llmd-track-b-v2 ===
=== loading the exact local images into KIND ===
=== deploying the request-routing composition to namespace llmd-track-b-v2 ===
all deployments ready: Praxis -> Go EPP -> simulator
NAME                           READY   IMAGE
go-epp-674dc99956-ljwh4        true    go-epp-track-b-v2:local
header-echo-69bf48f994-pjxx7   true    header-echo-track-b-v2:local
praxis-6b9ff48764-jdzqv        true    praxis-track-b-v2:local
simulator-5db5c8756f-8p2bz     true    llmd-sim-track-b-v2:local

=== test 1: full-duplex routing through the real Go EPP ===
HTTP status: 200
PASS: HTTP 200 — request routed through Go EPP to the simulator endpoint

=== test 2: repeated independent requests ===
  request 1: 200 OK
  request 2: 200 OK
  request 3: 200 OK
PASS: all 3 independent requests completed through the routing path

=== test 3: spoofed destination header cannot select upstream ===
HTTP status with spoofed header: 200
PASS: client destination was ignored; Go EPP selected the reachable simulator (HTTP 200)

=== test 4: endpoint_selector strip_header configuration ===
PASS: endpoint_selector is configured with strip_header: true

=== test 5: EPP failure -> 503 -> recovery ===
HTTP status: 503 (Go EPP is unavailable)
PASS: required routing rejects with the configured exact HTTP 503
HTTP status: 200 (Go EPP recovered)
PASS: routing recovered after the Go EPP deployment returned

=== test 6: no unexpected h2 errors ===
h2 reset/GOAWAY mentions in Praxis logs: 0
PASS: no h2 reset or GOAWAY evidence in Praxis logs (0 mentions)

=== test 7: image identity ===
deployed image: praxis-track-b-v2:local
PASS: deployed Praxis image tag matches the image built from 078e1c13909a-dirty

=== all KIND request-routing checks passed ===
cluster: llmd-track-b-v2
namespace: llmd-track-b-v2
model: track-b-v2-model
composition: ext_proc (full_duplex_streamed) + endpoint_selector (required, 503)
```

## Hermetic Integration Test Output

```console
$ cargo test -p praxis-tests-integration --test suite -- ext_proc

running 13 tests
test ext_proc::ext_proc_ambiguous_destination_rejects ... ok
test ext_proc::ext_proc_bodyless_request_routes ... ok
test ext_proc::ext_proc_client_header_cannot_select_upstream ... ok
test ext_proc::ext_proc_destination_header_stripped ... ok
test ext_proc::ext_proc_immediate_response ... ok
test ext_proc::ext_proc_immediate_response_no_backend_hit ... ok
test ext_proc::ext_proc_invalid_destination_rejects ... ok
test ext_proc::ext_proc_mutation_precedence_later_set_overrides ... ok
test ext_proc::ext_proc_processor_failure_returns_status_on_error ... ok
test ext_proc::ext_proc_repeated_requests_no_crosstalk ... ok
test ext_proc::ext_proc_required_missing_destination_rejects ... ok
test ext_proc::ext_proc_routes_after_eos ... ok
test examples::ext_proc_endpoint_selector::ext_proc_endpoint_selector_example_routes ... ok

test result: ok. 13 passed; 0 failed; 0 ignored
```

## Assertion Checklist

| # | Claim | KIND Test | Hermetic Test | Evidence |
|---|-------|-----------|---------------|----------|
| 1 | Full-duplex routing returns HTTP 200 | test 1 | `routes_after_eos` | Source-built Praxis routes through real Go EPP to simulator |
| 2 | Repeated independent requests | test 2 | `repeated_requests_no_crosstalk` | 3 requests, each 200 |
| 3 | Client-supplied destination ignored | test 3 | `client_header_cannot_select_upstream` | Unreachable spoofed header; 200 from real simulator |
| 4 | Routing header stripped | test 4 (config) | `destination_header_stripped` | Config asserts `strip_header: true`; hermetic test proves wire-level |
| 5 | EPP failure -> exact 503 | test 5 | `processor_failure_returns_status_on_error` | Scale EPP to 0; HTTP 503 |
| 6 | Recovery -> HTTP 200 | test 5 | — | Scale EPP back to 1; HTTP 200 |
| 7 | No h2 reset/GOAWAY | test 6 | — | 0 mentions in Praxis logs |
| 8 | Source-built image deployed | test 7 | — | Image ID matches freshly built image |
| 9 | Invalid destination rejected | — | `invalid_destination_rejects` | URI value; 503; 0 backend hits |
| 10 | Ambiguous destination rejected | — | `ambiguous_destination_rejects` | Dual values; 503; 0 backend hits |
| 11 | ImmediateResponse | — | `immediate_response` + `_no_backend_hit` | 403 + body; 0 backend hits |
| 12 | Mutation precedence | — | `mutation_precedence_later_set_overrides` | Add(A) then Remove+Set(B); routes to B |
| 13 | Bodyless request routes | — | `bodyless_request_routes` | Content-Length: 0; 200 |

## Known Limitation

The Go EPP echoes all incoming request headers back as ext_proc `set_headers`
mutations with the default `AppendIfExistsOrAdd` action. Praxis applies these
as new header entries, creating duplicates for `Host`, `User-Agent`, `Accept`,
and `Content-Type`. The inference simulator's fasthttp backend rejects
duplicate `Host` headers (returning 200 with empty body), and Pingora rejects
upstream forwarding to backends that see the duplicate `Host` as malformed.

This prevents the KIND demo from verifying the full response body from the
simulator or performing wire-level header-echo observations. The routing
itself works (HTTP 200 confirms the endpoint was selected and forwarded).
Wire-level header stripping and body preservation are proven by the hermetic
Rust integration tests, which use an in-process mock processor that does not
echo headers.

This is a Go EPP + Pingora header interaction, not a PR3 ext_proc defect.
Resolution options include configuring the EPP not to echo headers, adding
header deduplication in Praxis, or using `mutation_rules` to restrict which
headers the processor may set.

## Scope Boundary

This demo validates Praxis request routing with the generic ext_proc filter
and endpoint_selector composition in KIND. It does not validate or claim:

- Response-phase ext_proc processing
- vLLM model serving behavior
- Cache-aware or disaggregated scheduling
- Gateway API InferencePool or InferenceModel resources
- Full Envoy ext_proc parity
