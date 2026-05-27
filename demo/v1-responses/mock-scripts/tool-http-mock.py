#!/usr/bin/env python3
"""HTTP tool mock backend for manual Praxis validation.

Records and prints every POST body, returns a configurable
JSON response.

Usage:
    python3 tool-http-mock.py [PORT] [TOOL_NAME]
    # default port: 4101, default name: get_weather
"""

import http.server
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4101
TOOL_NAME = sys.argv[2] if len(sys.argv) > 2 else "get_weather"


class Handler(http.server.BaseHTTPRequestHandler):
    request_count = 0

    def do_POST(self):
        Handler.request_count += 1
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()

        print(f"\n--- [{TOOL_NAME}] POST #{Handler.request_count} {self.path} ---")
        print(f"BODY: {body}")
        print("---")
        sys.stdout.flush()

        resp = json.dumps({"weather": "sunny, 72F", "tool": TOOL_NAME})

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp.encode())

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[{TOOL_NAME}] Tool mock on 127.0.0.1:{PORT}")
    print("Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()
