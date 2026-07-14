# Demo 2 — API Provider Fallback

## Overview

The Grid operator can route a model request to an external API-provider backend
when the self-hosted provider does not serve the requested model.  The consumer
gateway selects the API-provider candidate from the operator-generated overlay
and **injects the provider credential transparently** — the client only specifies
the model name and a consumer-level token.

The demo uses an in-cluster OpenAI-compatible mock server as the API-provider
target so no external API keys or internet connectivity are required.

## What Is Proved (9 assertions)

| Assertion | Evidence |
|-----------|----------|
| API-provider candidate appears in overlay | `[OK] api_provider candidate: model="model-z" cluster="op-e2e-api-fallback" fresh=true` |
| API-provider sorts after local (scoring) | `[OK] overlay scoring order: local=site-a (pos 0) before api=op-e2e-api-fallback (pos 1)` |
| Local model routes to local provider gateway | `[PASS] model model-x (from site-a) returns 200` |
| API-fallback model routes to mock API-provider | `[PASS] model model-z (from api-provider mock) returns 200` |
| Mock requires credential — negative proof | `[PASS] direct request without Authorization returns 401` |
| Gateway injects credential — positive proof | `[PASS] gateway request without client Authorization returns 200 (gateway injected Bearer "grid-api-fallback-secret")` |
| Injected credential produces valid response | `[PASS] api-provider response is valid Chat Completions JSON` |
| Client did not supply provider API key | Client request carries no `Authorization` header; gateway injects one |
| Unknown model fails cleanly | `[PASS] unknown model fails cleanly via consumer gateway` |

## Architecture

```
Client
  → POST /v1/chat/completions {"model": "model-z"}
  → (NO Authorization header from client)

Consumer Praxis Gateway (kind-grid-consumer)
  → json_body_field: extracts model → X-Model: model-z
  → grid_route: selects cluster gateway-op-e2e-api-fallback
  → filter: headers / request_set: adds Authorization: Bearer grid-api-fallback-secret
  → load_balancer: routes to mock-api-provider.default.svc:8080 (plain HTTP)

Mock API-Provider (in-cluster, kind-grid-consumer)
  → OpenAI-compatible server (grid-mock-providers)
  → Validates Authorization: Bearer header presence
  → Returns HTTP 200 with valid Chat Completions JSON

Site-a Provider Gateway (kind-grid-site-a) — NOT used for model-z
  → Handles model-x only via mTLS
```

Key credential injection mechanism: the consumer Praxis config includes
`filter: headers` / `request_set` which sets `Authorization: Bearer grid-api-fallback-secret`
on all outgoing requests before upstream forwarding.  The client request carries no
Authorization header; only the Grid-configured credential reaches the API provider.

## Prerequisites

1. Kind clusters created and gateway images loaded:

   ```bash
   cargo xtask env up -c tests/env/operator-routing.toml
   cargo xtask env load-gateway-images -c tests/env/operator-routing.toml
   ```

2. The `grid-mock-providers` image must be available locally:

   ```bash
   docker build -t grid-mock-providers:latest -f mock-providers/Containerfile .
   ```

   The image is loaded into the consumer cluster automatically by the validation
   command.

## Validation Command

```bash
cargo xtask env verify-api-fallback -c tests/env/operator-routing.toml
```

## What PASS Output Means

```
verify-api-fallback: [1/5] deploying provider gateways...
  [PASS] provider gateway ready in kind-grid-site-a

verify-api-fallback: [2/5] deploying mock-api-provider in consumer cluster...
  api_provider endpoint: mock-api-provider.default.svc:8080

verify-api-fallback: [3/5] operator reconcile + overlay export...
  [OK] api_provider candidate: model="model-z" cluster="op-e2e-api-fallback" fresh=true
  [OK] overlay scoring order: local=site-a (pos 0) before api=op-e2e-api-fallback (pos 1)

verify-api-fallback: [4/5] deploying consumer gateway with api-provider cluster...
  [PASS] api-fallback consumer gateway ready in kind-grid-consumer

verify-api-fallback: [5/5] verifying API-provider fallback routing and credential injection...
  [PASS] model model-x (from site-a (local provider)) returns 200
  [PASS] model model-x response is valid Chat Completions JSON
  [PASS] model model-z (from api-provider mock (api fallback)) returns 200
  [PASS] model model-z response is valid Chat Completions JSON
  [PASS] credential injection negative proof: direct request without Authorization returns 401
  [PASS] credential injection positive proof: gateway request without client Authorization returns 200
          (gateway injected Bearer "grid-api-fallback-secret")
  [PASS] injected credential: api-provider response is valid Chat Completions JSON
  [PASS] unknown model fails cleanly via consumer gateway

RESULT: PASS provider inference baseline (9 assertions)
verify-api-fallback: PASS
```

