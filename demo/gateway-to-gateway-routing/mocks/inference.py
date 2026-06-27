#!/usr/bin/env python3
"""Minimal OpenAI-compatible inference mock for gateway-to-gateway E2E.

Returns a JSON response that identifies which site handled the request,
allowing test assertions to verify route selection.

Usage:
    python3 inference.py <port> <site-name>
"""

import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


class Handler(BaseHTTPRequestHandler):
    site = "unknown"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        model = "unknown"
        try:
            req = json.loads(body)
            model = req.get("model", "unknown")
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass

        resp = json.dumps({
            "id": "mock-0001",
            "object": "chat.completion",
            "model": model,
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": f"mock response from {self.site}",
                },
                "finish_reason": "stop",
            }],
            "site": self.site,
            "source": "mock-inference",
        }).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def do_GET(self):
        resp = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, fmt, *args):
        pass


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <port> <site-name>", file=sys.stderr)
        sys.exit(1)
    port = int(sys.argv[1])
    Handler.site = sys.argv[2]
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"inference mock listening on 127.0.0.1:{port} (site={Handler.site})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
