#!/usr/bin/env python3
"""Deterministic SSE backend for native /v1/responses streaming passthrough."""

import argparse
import http.server
import json
import sys
import time
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18282)
    parser.add_argument("--name", default="streaming-backend")
    parser.add_argument("--first-event-delay-ms", type=float, default=0.0)
    parser.add_argument("--event-delay-ms", type=float, default=0.0)
    return parser.parse_args()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True
    backend_name = "streaming-backend"
    first_event_delay_ms = 0.0
    event_delay_ms = 0.0

    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        encoded = b"ok"
        self.send_response(200)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self) -> None:
        raw = self.rfile.read(int(self.headers.get("content-length", "0")))
        try:
            request_body = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400)
            return

        print(
            f"[{self.backend_name}] {self.command} {self.path} "
            f"bytes={len(raw)} model={request_body.get('model', 'missing')}"
        )
        sys.stdout.flush()

        model = request_body.get("model", "missing")
        events = [
            {"type": "response.created", "response": {"id": "resp_stream_mock", "model": model}},
            {"type": "response.output_text.delta", "delta": "mock "},
            {"type": "response.output_text.delta", "delta": "stream"},
            {"type": "response.completed", "response": {"id": "resp_stream_mock", "model": model}},
        ]
        encoded_events = [f"data: {json.dumps(event, sort_keys=True, separators=(',', ':'))}\n\n".encode() for event in events]
        encoded_events.append(b"data: [DONE]\n\n")
        content_length = sum(len(event) for event in encoded_events)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(content_length))
        self.end_headers()

        time.sleep(self.first_event_delay_ms / 1000)
        for event in encoded_events:
            self.wfile.write(event)
            self.wfile.flush()
            time.sleep(self.event_delay_ms / 1000)

    def log_message(self, _format: str, *_args: Any) -> None:
        pass


def main() -> None:
    args = parse_args()
    Handler.backend_name = args.name
    Handler.first_event_delay_ms = args.first_event_delay_ms
    Handler.event_delay_ms = args.event_delay_ms
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[{args.name}] SSE mock listening on 127.0.0.1:{args.port}")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
