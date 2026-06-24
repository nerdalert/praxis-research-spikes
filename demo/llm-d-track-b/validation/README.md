# PR3 Integration Validation

Reviewer-facing validation evidence for the generic `ext_proc` +
`endpoint_selector` full-duplex request-routing integration.

## KIND Demo

Builds Praxis from the declared PR3 source, deploys it in a fresh
dedicated KIND cluster alongside the real Go EPP and inference simulator,
and runs 7 assertion tests from a single command:

```bash
PRAXIS_DIR=<pr3-checkout> \
bash demo/llm-d-track-b/scripts/kind-request-routing/run-request-routing.sh
```

| # | Test | Result |
|---|------|--------|
| 1 | Full-duplex routing through real Go EPP (HTTP 200) | PASS |
| 2 | 3 repeated independent requests (each 200) | PASS |
| 3 | Client-supplied unreachable destination ignored (200 from simulator) | PASS |
| 4 | endpoint_selector configured with `strip_header: true` | PASS |
| 5 | EPP scaled to 0 returns exact 503; recovery returns 200 | PASS |
| 6 | No h2 reset or GOAWAY evidence in Praxis logs | PASS |
| 7 | Deployed image matches source-built Praxis image | PASS |

Source identity, Docker image ID, and Kubernetes pod status are printed
in every run for traceability.

## Hermetic Rust Integration Tests

13 tests in `tests/integration/tests/suite/ext_proc.rs` run in standard
CI without Docker, KIND, or the Go EPP. They use an in-process tonic
`ExternalProcessor` mock and prove wire-level behaviors that the KIND demo
cannot observe (header-echo stripping, body digest, ImmediateResponse
backend isolation, mutation precedence, ambiguous/invalid destination
rejection).

## Known Limitation

The Go EPP echoes all request headers back as ext_proc mutations, creating
duplicate `Host` headers. The simulator's fasthttp rejects duplicates and
returns 200 with empty body. Wire-level response-body and header-echo
observations require either configuring the EPP not to echo headers or
adding header deduplication. This is a Go EPP + Pingora interaction, not
a PR3 defect.

## Scope Boundary

This demo validates Praxis request routing with the generic ext_proc
filter and endpoint_selector in KIND. It does not validate response-phase
processing, vLLM serving, cache-aware scheduling, Gateway API resources,
or full Envoy ext_proc parity.

## Output

See [sample-output.md](sample-output.md) for exact captured output from
the source-built KIND demo run.
