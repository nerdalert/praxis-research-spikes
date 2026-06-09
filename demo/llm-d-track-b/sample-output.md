# Track B Sample Output

## 01 - Praxis-to-Go-EPP Request Path

```console
$ TRACK_B_DIR=<track-b-checkout> bash scripts/run-01-request-path.sh

=== checking ports ===
all ports free

=== starting inference simulator (model=track-b-demo-1780721862-2001356) ===
sim ready (2s)

=== starting Go EPP on gRPC port 9002 ===
epp ready (2s)

=== starting Praxis on port 18091 ===
praxis ready (2s)

=== request path: successful request (model=track-b-demo-1780721862-2001356) ===
HTTP status: 200
Response: {"id":"chatcmpl-...","model":"track-b-demo-1780721862-2001356",
           "object":"chat.completion",...}
PASS: response contains correct model name
PASS: simulator process alive through request
PASS: EPP log contains model 'track-b-demo-1780721862-2001356'
PASS: successful request path

=== failure behavior: oversized body (marker=oversize-track-b-demo-1780721862-2001356) ===
HTTP status for oversized body: 413
PASS: oversized body returns 413
PASS: EPP log does not contain 'oversize-track-b-demo-...' — no EPP call

=== failure behavior: EPP unavailable ===
HTTP status with EPP down: 503
PASS: EPP unavailable returns exactly 503

=== all request-path tests passed ===
--- cleanup ---
all harness processes stopped
```

**What this proves:**
- Praxis called the real Go EPP and received the selected endpoint
- The request body reached the simulator without framing errors
- Oversized bodies are rejected before calling the EPP (413)
- EPP unavailability returns the configured `status_on_error` (503)

## 03 - Kubernetes Go EPP Load-Aware Routing

```console
$ bash scripts/03-kubernetes-go-epp-load-aware-routing/run-kubernetes-load-aware.sh

[track-b] 03 - Kubernetes Go EPP Load-Aware Routing
[track-b] Two backends serve the same model with asymmetric load:
[track-b]   sim-a: idle  (kv-cache 10%, 0 running, 0 waiting)
[track-b]   sim-b: busy  (kv-cache 90%, 8 running, 3 waiting)

[track-b] Preflight
[track-b] preflight OK

[track-b] Building container images
[track-b] images built

[track-b] Creating KIND cluster 'llmd-track-b'
[track-b] cluster ready

[track-b] Deploying simulators (sim-a=idle, sim-b=busy)
[track-b] sim-a ClusterIP: 10.96.X.X (idle:  kv=10%, running=0, waiting=0)
[track-b] sim-b ClusterIP: 10.96.Y.Y (busy: kv=90%, running=8, waiting=3)

[track-b] Deploying Go EPP (kv-cache scorer + max-score picker)
[track-b] waiting for EPP to scrape endpoint metrics ...

[track-b] Deploying Praxis

[track-b] Pod status
NAME                      READY   STATUS    IP
go-epp-...                True    Running   10.244.0.6
praxis-...                True    Running   10.244.0.7
sim-a-...                 True    Running   10.244.0.4
sim-b-...                 True    Running   10.244.0.5

[track-b] Verifying simulator fake-metrics
[track-b] sim-a kv_cache_usage_perc: 0.1
[track-b] sim-b kv_cache_usage_perc: 0.9

[track-b] Sending requests through Praxis -> Go EPP -> backend
[track-b]   ✓ all 10 requests returned HTTP 200

[track-b] Verifying Go EPP endpoint selection
[track-b]   ✓ EPP logs contain model 'track-b-load-aware'
[track-b]   ✓ EPP logs contain sim-a endpoint '10.96.X.X' (idle)
[track-b] EPP endpoint selection log:
[track-b]   ... "Running scorer plugin" ... "plugin":"kv-scorer/kv-cache-utilization-scorer"
[track-b]   ... "Running picker plugin" ... "plugin":"best-picker/max-score-picker"
[track-b]   ... "Request handled" ... "endpoint":"10.96.X.X:8000"
[track-b] EPP selected sim-a (10.96.X.X) 10 times (idle, kv=10%)
[track-b] EPP selected sim-b (10.96.Y.Y) 0 times (busy, kv=90%)
[track-b]   ✓ Go EPP preferred the idle backend (sim-a: 10, sim-b: 0)

[track-b] What this demo proved:
[track-b]   - Go EPP scraped Prometheus /metrics from both backends
[track-b]   - sim-a reports kv-cache 10% (idle), sim-b reports 90% (busy)
[track-b]   - Go EPP's kv-cache-utilization-scorer preferred the idle endpoint
[track-b]   - Praxis called Go EPP and applied the selected endpoint via ctx.upstream
[track-b]   - No Envoy in the request path

[track-b] 03 complete
```

**What this proves:**
- Go EPP scrapes real Prometheus metrics from both backends
- The `kv-cache-utilization-scorer` scores `1 - kv_usage`: sim-a (0.9) vs sim-b (0.1)
- `max-score-picker` selects the highest-scoring (idle) endpoint
- Praxis calls Go EPP and applies the selected endpoint — no Envoy in the path
- Claim boundary: Go EPP performs load-aware selection; Praxis carries the decision
