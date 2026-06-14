# Track B Sample Output

## Local Request Routing (8 assertions)

```console
$ bash scripts/local-request-routing/run-request-routing.sh

=== checking ports ===
all ports free

=== starting inference simulator (model=fd03-smoke-...) ===
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

=== all 8 FD03 full-duplex smoke checks passed ===
--- cleanup ---
all harness processes stopped
```

## KIND Deployment (5 assertions)

```console
$ bash scripts/kind-request-routing/run-request-routing.sh

=== preflight ===
tools: kind=kind v0.31.0, kubectl=Client Version: v1.34.3

=== building Praxis v2 image ===
=== building Go EPP image ===
=== building simulator image ===
all images present

=== creating KIND cluster llmd-track-b-v2 ===
=== loading images into KIND ===

=== deploying to namespace llmd-track-b-v2 ===
waiting for simulator...
deployment "simulator" successfully rolled out
waiting for Go EPP...
deployment "go-epp" successfully rolled out
waiting for Praxis...
deployment "praxis" successfully rolled out
all deployments ready

=== test 1: normal request routing ===
HTTP status: 200
PASS: correct model in response

=== test 2: repeated requests ===
  request 1: 200 OK
  request 2: 200 OK
  request 3: 200 OK
PASS: 3 repeated requests succeeded

=== test 3: EPP failure -> 503 -> recovery ===
HTTP status with EPP down: 503
PASS: EPP unavailable returns 503
HTTP status after recovery: 200
PASS: EPP failure and recovery

=== test 4: no unexpected h2 errors ===
PASS: no unexpected h2 errors

=== test 5: image identity ===
deployed image: praxis-track-b-v2:local
PASS: correct image deployed

=== all KIND request-routing checks passed ===
--- cleanup ---
cluster deleted
```

## Claim Boundary

These demo outputs prove the generic full-duplex request-routing lifecycle.
Complete response-body and response-trailer lifecycle support is deferred to
FD04. The request body preserves its JSON semantics and arrives once, but
the path may normalize JSON field order; byte-for-byte preservation is not
claimed.
