#!/usr/bin/env python3
"""Stdlib-only load generator and summarizer for the passthrough demo."""

import argparse
import concurrent.futures
import datetime
import json
import math
import os
import platform
import statistics
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any

VERSION = "1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run")
    run.add_argument("--profile", required=True)
    run.add_argument("--workload", required=True)
    run.add_argument("--url", required=True)
    run.add_argument("--model", required=True)
    run.add_argument("--requests", type=int, default=200)
    run.add_argument("--concurrency", type=int, default=8)
    run.add_argument("--warmup", type=int, default=20)
    run.add_argument("--store", choices=("true", "false"), default="false")
    run.add_argument("--output", required=True)

    metadata = subparsers.add_parser("metadata")
    metadata.add_argument("--praxis-dir", required=True)
    metadata.add_argument("--output", required=True)

    summary = subparsers.add_parser("summarize")
    summary.add_argument("--artifact-dir", required=True)
    summary.add_argument("--output", required=True)

    return parser.parse_args()


def request_body(workload: str, model: str, store: bool) -> dict[str, Any]:
    base: dict[str, Any] = {"model": model, "store": store}
    if workload == "small-json":
        return {**base, "input": "benchmark request"}
    if workload == "streaming-sse":
        return {"model": model, "input": "stream benchmark", "stream": True, "store": False}
    if workload.startswith("payload-"):
        kib = int(workload.removeprefix("payload-").removesuffix("kib"))
        return {**base, "input": "x" * (kib * 1024)}
    if workload == "tools":
        return {
            **base,
            "input": "tool benchmark",
            "tools": [
                {
                    "type": "function",
                    "name": "read_file",
                    "description": "Read a file",
                    "parameters": {"type": "object", "properties": {"path": {"type": "string"}}},
                }
            ],
        }
    if workload == "function-call-output":
        return {
            **base,
            "input": [
                {
                    "type": "function_call_output",
                    "call_id": "call_benchmark_001",
                    "output": '{"result":42}',
                }
            ],
        }
    raise ValueError(f"unknown workload: {workload}")


def execute_request(url: str, encoded_body: bytes, streaming: bool) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=encoded_body,
        method="POST",
        headers={"content-type": "application/json", "x-demo-compact-response": "true"},
    )
    started = time.perf_counter_ns()
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            ttfe_ms = None
            if streaming:
                first_line = response.readline()
                ttfe_ms = (time.perf_counter_ns() - started) / 1_000_000
                remaining = response.read()
                body_bytes = len(first_line) + len(remaining)
            else:
                body_bytes = len(response.read())
            latency_ms = (time.perf_counter_ns() - started) / 1_000_000
            return {
                "success": 200 <= response.status < 300,
                "status": response.status,
                "latency_ms": latency_ms,
                "ttfe_ms": ttfe_ms,
                "response_bytes": body_bytes,
            }
    except Exception as error:
        return {
            "success": False,
            "status": None,
            "latency_ms": (time.perf_counter_ns() - started) / 1_000_000,
            "ttfe_ms": None,
            "response_bytes": 0,
            "error": str(error),
        }


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


def run_benchmark(args: argparse.Namespace) -> None:
    body = request_body(args.workload, args.model, args.store == "true")
    encoded = json.dumps(body, separators=(",", ":")).encode()
    streaming = args.workload == "streaming-sse"

    for _ in range(args.warmup):
        execute_request(args.url, encoded, streaming)

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = [executor.submit(execute_request, args.url, encoded, streaming) for _ in range(args.requests)]
        samples = [future.result() for future in futures]
    elapsed = time.perf_counter() - started

    latencies = [sample["latency_ms"] for sample in samples]
    ttfes = [sample["ttfe_ms"] for sample in samples if sample["ttfe_ms"] is not None]
    successes = sum(1 for sample in samples if sample["success"])
    result = {
        "generated_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "profile": args.profile,
        "workload": args.workload,
        "url": args.url,
        "model": args.model,
        "store": args.store == "true",
        "requests": args.requests,
        "concurrency": args.concurrency,
        "warmup_requests": args.warmup,
        "elapsed_seconds": elapsed,
        "rps": args.requests / elapsed,
        "success_rate": successes / args.requests,
        "latency_ms": {
            "p50": percentile(latencies, 0.50),
            "p95": percentile(latencies, 0.95),
            "p99": percentile(latencies, 0.99),
            "mean": statistics.fmean(latencies),
        },
        "ttfe_ms": (
            {
                "p50": percentile(ttfes, 0.50),
                "p95": percentile(ttfes, 0.95),
                "p99": percentile(ttfes, 0.99),
                "mean": statistics.fmean(ttfes),
            }
            if ttfes
            else None
        ),
        "errors": [sample.get("error") for sample in samples if not sample["success"]][:10],
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        f"{args.profile:28} {args.workload:22} "
        f"rps={result['rps']:.1f} p50={result['latency_ms']['p50']:.3f}ms "
        f"p99={result['latency_ms']['p99']:.3f}ms success={result['success_rate']:.2%}"
    )


