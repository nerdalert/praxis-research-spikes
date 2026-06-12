#!/usr/bin/env python3
"""Assert the complete /v1/responses passthrough demo scenario set."""

import argparse
import json
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class HttpResult:
    status: int
    content_type: str
    body: bytes

    def json(self) -> dict[str, Any]:
        return json.loads(self.body)


@dataclass
class Scenario:
    title: str
    request_body: dict[str, Any]
    evidence: str
    response: Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--praxis-url", required=True)
    parser.add_argument("--stream-backend-url", required=True)
    parser.add_argument("--markdown-output")
    return parser.parse_args()


def post_json(url: str, body: dict[str, Any]) -> HttpResult:
    encoded = json.dumps(body, separators=(",", ":")).encode()
    request = urllib.request.Request(
        url,
        data=encoded,
        method="POST",
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return HttpResult(
            status=response.status,
            content_type=response.headers.get_content_type(),
            body=response.read(),
        )


def received_request(result: HttpResult) -> dict[str, Any]:
    assert result.status == 200
    return result.json()["metadata"]["received_request"]


def run_scenarios(args: argparse.Namespace) -> list[Scenario]:
    praxis_responses = f"{args.praxis_url}/v1/responses"
    praxis_chat = f"{args.praxis_url}/v1/chat/completions"
    direct_stream = f"{args.stream_backend_url}/v1/responses"
    scenarios: list[Scenario] = []

    body = {"model": "backend-native", "input": "no rewrite", "store": False}
    result = post_json(praxis_responses, body)
    assert received_request(result) == body
    scenarios.append(Scenario("No-op passthrough", body, "Backend received the request unchanged.", result.json()))

    body = {"model": "codex-mini-latest", "input": "rewrite this", "store": False}
    result = post_json(praxis_responses, body)
    forwarded = received_request(result)
    assert forwarded["model"] == "llama-3.3-70b"
    assert forwarded["input"] == body["input"]
    scenarios.append(
        Scenario("Model alias rewrite", body, "Backend received model `llama-3.3-70b`.", result.json())
    )

    body = {"input": "inject a default model", "store": False}
    result = post_json(praxis_responses, body)
    forwarded = received_request(result)
    assert forwarded["model"] == "llama-3.3-70b"
    scenarios.append(
        Scenario("Default model injection", body, "Backend received injected model `llama-3.3-70b`.", result.json())
    )

    body = {"model": "backend-native", "input": "stream unchanged", "stream": True, "store": False}
    direct = post_json(direct_stream, body)
    proxied = post_json(praxis_responses, body)
    assert direct.content_type == "text/event-stream"
    assert proxied.content_type == "text/event-stream"
    assert proxied.body == direct.body
    scenarios.append(
        Scenario(
            "Streaming SSE passthrough",
            body,
            "Direct-backend and proxied SSE bytes matched exactly.",
            proxied.body.decode(),
        )
    )

    tools = [
        {
            "type": "function",
            "name": "read_file",
            "description": "Read a file",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}}},
        }
    ]
    body = {"model": "codex-mini-latest", "input": "use a tool", "tools": tools, "store": False}
    result = post_json(praxis_responses, body)
    forwarded = received_request(result)
    assert forwarded["tools"] == tools
    assert forwarded["model"] == "llama-3.3-70b"
    scenarios.append(
        Scenario("Codex-shaped tools request", body, "Tool definitions were preserved while model was rewritten.", result.json())
    )

    function_output = {
        "type": "function_call_output",
        "call_id": "call_demo_001",
        "output": '{"result":42}',
    }
    body = {"model": "codex-mini-latest", "input": [function_output], "store": False}
    result = post_json(praxis_responses, body)
    forwarded = received_request(result)
    assert forwarded["input"] == [function_output]
    scenarios.append(
        Scenario("Function-call follow-up", body, "`function_call_output` and `call_id` were preserved.", result.json())
    )

    body = {"model": "gpt-4.1-mini", "messages": [{"role": "user", "content": "chat request"}]}
    result = post_json(praxis_chat, body)
    parsed = result.json()
    assert parsed["metadata"]["backend"] == "chat-backend"
    assert parsed["metadata"]["received_request"] == body
    scenarios.append(
        Scenario("Mixed Chat Completions traffic", body, "Chat request routed to the separate chat backend.", parsed)
    )

    return scenarios


def render_markdown(path: Path, scenarios: list[Scenario]) -> None:
    lines = [
        "# /v1/responses Passthrough Demo Transcript",
        "",
        "Generated by `scripts/run-smoke.sh`. All scenarios below were asserted before this file was written.",
        "",
        "| # | Scenario | Result |",
        "|---:|---|---|",
    ]
    lines.extend(f"| {index} | {scenario.title} | PASS |" for index, scenario in enumerate(scenarios, start=1))

    for index, scenario in enumerate(scenarios, start=1):
        lines.extend(
            [
                "",
                f"## {index}. {scenario.title}",
                "",
                scenario.evidence,
                "",
                "Request:",
                "",
                "```json",
                json.dumps(scenario.request_body, indent=2, sort_keys=True),
                "```",
                "",
                "Observed response:",
                "",
            ]
        )
        if isinstance(scenario.response, str):
            lines.extend(["```text", scenario.response.rstrip(), "```"])
        else:
            lines.extend(["```json", json.dumps(scenario.response, indent=2, sort_keys=True), "```"])

    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    args = parse_args()
    try:
        scenarios = run_scenarios(args)
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise

    for scenario in scenarios:
        print(f"PASS: {scenario.title}")
    print(f"PASS: {len(scenarios)} scenarios")

    if args.markdown_output:
        output = Path(args.markdown_output)
        output.parent.mkdir(parents=True, exist_ok=True)
        render_markdown(output, scenarios)
        print(f"Transcript: {output}")


if __name__ == "__main__":
    main()

