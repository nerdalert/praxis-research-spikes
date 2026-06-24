# Track B Sample Output

## Local Request Routing (8 assertions)

```console
$ bash scripts/local-request-routing/run-request-routing.sh

=== checking ports ===
all ports free
=== building Praxis (ext-proc feature) ===
=== building Go EPP ===
=== Praxis runtime config ===
(ext_proc full_duplex_streamed -> endpoint_selector required 503)

=== starting inference simulator ===
sim ready (2s)
=== starting Go EPP on gRPC port 9102 ===
epp ready (2s)
=== starting Praxis on port 18191 ===
praxis ready (2s)

=== test 1: successful request path ===
HTTP status: 200
PASS: correct model in response — EPP selected the right backend

=== test 2: malicious client destination ignored ===
HTTP status with malicious header: 200
PASS: malicious header ignored — response from correct backend

=== test 3: repeated requests ===
  request 1: 200 OK
  request 2: 200 OK
  request 3: 200 OK
PASS: 3 repeated requests succeeded

=== test 4: EPP unavailable -> exact 503 ===
HTTP status with EPP down: 503
PASS: EPP unavailable returns exactly 503

=== test 5: EPP restart recovery ===
HTTP status after EPP restart: 200
PASS: EPP restart recovery — requests succeed after restart

=== test 6: destination header stripped at backend wire boundary ===
PASS: internal destination header absent from simulator logs

=== test 7: one Process invocation per HTTP request ===
Process invocations for one request: 1
PASS: exactly one Process invocation per HTTP request

=== test 8: request body preserved ===
PASS: request body semantic content observed exactly once at backend

=== all 8 full-duplex smoke checks passed ===
composition: ext_proc (full_duplex_streamed) + endpoint_selector (required, 503)
--- cleanup ---
all harness processes stopped
```

## KIND Deployment (7 assertions)

```console
$ bash scripts/kind-request-routing/run-request-routing.sh

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
PASS: backend received non-empty request body (sha256=5881c6b1...)

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
--- cleanup ---
cluster deleted
```

## Scope Boundary

These outputs prove the generic full-duplex request-routing lifecycle:
real Praxis + Go EPP + inference simulator. Response-phase ext_proc
processing, vLLM serving, cache-aware scheduling, and Gateway API
pool management are not validated here.

The Go EPP re-serializes JSON before forwarding, so request body
key order may change. Body integrity is verified by non-empty SHA-256,
not byte-for-byte preservation.
