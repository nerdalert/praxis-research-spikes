# Track B Demo Scripts

## Setup

See [deploy.md](../deploy.md) for full setup instructions including
Praxis, Go EPP, and inference simulator build requirements.

> **Claim boundary:** Track B demos prove Praxis carries the Go EPP
> scheduling decision without Envoy using generic full-duplex ext_proc.
> They do not prove Praxis-native scheduling features — those are Track A.

## Validated Demos

| Script | Environment | What it proves |
|---|---|---|
| `local-request-routing/run-request-routing.sh` | Local processes | 8 assertions: routing, security, header stripping, body preservation, Process count, failure, recovery |
| `kind-request-routing/run-request-routing.sh` | KIND cluster | 5 assertions: deployment, repeated routing, EPP failure/recovery, h2 checks, image identity |

## Running

```bash
# Local request routing (8 assertions)
bash scripts/local-request-routing/run-request-routing.sh

# KIND deployment (5 assertions)
bash scripts/kind-request-routing/run-request-routing.sh
```

## Filter Composition

Both suites use the generic `ext_proc` + `endpoint_selector` composition:

```yaml
filters:
  - filter: ext_proc
    target: "http://go-epp:9002"
    processing_mode:
      request_body_mode: full_duplex_streamed
      response_header_mode: skip
  - filter: endpoint_selector
    source_header: x-gateway-destination-endpoint
    required: true
    status_on_required_failure: 503
    strip_header: true
```

No `llmd_external_epp` filter or legacy compatibility layer is used.

## Benchmark Results

See [benchmark results](../../llm-d-benchmarks/results.md) for
`praxis-ext-proc-full-duplex-go-epp` vs `envoy-go-epp`.
