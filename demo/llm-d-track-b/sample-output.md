# Track B Sample Output

## Local Smoke

```console
$ cd demo/llm-d-track-b
$ bash scripts/run-local-smoke.sh

=== checking ports ===
all ports free
=== building Praxis (ext-proc feature) ===
=== building Go EPP ===
=== checking inference simulator ===

=== starting inference simulator (model=smoke-1780721862-2001356) ===
waiting for sim (PID 2001374) on port 18080...
sim ready (2s)
=== starting Go EPP on gRPC port 9002 ===
waiting for epp (PID 2001394) on port 9002 (TCP)...
epp ready (2s)
=== starting Praxis on port 18091 ===
waiting for praxis (PID 2001413) on port 18091 (TCP)...
praxis ready (2s)

=== smoke: successful request (model=smoke-1780721862-2001356) ===
HTTP status: 200
Response (first 300 chars): {"id":"chatcmpl-...","model":"smoke-1780721862-2001356",...}
PASS: response contains correct model name
PASS: simulator process alive through request
PASS: EPP log contains model 'smoke-1780721862-2001356'
PASS: successful request path

=== smoke: oversized body (marker=oversize-smoke-1780721862-2001356) ===
HTTP status for oversized body: 413
PASS: oversized body returns 413
PASS: EPP log does not contain 'oversize-smoke-...' — no EPP call

=== smoke: EPP unavailable ===
HTTP status with EPP down: 503
PASS: EPP unavailable returns exactly 503

=== all smoke tests passed ===
```

## KIND Smoke

```console
$ bash scripts/run-kind-smoke.sh

=== preflight ===
required tools, cluster absent, port 30092 free

=== creating KIND cluster 'llmd-track-b' ===
Creating cluster "llmd-track-b" ...
 ✓ Ensuring node image
 ✓ Preparing nodes
 ✓ Writing configuration
 ✓ Starting control-plane
 ✓ Installing CNI
 ✓ Installing StorageClass

=== loading images into KIND ===
=== deploying namespace and simulator (model=kind-smoke-1780724944-2082009) ===
simulator endpoint: 10.96.83.220:8000
=== deploying Go EPP ===
=== deploying Praxis ===

=== pod status ===
NAME                         READY   STATUS    IP
go-epp-69f48c7c7-ct4xx       1/1     Running   10.244.0.6
praxis-679bb59fcc-qvqg2      1/1     Running   10.244.0.7
simulator-76d4988578-s26q2   1/1     Running   10.244.0.5

=== smoke: successful request (model=kind-smoke-1780724944-2082009) ===
HTTP status: 200
PASS: response contains unique model
PASS: EPP logs contain model
PASS: EPP logs contain simulator endpoint '10.96.83.220'

=== smoke: EPP down (scale to 0) ===
HTTP status with EPP down: 503
PASS: EPP down returns exactly 503

=== smoke: recovery after EPP restart ===
new EPP pod: go-epp-69f48c7c7-p8ftn
HTTP status after recovery: 200
PASS: recovery response contains model
PASS: restarted EPP pod processed recovery request
PASS: restarted EPP selected simulator endpoint

=== all KIND smoke tests passed ===
```