## What Proves Gateway-Level Credential Injection

### Negative proof
A direct request to the mock API-provider **without** an `Authorization` header
returns `401 Unauthorized`.  This establishes that the backend genuinely requires
a credential.

### Positive proof
A request routed **through the consumer gateway** without the client sending any
`Authorization` header returns `200 OK` with a valid response.  The gateway config
includes `filter: headers` / `request_set` which injects
`Authorization: Bearer grid-api-fallback-secret` before forwarding.

Together these prove:
- The mock API-provider requires a bearer token.
- The client did not supply one.
- The gateway supplied it from its own configuration.

The mechanism is Praxis's built-in `filter: headers` filter with `request_set`,
which sets (or replaces) named headers on outgoing upstream requests.  This filter
is part of the standard Praxis filter library and is available in the
`praxis-ai:llmd-ext-proc` build used by the Grid consumer gateway.

In a production deployment, the injected token value would be read from a Kubernetes
Secret referenced by `InferenceProvider.spec.auth`.  The credential management path
from the operator CRD to the Praxis consumer config is not yet wired; the kind demo
uses a static token baked into the consumer config by the xtask harness.

## What Proves API-Fallback Routing

The overlay generated by the Grid operator contains exactly two candidates:

- `model-x @ site-a` (local, score ≈ 7.0)
- `model-z @ op-e2e-api-fallback` (api_provider, score ≈ 5.8)

The api_provider candidate sorts after the local one because the scoring engine
assigns `BackendKind::ApiProvider` a locality score of 0.1 vs 1.0 for
`BackendKind::Local`.  The consumer gateway's `grid_route` filter selects
`gateway-op-e2e-api-fallback` for `model-z` and `gateway-site-a` for `model-x`.

A request for `model-z` can only be routed to `gateway-op-e2e-api-fallback` —
the overlay has no `model-z @ site-a` candidate and the site-a provider only
declares `model-x`.

## Cleanup Notes

The `mock-api-provider` Deployment and Service are deleted automatically at the end
of each run.  Other Grid resources are cleaned at the start so the command is
idempotent.

To manually clean up after a failed run:

```bash
kubectl --context kind-grid-consumer delete deployment mock-api-provider --ignore-not-found
kubectl --context kind-grid-consumer delete service mock-api-provider --ignore-not-found
cargo xtask env verify-api-fallback -c tests/env/operator-routing.toml  # retries cleanly
```

## Limitations

- **Uses a mock API-provider, not real OpenAI or Anthropic.**
  The mock accepts any Bearer token value and returns a fixed response.  It does not
  validate the specific token value, enforce rate limits, or implement streaming.

- **Credential injection is gateway-config-level, not operator-managed.**
  The injected token (`grid-api-fallback-secret`) is baked into the consumer Praxis
  config by the xtask harness.  In production, the Grid operator would read the
  provider credential from `InferenceProvider.spec.auth.secret_ref` (a Kubernetes
  Secret reference) and project it into the Praxis config.  The CRD type
  (`AuthConfig`, `AuthStrategy`) exists in the operator codebase but is not yet
  read by the overlay renderer.

- **Credential scope is per filter chain, not per cluster.**
  The `filter: headers` / `request_set` applies to all upstream requests in the
  consumer filter chain, including those going to local provider gateways.  Local
  provider gateways ignore the injected `Authorization` header (they authenticate
  via mTLS, not Bearer token).  In production, per-cluster credential injection
  would be configured at the cluster level when Praxis adds that capability.

- **Does not prove budget enforcement.**
  No cost or rate-limit policy is applied.

- **Does not prove production secret rotation.**
  Dynamic credential rotation is out of scope for this validation.
