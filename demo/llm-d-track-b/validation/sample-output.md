# PR3 KIND Demo Validation Output

## Source Identity

- **Branch**: `brent-ext-proc-full-duplex-routing`
- **Revision**: `078e1c13909a` (dirty — PR3 changes including Host mutation fix)
- **Praxis image**: `sha256:720f1750228b5b8958ddfd12209508c4d2312f388ccf9dd786d2828777712a25`
- **Built from source**: yes (no SKIP_BUILD)
- **Composition**: `ext_proc(request_body_mode=full_duplex_streamed)` -> `endpoint_selector(required, 503)`

## KIND Demo Output

All images built from declared source checkouts. Fresh dedicated KIND cluster.

```console
=== Praxis full-duplex ext_proc KIND demo ===

This deploys the PR3 Praxis source with the generic ext_proc filter,
the unchanged Go EPP scheduler, and an inference simulator. Each HTTP
request keeps one bidirectional Process stream open while Praxis sends
headers, body data, and EOS before Go EPP returns the selected endpoint.

The demo validates request routing only. It does not claim response-phase
ext_proc processing, vLLM behavior, or Gateway API pool management.

=== preflight and source identity ===
Praxis source: branch=brent-ext-proc-full-duplex-routing, revision=078e1c13909a, state=dirty
Composition: ext_proc(request_body_mode=full_duplex_streamed) -> endpoint_selector(required, 503)

=== building images from the declared source checkouts ===
Praxis image: compiling 078e1c13909a-dirty with the ext-proc feature enabled
Praxis image identity: sha256:720f1750228b5b8958ddfd12209508c4d2312f388ccf9dd786d2828777712a25
Praxis image was built directly from 078e1c13909a-dirty in this run

=== creating KIND cluster llmd-track-b-v2 ===
=== deploying the request-routing composition to namespace llmd-track-b-v2 ===
all deployments ready: Praxis -> Go EPP -> simulator
NAME                           READY   IMAGE
go-epp-674dc99956-fb9g8        true    go-epp-track-b-v2:local
header-echo-69bf48f994-twlhd   true    header-echo-track-b-v2:local
praxis-6b9ff48764-ngmqw        true    praxis-track-b-v2:local
simulator-5db5c8756f-5475f     true    llmd-sim-track-b-v2:local

=== test 1: full-duplex routing through the real Go EPP ===
HTTP status: 200
PASS: HTTP 200 and simulator response identifies model 'track-b-v2-model'

=== test 2: repeated independent requests ===
  request 1: 200 OK
  request 2: 200 OK
  request 3: 200 OK
PASS: all 3 independent requests completed through the routing path

=== test 3: spoofed destination header cannot select upstream ===
HTTP status with spoofed header: 200
PASS: client destination was ignored; simulator response identifies model 'track-b-v2-model'

=== test 4: backend header stripping and body integrity ===
Go EPP now selects the header-echo backend
HTTP status from header-echo backend: 200
PASS: x-gateway-destination-endpoint is absent from backend headers
PASS: backend received non-empty request body (sha256=5881c6b1e2c16389f49960a0977e816cb0ec553bc04d2772f7a1a687f90bb9bb)

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
validated: source provenance, routing, repeated requests, client-header distrust,
backend header stripping, non-empty forwarded body, EPP failure/recovery, h2 log hygiene
```

## Assertion Checklist

| # | Claim | KIND Test | Evidence |
|---|-------|-----------|----------|
| 1 | Full-duplex routing returns HTTP 200 with model name | test 1 | Simulator response contains `track-b-v2-model` |
| 2 | Repeated independent requests succeed | test 2 | 3 requests, each 200 |
| 3 | Client-supplied destination ignored | test 3 | Unreachable spoofed header; simulator response contains model |
| 4 | Destination header stripped at wire level | test 4 | Header-echo proves `x-gateway-destination-endpoint` absent |
| 5 | Non-empty body forwarded | test 4 | Header-echo body SHA-256 is non-empty (not the empty-input hash) |
| 6 | EPP failure returns exact 503 | test 5 | Scale EPP to 0; HTTP 503 |
| 7 | Recovery returns 200 | test 5 | Scale EPP back to 1; HTTP 200 |
| 8 | No h2 reset/GOAWAY | test 6 | 0 mentions in Praxis logs |
| 9 | Source-built image deployed | test 7 | Image ID matches freshly built image |

## Notes

- Test 4 proves destination-header stripping and non-empty body forwarding.
  It does not claim byte-for-byte JSON preservation: the Go EPP re-serializes
  JSON before forwarding, which changes key order.
- Remaining non-Host header duplicates (Accept, Content-Type, User-Agent) are
  caused by the Go EPP echoing headers with the default append action. They did
  not fail this demo, but their acceptability depends on the selected backend.
  The EPP should use `OverwriteIfExistsOrAdd` or avoid echoing headers it does
  not intend to mutate.

## Scope Boundary

Real Praxis + Go EPP + inference simulator request routing in KIND.
Not response-phase processing, vLLM serving, cache-aware scheduling,
Gateway API resources, or full Envoy ext_proc parity.
