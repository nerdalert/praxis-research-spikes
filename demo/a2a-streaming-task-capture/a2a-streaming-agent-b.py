"""Deterministic A2A agent-b backend on 127.0.0.1:9102 (fallback)."""
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

AGENT = "agent-b"

AGENT_CARD = json.dumps({
    "name": AGENT,
    "url": f"http://127.0.0.1:9102/a2a/",
    "version": "1.0",
    "capabilities": {},
    "skills": [],
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
        task_id = req.get("params", {}).get("id", "")

        body = json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "handled_by": AGENT,
                "id": task_id,
                "method_received": method,
                "status": {"state": "TASK_STATE_COMPLETED"},
            },
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 9102), Handler)
    print(f"agent-b listening on 127.0.0.1:9102", flush=True)
    server.serve_forever()
