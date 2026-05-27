#!/usr/bin/env python3
"""Responses API mock for the full agent loop.

Returns function_call on first request, final text on
second request (when body contains function_call_output).

Usage:
    python3 responses-loop-mock.py [PORT]
    # default port: 3101
"""

import http.server
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3101


class Handler(http.server.BaseHTTPRequestHandler):
    request_count = 0

    def do_POST(self):
        Handler.request_count += 1
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()

        print(f"\n--- [loop-mock] POST #{Handler.request_count} {self.path} ---")
        print(f"BODY: {body}")
        print("---")
        sys.stdout.flush()

        if "function_call_output" in body:
            resp = json.dumps({
                "id": "resp_final",
                "object": "response",
                "created_at": 1700000000,
                "status": "completed",
                "model": "loop-model",
                "output": [{
                    "type": "message",
                    "id": "msg_final",
                    "role": "assistant",
                    "status": "completed",
                    "content": [{
                        "type": "output_text",
                        "text": "It is sunny and 72F in Boston. Bring sunglasses!",
                        "annotations": [],
                    }],
                }],
                "usage": {"input_tokens": 30, "output_tokens": 15, "total_tokens": 45},
            })
        else:
            resp = json.dumps({
                "id": "resp_fc",
                "object": "response",
                "created_at": 1700000000,
                "status": "completed",
                "model": "loop-model",
                "output": [{
                    "type": "function_call",
                    "id": "fc_001",
                    "call_id": "call_weather_001",
                    "name": "get_weather",
                    "arguments": '{"city":"Boston"}',
                    "status": "completed",
                }],
                "usage": {"input_tokens": 15, "output_tokens": 8, "total_tokens": 23},
            })

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
    print(f"[loop-mock] Responses loop mock on 127.0.0.1:{PORT}")
    print("1st call: function_call(get_weather), 2nd call: final text")
    print("Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()
