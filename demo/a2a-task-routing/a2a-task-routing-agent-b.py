#!/usr/bin/env python3
"""Mock A2A agent-b (fallback) for task routing validation.

Manual validation only -- not a production server.

Returns a recognizable fallback response for any A2A method,
so the demo can distinguish agent-a routing from fallback.
"""

import json
from http.server import HTTPServer, BaseHTTPRequestHandler


class AgentBHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        try:
            req = json.loads(body)
        except json.JSONDecodeError:
            self._respond(400, {"error": "invalid JSON"})
            return

        req_id = req.get("id")
        method = req.get("method", "")

        self._respond(200, {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "message": {
                    "role": "ROLE_AGENT",
                    "parts": [{"text": f"fallback agent-b handled {method}"}],
                }
            },
        })

    def _respond(self, status, body):
        payload = json.dumps(body)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload.encode())

    def log_message(self, fmt, *args):
        print(f"[agent-b] {args[0]}")


if __name__ == "__main__":
    port = 9102
    print(f"agent-b listening on :{port}")
    HTTPServer(("127.0.0.1", port), AgentBHandler).serve_forever()
