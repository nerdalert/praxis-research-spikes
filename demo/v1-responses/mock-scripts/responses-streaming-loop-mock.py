#!/usr/bin/env python3
"""Responses API SSE streaming mock for the agent loop.

First request returns text/event-stream with function_call
arguments split across delta events. Second request returns
final JSON.

Usage:
    python3 responses-streaming-loop-mock.py [PORT]
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

        print(f"\n--- [streaming-mock] POST #{Handler.request_count} {self.path} ---")
        print(f"BODY: {body}")
        print("---")
        sys.stdout.flush()

        if "function_call_output" in body:
            resp = json.dumps({
                "id": "resp_final",
                "object": "response",
                "created_at": 1700000000,
                "status": "completed",
                "model": "stream-model",
                "output": [{
                    "type": "message",
                    "id": "msg_final",
                    "role": "assistant",
                    "status": "completed",
                    "content": [{
                        "type": "output_text",
                        "text": "It is sunny and 72F in Boston!",
                        "annotations": [],
                    }],
                }],
                "usage": {"input_tokens": 30, "output_tokens": 15, "total_tokens": 45},
            })
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp.encode())
        else:
            sse = (
                'data: {"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_weather_001","name":"get_weather"}}\n'
                'data: {"type":"response.function_call_arguments.delta","delta":"{\\"cit"}\n'
                'data: {"type":"response.function_call_arguments.delta","delta":"y\\":\\"Bos"}\n'
                'data: {"type":"response.function_call_arguments.delta","delta":"ton\\"}"}\n'
                'data: {"type":"response.function_call_arguments.done","arguments":"{\\"city\\":\\"Boston\\"}"}\n'
                'data: {"type":"response.output_item.done"}\n'
                'data: {"type":"response.completed"}\n'
                'data: [DONE]\n'
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(sse)))
            self.end_headers()
            self.wfile.write(sse.encode())

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[streaming-mock] SSE Responses mock on 127.0.0.1:{PORT}")
    print("1st: SSE function_call(get_weather) with split args")
    print("2nd: JSON final text response")
    print("Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()
