# /v1/responses Passthrough Benchmark Results

> These are local mock-backend request-path measurements. They are not model-serving or production-performance claims.

## Run Metadata

| Item | Value |
|---|---|
| Praxis commit | `26b2d460237bf08794609bc63e627e6d32bcea4c` |
| Praxis branch | `feat/openai-responses-model-rewrite` |
| Praxis worktree dirty | `True` |
| Rust | `rustc 1.94.0 (4a4ef493e 2026-03-02)` |
| Python | `3.12.3` |
| OS | `Linux-6.14.0-1018-aws-x86_64-with-glibc2.39` |
| CPU | `Intel(R) Xeon(R) CPU E5-2686 v4 @ 2.30GHz` (8 logical CPUs) |
| Load generator | `scripts/benchmark_client.py v1 (Python stdlib ThreadPoolExecutor + urllib)` |
| Generated | `2026-06-12T02:48:31.877512+00:00` |
| Raw runs per profile/workload | `3` |
| Measured requests per raw run | `200` |
| Warmup requests per raw run | `20` |
| Concurrency | `8` |
| Raw artifacts | `artifacts/20260612T024515Z` |

## Median Results

Each row is the median of the raw runs for that profile/workload.

| Profile | Workload | Runs | RPS | p50 | p95 | p99 | Success | TTFE p50 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `direct-backend` | `function-call-output` | 3 | 178.1 | 4.101ms | 7.262ms | 10.541ms | 100.00% | - |
| `direct-backend` | `payload-16kib` | 3 | 178.1 | 5.920ms | 9.534ms | 14.653ms | 100.00% | - |
| `direct-backend` | `payload-256kib` | 3 | 165.9 | 17.053ms | 23.573ms | 27.637ms | 100.00% | - |
| `direct-backend` | `payload-64kib` | 3 | 179.0 | 7.333ms | 11.045ms | 14.188ms | 100.00% | - |
| `direct-backend` | `small-json` | 3 | 178.1 | 4.431ms | 8.203ms | 13.147ms | 100.00% | - |
| `direct-backend` | `streaming-sse` | 3 | 923.4 | 7.984ms | 12.419ms | 15.499ms | 100.00% | 4.331ms |
| `direct-backend` | `tools` | 3 | 178.9 | 4.190ms | 8.293ms | 11.188ms | 100.00% | - |
| `praxis-format-route` | `function-call-output` | 3 | 1299.1 | 5.238ms | 9.755ms | 12.788ms | 100.00% | - |
| `praxis-format-route` | `payload-16kib` | 3 | 996.3 | 6.614ms | 14.163ms | 17.997ms | 100.00% | - |
| `praxis-format-route` | `payload-256kib` | 3 | 452.4 | 16.926ms | 26.739ms | 32.490ms | 100.00% | - |
| `praxis-format-route` | `payload-64kib` | 3 | 830.7 | 8.532ms | 17.085ms | 22.746ms | 100.00% | - |
| `praxis-format-route` | `small-json` | 3 | 1320.8 | 5.382ms | 9.821ms | 11.002ms | 100.00% | - |
| `praxis-format-route` | `streaming-sse` | 3 | 1140.7 | 6.335ms | 10.650ms | 13.924ms | 100.00% | 6.007ms |
| `praxis-format-route` | `tools` | 3 | 1291.6 | 5.385ms | 10.081ms | 12.211ms | 100.00% | - |
| `praxis-full-flow` | `function-call-output` | 3 | 69.1 | 14.177ms | 546.349ms | 1246.689ms | 100.00% | - |
| `praxis-full-flow` | `payload-16kib` | 3 | 81.0 | 13.963ms | 441.605ms | 1246.296ms | 100.00% | - |
| `praxis-full-flow` | `payload-256kib` | 3 | 68.7 | 27.749ms | 549.809ms | 958.356ms | 100.00% | - |
| `praxis-full-flow` | `payload-64kib` | 3 | 69.4 | 16.058ms | 643.495ms | 1244.850ms | 100.00% | - |
| `praxis-full-flow` | `small-json` | 3 | 77.2 | 13.806ms | 542.516ms | 1146.815ms | 100.00% | - |
| `praxis-full-flow` | `streaming-sse` | 3 | 1087.1 | 6.778ms | 11.838ms | 13.632ms | 100.00% | 6.325ms |
| `praxis-full-flow` | `tools` | 3 | 107.5 | 10.709ms | 439.052ms | 946.733ms | 100.00% | - |
| `praxis-model-rewrite-alias` | `function-call-output` | 3 | 1318.5 | 5.109ms | 10.100ms | 12.318ms | 100.00% | - |
| `praxis-model-rewrite-alias` | `payload-16kib` | 3 | 1036.9 | 6.686ms | 14.015ms | 16.948ms | 100.00% | - |
| `praxis-model-rewrite-alias` | `payload-256kib` | 3 | 308.3 | 24.486ms | 37.580ms | 44.323ms | 100.00% | - |
| `praxis-model-rewrite-alias` | `payload-64kib` | 3 | 780.0 | 9.392ms | 17.081ms | 19.406ms | 100.00% | - |
| `praxis-model-rewrite-alias` | `small-json` | 3 | 1370.4 | 5.318ms | 9.561ms | 11.045ms | 100.00% | - |
| `praxis-model-rewrite-alias` | `streaming-sse` | 3 | 1096.2 | 6.775ms | 11.765ms | 13.844ms | 100.00% | 6.395ms |
| `praxis-model-rewrite-alias` | `tools` | 3 | 1312.1 | 5.347ms | 9.983ms | 12.318ms | 100.00% | - |
| `praxis-model-rewrite-noop` | `function-call-output` | 3 | 1336.9 | 5.346ms | 9.264ms | 10.948ms | 100.00% | - |
| `praxis-model-rewrite-noop` | `payload-16kib` | 3 | 1235.6 | 5.827ms | 11.600ms | 14.356ms | 100.00% | - |
| `praxis-model-rewrite-noop` | `payload-256kib` | 3 | 473.3 | 15.701ms | 27.023ms | 29.895ms | 100.00% | - |
| `praxis-model-rewrite-noop` | `payload-64kib` | 3 | 1003.5 | 6.787ms | 13.537ms | 15.647ms | 100.00% | - |
| `praxis-model-rewrite-noop` | `small-json` | 3 | 1301.5 | 5.475ms | 9.823ms | 11.870ms | 100.00% | - |
| `praxis-model-rewrite-noop` | `streaming-sse` | 3 | 1110.5 | 6.444ms | 11.076ms | 14.214ms | 100.00% | 5.957ms |
| `praxis-model-rewrite-noop` | `tools` | 3 | 1301.3 | 5.365ms | 9.709ms | 12.145ms | 100.00% | - |

## Interpretation Guardrails

- `direct-backend` is a control for the same Python mock, not a theoretical zero-overhead lower bound. Direct samples exercise the Python server's client-connection handling, while proxied samples also exercise Praxis upstream connection management.
- The alias profile parses and reserializes JSON. Its relative cost should grow with request-body size; compare it primarily with the no-op rewrite profile.
- The full-flow profile intentionally performs concurrent SQLite persistence for non-streaming requests. Local database contention is part of that profile and can dominate tail latency.
- Streaming requests skip response persistence, so the full-flow streaming row does not measure SQLite writes.
- The Python stdlib load generator can become part of the bottleneck. Treat comparisons as directional evidence within this run.

## Claim Boundaries

- The mocks return immediately, so results isolate client, proxy, JSON handling, routing, persistence, and local HTTP overhead.
- Results do not represent GPU inference, model quality, production capacity, or end-user latency.
- Streaming TTFE here means time to the first deterministic mock SSE line, not model time-to-first-token.
- The full-flow profile includes classifier, validator, SQLite response store, router, and load balancer.
- Publish comparisons only from runs with at least three raw samples per profile/workload.
