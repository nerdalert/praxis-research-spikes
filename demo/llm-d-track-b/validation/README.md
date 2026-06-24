# PR3 Integration Validation

Reviewer-facing validation evidence for the generic `ext_proc` +
`endpoint_selector` full-duplex request-routing integration.

## KIND Demo

Builds Praxis from the declared PR3 source, deploys it in a fresh
dedicated KIND cluster alongside the real Go EPP and inference simulator,
and runs 7 assertion tests:

```bash
PRAXIS_DIR=<pr3-checkout> \
bash demo/llm-d-track-b/scripts/kind-request-routing/run-request-routing.sh
```

| # | Test | Result |
|---|------|--------|
| 1 | Full-duplex routing (HTTP 200, simulator identifies model) | PASS |
| 2 | 3 repeated independent requests (each 200) | PASS |
| 3 | Spoofed unreachable destination ignored (simulator identifies model) | PASS |
| 4 | Header-echo: destination header absent, non-empty body forwarded | PASS |
| 5 | EPP down -> exact 503; recovery -> 200 | PASS |
| 6 | No h2 reset/GOAWAY in Praxis logs | PASS |
| 7 | Deployed image matches source-built Praxis image | PASS |

Test 4 switches the real Go EPP to a header-echo observation backend that
returns received headers and a body SHA-256. It proves the internal
`x-gateway-destination-endpoint` header is stripped and a non-empty body
reaches the backend. It does not claim byte-for-byte JSON preservation
because the Go EPP re-serializes JSON before forwarding.

Source identity, Docker image ID, and Kubernetes pod status are printed
in every run.

## Scope Boundary

Real Praxis + Go EPP + inference simulator request routing in KIND.
Not response-phase processing, vLLM serving, cache-aware scheduling,
Gateway API resources, or full Envoy ext_proc parity.

## Output

See [sample-output.md](sample-output.md) for the captured results from
the source-built KIND demo run.
