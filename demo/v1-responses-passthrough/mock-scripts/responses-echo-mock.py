#!/usr/bin/env python3
"""Deterministic JSON backend for Responses and Chat Completions requests."""

import argparse
import hashlib
import http.server
import json
import sys
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18281)
    parser.add_argument("--name", default="responses-backend")
    return parser.parse_args()


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True
    backend_name = "responses-backend"

    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        self.send_json({"status": "ok", "backend": self.backend_name})

    def do_POST(self) -> None:
        raw = self.rfile.read(int(self.headers.get("content-length", "0")))
        try:
            request_body = json.loads(raw)
        except json.JSONDecodeError:
            self.send_json({"error": "invalid JSON"}, status=400)
            return

        print(
            f"[{self.backend_name}] {self.command} {self.path} "
            f"bytes={len(raw)} model={request_body.get('model', 'missing')}"
        )
        sys.stdout.flush()

        compact = self.headers.get("x-demo-compact-response") == "true"
        metadata = {"backend": self.backend_name, "request_bytes": len(raw)}
        if not compact:
            metadata["received_request"] = request_body

        if self.path == "/v1/chat/completions":
            response = {
                "id": "chatcmpl_mock",
                "object": "chat.completion",
                "model": request_body.get("model", "unknown"),
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "mock chat response"}}],
                "metadata": metadata,
            }
        else:
            digest = hashlib.sha256(canonical_json(request_body).encode()).hexdigest()[:16]
            response = {
                "id": f"resp_mock_{digest}",
                "object": "response",
                "created_at": 1_700_000_000,
                "status": "completed",
                "model": request_body.get("model", "missing"),
                "output": [
                    {
                        "type": "message",
                        "id": f"msg_{digest}",
                        "role": "assistant",
                        "status": "completed",
                        "content": [{"type": "output_text", "text": "mock response", "annotations": []}],
                    }
                ],
                "usage": {"input_tokens": 8, "output_tokens": 3, "total_tokens": 11},
                "metadata": metadata,
            }
        self.send_json(response)

    def send_json(self, value: Any, status: int = 200) -> None:
        encoded = canonical_json(value).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _format: str, *_args: Any) -> None:
        pass


def main() -> None:
    args = parse_args()
    Handler.backend_name = args.name
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[{args.name}] JSON mock listening on 127.0.0.1:{args.port}")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