def command_output(command: list[str], cwd: str | None = None) -> str:
    return subprocess.check_output(command, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def cpu_model() -> str:
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.exists():
        for line in cpuinfo.read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    return platform.processor() or command_output(["uname", "-m"])


def write_metadata(args: argparse.Namespace) -> None:
    praxis_dir = os.path.abspath(args.praxis_dir)
    metadata = {
        "generated_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "praxis_dir": praxis_dir,
        "praxis_commit": command_output(["git", "rev-parse", "HEAD"], praxis_dir),
        "praxis_branch": command_output(["git", "branch", "--show-current"], praxis_dir),
        "praxis_dirty": bool(command_output(["git", "status", "--porcelain"], praxis_dir)),
        "rustc": command_output(["rustc", "--version"]),
        "python": platform.python_version(),
        "load_generator": f"scripts/benchmark_client.py v{VERSION} (Python stdlib ThreadPoolExecutor + urllib)",
        "os": platform.platform(),
        "cpu": cpu_model(),
        "logical_cpus": os.cpu_count(),
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


def fmt_ms(value: float) -> str:
    return f"{value:.3f}ms"


def summarize(args: argparse.Namespace) -> None:
    artifact_dir = Path(args.artifact_dir)
    output = Path(args.output)
    runs = [json.loads(path.read_text()) for path in sorted((artifact_dir / "raw").glob("*.json"))]
    if not runs:
        raise RuntimeError(f"no raw benchmark JSON found under {artifact_dir / 'raw'}")
    metadata = json.loads((artifact_dir / "metadata.json").read_text())

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for run in runs:
        grouped.setdefault((run["profile"], run["workload"]), []).append(run)

    def uniform_value(key: str) -> Any:
        values = {run[key] for run in runs}
        return next(iter(values)) if len(values) == 1 else "varied"

    raw_runs_per_row = sorted({len(values) for values in grouped.values()})
    raw_runs_display: Any = raw_runs_per_row[0] if len(raw_runs_per_row) == 1 else "varied"
    artifact_display = os.path.relpath(artifact_dir.resolve(), output.parent.resolve())

    lines = [
        "# /v1/responses Passthrough Benchmark Results",
        "",
        "> These are local mock-backend request-path measurements. They are not model-serving or production-performance claims.",
        "",
        "## Run Metadata",
        "",
        "| Item | Value |",
        "|---|---|",
        f"| Praxis commit | `{metadata['praxis_commit']}` |",
        f"| Praxis branch | `{metadata['praxis_branch']}` |",
        f"| Praxis worktree dirty | `{metadata['praxis_dirty']}` |",
        f"| Rust | `{metadata['rustc']}` |",
        f"| Python | `{metadata['python']}` |",
        f"| OS | `{metadata['os']}` |",
        f"| CPU | `{metadata['cpu']}` ({metadata['logical_cpus']} logical CPUs) |",
        f"| Load generator | `{metadata['load_generator']}` |",
        f"| Generated | `{metadata['generated_at']}` |",
        f"| Raw runs per profile/workload | `{raw_runs_display}` |",
        f"| Measured requests per raw run | `{uniform_value('requests')}` |",
        f"| Warmup requests per raw run | `{uniform_value('warmup_requests')}` |",
        f"| Concurrency | `{uniform_value('concurrency')}` |",
        f"| Raw artifacts | `{artifact_display}` |",
        "",
        "## Median Results",
        "",
        "Each row is the median of the raw runs for that profile/workload.",
        "",
        "| Profile | Workload | Runs | RPS | p50 | p95 | p99 | Success | TTFE p50 |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for (profile, workload), values in sorted(grouped.items()):
        median = statistics.median
        ttfe_values = [value["ttfe_ms"]["p50"] for value in values if value["ttfe_ms"]]
        ttfe = fmt_ms(median(ttfe_values)) if ttfe_values else "-"
        lines.append(
            f"| `{profile}` | `{workload}` | {len(values)} | "
            f"{median(value['rps'] for value in values):.1f} | "
            f"{fmt_ms(median(value['latency_ms']['p50'] for value in values))} | "
            f"{fmt_ms(median(value['latency_ms']['p95'] for value in values))} | "
            f"{fmt_ms(median(value['latency_ms']['p99'] for value in values))} | "
            f"{median(value['success_rate'] for value in values):.2%} | {ttfe} |"
        )

    lines.extend(
        [
            "",
            "## Interpretation Guardrails",
            "",
            "- `direct-backend` is a control for the same Python mock, not a theoretical zero-overhead lower bound. Direct samples exercise the Python server's client-connection handling, while proxied samples also exercise Praxis upstream connection management.",
            "- The alias profile parses and reserializes JSON. Its relative cost should grow with request-body size; compare it primarily with the no-op rewrite profile.",
            "- The full-flow profile intentionally performs concurrent SQLite persistence for non-streaming requests. Local database contention is part of that profile and can dominate tail latency.",
            "- Streaming requests skip response persistence, so the full-flow streaming row does not measure SQLite writes.",
            "- The Python stdlib load generator can become part of the bottleneck. Treat comparisons as directional evidence within this run.",
            "",
            "## Claim Boundaries",
            "",
            "- The mocks return immediately, so results isolate client, proxy, JSON handling, routing, persistence, and local HTTP overhead.",
            "- Results do not represent GPU inference, model quality, production capacity, or end-user latency.",
            "- Streaming TTFE here means time to the first deterministic mock SSE line, not model time-to-first-token.",
            "- The full-flow profile includes classifier, validator, SQLite response store, router, and load balancer.",
            "- Publish comparisons only from runs with at least three raw samples per profile/workload.",
            "",
        ]
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines))
    print(f"Summary: {output}")


def main() -> None:
    args = parse_args()
    if args.command == "run":
        run_benchmark(args)
    elif args.command == "metadata":
        write_metadata(args)
    else:
        summarize(args)


if __name__ == "__main__":
    main()
