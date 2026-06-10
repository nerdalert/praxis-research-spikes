"""Deterministic A2A agent-a backend on 127.0.0.1:9101."""
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

TASK_ID = "task-live-stream-a"
AGENT = "agent-a"

# A2A v1.0 spec-shaped SSE stream: Task, artifactUpdate, statusUpdate (working), statusUpdate (completed)
SSE_EVENTS = [
    # 1. Initial Task result
    json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"task": {"id": TASK_ID, "contextId": "ctx-live-1", "status": {"state": "TASK_STATE_SUBMITTED"}}}}),
    # 2. TaskArtifactUpdateEvent
    json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"artifactUpdate": {"taskId": TASK_ID, "contextId": "ctx-live-1", "artifact": {"artifactId": "art-1", "parts": [{"text": "Hello from agent-a"}]}}}}),
    # 3. TaskStatusUpdateEvent (working)
    json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"statusUpdate": {"taskId": TASK_ID, "contextId": "ctx-live-1", "status": {"state": "TASK_STATE_WORKING"}}}}),
    # 4. TaskStatusUpdateEvent (completed / terminal)
    json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"statusUpdate": {"taskId": TASK_ID, "contextId": "ctx-live-1", "status": {"state": "TASK_STATE_COMPLETED"}}}}),
]

AGENT_CARD = json.dumps({
    "name": AGENT,
    "url": f"http://127.0.0.1:9101/a2a/",
    "version": "1.0",
    "capabilities": {"streaming": True},
    "skills": [{"id": "echo", "name": "Echo"}],
})


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/.well-known/agent-card.json":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            body = AGENT_CARD.encode()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            req = json.loads(raw)
        except Exception:
            self.send_error(400, "bad JSON")
            return

        method = req.get("method", "")
        req_id = req.get("id", 1)

        if method == "SendStreamingMessage":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            for event in SSE_EVENTS:
                self.wfile.write(f"data: {event}\n\n".encode())
                self.wfile.flush()

        elif method == "GetTask":
            task_id = req.get("params", {}).get("id", "")
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "handled_by": AGENT,
                    "id": task_id,
                    "status": {"state": "TASK_STATE_COMPLETED"},
                },
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"unknown method: {method}"},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # suppress request logging


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 9101), Handler)
    print(f"agent-a listening on 127.0.0.1:9101", flush=True)
    server.serve_forever()
