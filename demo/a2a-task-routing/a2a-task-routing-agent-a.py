#!/usr/bin/env python3
"""Mock A2A agent-a for task routing validation.

Manual validation only -- not a production server.

Handles:
- SendMessage: returns a JSON-RPC result with task id "task-demo-123".
- GetTask for "task-demo-123": returns a recognizable task status.
- All other methods: returns a JSON-RPC error.
"""

import json
from http.server import HTTPServer, BaseHTTPRequestHandler


class AgentAHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        try:
            req = json.loads(body)
        except json.JSONDecodeError:
            self._respond(400, {"error": "invalid JSON"})
            return

        method = req.get("method", "")
        req_id = req.get("id")
        params = req.get("params", {})

        if method == "SendMessage":
            self._respond(200, {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "task": {
                        "id": "task-demo-123",
                        "contextId": "ctx-demo-1",
                        "status": {"state": "TASK_STATE_WORKING"},
                        "artifacts": [],
                    }
                },
            })
        elif method == "GetTask":
            task_id = params.get("id", "")
            if task_id == "task-demo-123":
                self._respond(200, {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "task": {
                            "id": "task-demo-123",
                            "contextId": "ctx-demo-1",
                            "status": {"state": "TASK_STATE_COMPLETED"},
                            "artifacts": [{"parts": [{"text": "result from agent-a"}]}],
                        }
                    },
                })
            else:
                self._respond(200, {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32001, "message": f"agent-a: unknown task {task_id}"},
                })
        else:
            self._respond(200, {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"agent-a: unknown method {method}"},
            })

    def _respond(self, status, body):
        payload = json.dumps(body)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload.encode())

    def log_message(self, fmt, *args):
        print(f"[agent-a] {args[0]}")


if __name__ == "__main__":
    port = 9101
    print(f"agent-a listening on :{port}")
    HTTPServer(("127.0.0.1", port), AgentAHandler).serve_forever()
