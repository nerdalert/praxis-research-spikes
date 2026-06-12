# Run And Validate

## Prerequisites

- Praxis checkout containing PR 1.
- Rust 1.94+.
- Python 3.11+.
- Bash, curl, git, and `setsid`.

The scripts default to this sibling layout:

```text
prs/
  praxis/
  praxis-research-spikes/
```

Override the Praxis checkout when needed:

```bash
export PRAXIS_DIR=/path/to/praxis
```

## Smoke Validation

```bash
cd demo/v1-responses-passthrough
./scripts/run-smoke.sh
```

The script:

1. Builds Praxis with `ai-inference`.
2. Starts deterministic Responses JSON, Responses SSE, Chat Completions, and
   default backends.
3. Generates a temporary Praxis config.
4. Starts Praxis.
5. Runs and asserts all seven scenarios.
6. Cleans up every process.

Reuse an existing debug build:

```bash
SKIP_BUILD=1 ./scripts/run-smoke.sh
```

## Regenerate The Transcript

```bash
./run-complete-e2e-demo.sh
```

Use a different output path:

```bash
./run-complete-e2e-demo.sh /tmp/responses-passthrough-output.md
```

## Full Benchmark Matrix

Defaults:

- 3 runs per profile/workload.
- 200 measured requests per run.
- 20 warmup requests.
- Concurrency 8.

```bash
./scripts/run-benchmark.sh
```

Raw artifacts and a generated summary are written under:

```text
artifacts/<UTC-run-id>/
  configs/
  logs/
  raw/
  metadata.json
  results.md
```

Publish a completed run into this directory only after reviewing the raw
artifacts:

```bash
RESULTS_OUTPUT="$PWD/results.md" ./scripts/run-benchmark.sh
```

## Reduced Harness Validation

This confirms that every profile and workload executes, but it does not produce
publishable benchmark results:

```bash
SKIP_BUILD=1 \
BENCH_RUNS=1 \
BENCH_REQUESTS=10 \
BENCH_WARMUP=2 \
BENCH_CONCURRENCY=2 \
ARTIFACT_DIR=/tmp/v1-responses-benchmark-validation \
RESULTS_OUTPUT=/tmp/v1-responses-benchmark-validation/results.md \
./scripts/run-benchmark.sh
```

## Port Overrides

| Variable | Default |
|---|---:|
| `PRAXIS_PORT` | `18280` |
| `RESPONSES_BACKEND_PORT` | `18281` |
| `STREAM_BACKEND_PORT` | `18282` |
| `CHAT_BACKEND_PORT` | `18283` |
| `DEFAULT_BACKEND_PORT` | `18284` |

Example:

```bash
PRAXIS_PORT=19280 RESPONSES_BACKEND_PORT=19281 ./scripts/run-smoke.sh
```

## Manual Validation Commands

```bash
bash -n run-complete-e2e-demo.sh scripts/common.sh scripts/run-smoke.sh scripts/run-benchmark.sh
python3 -m py_compile \
  mock-scripts/responses-echo-mock.py \
  mock-scripts/responses-streaming-echo-mock.py \
  scripts/smoke_client.py \
  scripts/benchmark_client.py
./scripts/run-smoke.sh
```

## Troubleshooting

If Praxis fails to start, confirm PR 1 is present:

```bash
rg 'openai_responses_model_rewrite' "$PRAXIS_DIR/filter/src/registry.rs"
```

If a port is already occupied, override the corresponding environment variable.
All processes started by the harness are terminated on exit, including failed
runs.

