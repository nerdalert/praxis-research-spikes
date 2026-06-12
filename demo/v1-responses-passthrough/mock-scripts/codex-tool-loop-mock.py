#!/usr/bin/env python3
"""Deterministic SSE backend for the Codex tool-loop E2E test.

Handles exactly two requests:
  1. Returns an SSE stream with a single `exec_command` function_call.
  2. Returns an SSE stream with a final text message.

The mock records each raw request to LOG_DIR/backend-req-N.json
for post-hoc verification.

Usage:
    python3 codex-tool-loop-mock.py --port 18285
    LOG_DIR=/tmp python3 codex-tool-loop-mock.py --port 18285
"""

import argparse
import http.server
import json
import os
import sys
import threading
from typing import Any

CALL_ID = "call_praxis_e2e_001"
SENTINEL_CMD = "printf 'praxis-codex-e2e' > proof.txt"
FINAL_TEXT = "Proof file created with content praxis-codex-e2e."


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(description="Codex tool-loop SSE mock")
    parser.add_argument("--port", type=int, default=18285)
    parser.add_argument("--name", default="codex-tool-loop-backend")
    return parser.parse_args()


def sse_encode(events: list[dict[str, Any]]) -> bytes:
    """Encode a list of event dicts as SSE data lines."""
    lines = [f"data: {json.dumps(ev)}\n\n" for ev in events]
    lines.append("data: [DONE]\n\n")
    return "".join(lines).encode()


def build_function_call_events(model: str) -> list[dict[str, Any]]:
    """Build SSE events for the first request: a function_call."""
    resp_id = "resp_e2e_001"
    cmd_args = json.dumps({"cmd": SENTINEL_CMD})
    fc_item = {
        "type": "function_call",
        "id": "fc_001",
        "call_id": CALL_ID,
        "name": "exec_command",
        "arguments": cmd_args,
        "status": "completed",
    }
    return [
        {
            "type": "response.created",
            "response": {
                "id": resp_id,
                "object": "response",
                "status": "in_progress",
                "model": model,
                "output": [],
            },
        },
        {
            "type": "response.in_progress",
            "response": {
                "id": resp_id,
                "object": "response",
                "status": "in_progress",
                "model": model,
                "output": [],
            },
        },
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "type": "function_call",
                "id": "fc_001",
                "call_id": CALL_ID,
                "name": "exec_command",
                "arguments": "",
                "status": "in_progress",
            },
        },
        {
            "type": "response.function_call_arguments.delta",
            "output_index": 0,
            "item_id": "fc_001",
            "delta": cmd_args,
        },
        {
            "type": "response.function_call_arguments.done",
            "output_index": 0,
            "item_id": "fc_001",
            "arguments": cmd_args,
        },
        {"type": "response.output_item.done", "output_index": 0, "item": fc_item},
        {
            "type": "response.completed",
            "response": {
                "id": resp_id,
                "object": "response",
                "status": "completed",
                "model": model,
                "output": [fc_item],
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 20,
                    "total_tokens": 120,
                },
            },
        },
    ]


def build_final_message_events(model: str) -> list[dict[str, Any]]:
    """Build SSE events for the second request: a text message."""
    msg_item = {
        "type": "message",
        "id": "msg_final",
        "role": "assistant",
        "status": "completed",
        "content": [
            {"type": "output_text", "text": FINAL_TEXT, "annotations": []}
        ],
    }
    resp = {
        "id": "resp_e2e_002",
        "object": "response",
        "created_at": 1_700_000_000,
        "status": "completed",
        "model": model,
        "output": [msg_item],
        "usage": {
            "input_tokens": 150,
            "output_tokens": 10,
            "total_tokens": 160,
        },
    }
    return [
        {"type": "response.created", "response": resp},
        {"type": "response.output_item.added", "output_index": 0, "item": msg_item},
        {
            "type": "response.content_part.added",
            "output_index": 0,
            "content_index": 0,
            "part": {"type": "output_text", "text": "", "annotations": []},
        },
        {
            "type": "response.output_text.delta",
            "output_index": 0,
            "content_index": 0,
            "delta": FINAL_TEXT,
        },
        {
            "type": "response.output_text.done",
            "output_index": 0,
            "content_index": 0,
            "text": FINAL_TEXT,
        },
        {
            "type": "response.content_part.done",
            "output_index": 0,
            "content_index": 0,
            "part": {"type": "output_text", "text": FINAL_TEXT, "annotations": []},
        },
        {"type": "response.output_item.done", "output_index": 0, "item": msg_item},
        {"type": "response.completed", "response": resp},
    ]


class CodexToolLoopHandler(http.server.BaseHTTPRequestHandler):
    """Handle exactly two POST /v1/responses requests."""

    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True
    backend_name = "codex-tool-loop-backend"
    log_dir = "/tmp"
    request_count = 0
    max_requests = 2

    def do_POST(self) -> None:
        """Serve one SSE response per request."""
        CodexToolLoopHandler.request_count += 1
        n = CodexToolLoopHandler.request_count
        raw = self.rfile.read(int(self.headers.get("content-length", "0")))
        body = json.loads(raw)
        model = body.get("model", "unknown")

        log_path = os.path.join(self.log_dir, f"backend-req-{n}.json")
        with open(log_path, "w") as f:
            json.dump(body, f, indent=2)

        print(f"[{self.backend_name}] POST #{n} model={model}", flush=True)

        if n == 1:
            events = build_function_call_events(model)
        else:
            events = build_final_message_events(model)

        sse_bytes = sse_encode(events)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        self.wfile.write(sse_bytes)
        self.wfile.flush()

        if n >= self.max_requests:
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, _format: str, *_args: Any) -> None:
        """Suppress default access logging."""


def main() -> None:
    """Start the mock server."""
    args = parse_args()
    CodexToolLoopHandler.backend_name = args.name
    CodexToolLoopHandler.log_dir = os.environ.get("LOG_DIR", "/tmp")
    CodexToolLoopHandler.request_count = 0

    server = http.server.HTTPServer(("127.0.0.1", args.port), CodexToolLoopHandler)
    print(f"[{args.name}] Codex tool-loop SSE mock on 127.0.0.1:{args.port}")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
