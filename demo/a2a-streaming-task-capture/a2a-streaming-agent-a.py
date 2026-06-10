"""Deterministic A2A agent-a backend on 127.0.0.1:9101.

Uses the official a2a-sdk protobuf types and the same camelCase
serialization path the SDK's JSON-RPC transport uses, so the SSE
payloads are wire-format conformant with the A2A v1.0 spec.

Requires: pip install a2a-sdk
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

from a2a.types.a2a_pb2 import (
    Artifact,
    Part,
    StreamResponse,
    Task,
    TaskArtifactUpdateEvent,
    TaskStatus,
    TaskStatusUpdateEvent,
    TASK_STATE_COMPLETED,
    TASK_STATE_SUBMITTED,
    TASK_STATE_WORKING,
)
from a2a.utils.proto_utils import to_stream_response
from google.protobuf.json_format import MessageToDict

TASK_ID = "task-live-stream-a"
CONTEXT_ID = "ctx-live-1"
AGENT = "agent-a"


def build_sse_events() -> list[StreamResponse]:
    """Build spec-shaped A2A v1.0 streaming events using SDK types."""
    return [
        to_stream_response(
            Task(
                id=TASK_ID,
                context_id=CONTEXT_ID,
                status=TaskStatus(state=TASK_STATE_SUBMITTED),
            )
        ),
        to_stream_response(
            TaskArtifactUpdateEvent(
                task_id=TASK_ID,
                context_id=CONTEXT_ID,
                artifact=Artifact(
                    artifact_id="art-1",
                    parts=[Part(text="Hello from agent-a")],
                ),
            )
        ),
        to_stream_response(
            TaskStatusUpdateEvent(
                task_id=TASK_ID,
                context_id=CONTEXT_ID,
                status=TaskStatus(state=TASK_STATE_WORKING),
            )
        ),
        to_stream_response(
            TaskStatusUpdateEvent(
                task_id=TASK_ID,
                context_id=CONTEXT_ID,
                status=TaskStatus(state=TASK_STATE_COMPLETED),
            )
        ),
    ]


def stream_response_to_jsonrpc(sr: StreamResponse, req_id: int) -> str:
    """Serialize a StreamResponse the same way the SDK's JSON-RPC transport does."""
    result = MessageToDict(sr, preserving_proto_field_name=False)
    return json.dumps(
        {"jsonrpc": "2.0", "id": req_id, "result": result},
        ensure_ascii=False,
    )


SSE_EVENTS = build_sse_events()

AGENT_CARD = json.dumps({
    "name": AGENT,
    "url": "http://127.0.0.1:9101/a2a/",
    "version": "1.0",
    "capabilities": {"streaming": True},
    "skills": [{"id": "echo", "name": "Echo"}],
})


class Handler(BaseHTTPRequestHandler):
    """Handles A2A JSON-RPC requests."""

    def do_GET(self):
        """Serve the agent card."""
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
        """Handle A2A JSON-RPC methods."""
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
                line = stream_response_to_jsonrpc(event, req_id)
                self.wfile.write(f"data: {line}\n\n".encode())
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
        """Suppress request logging."""


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 9101), Handler)
    print("agent-a listening on 127.0.0.1:9101", flush=True)
    server.serve_forever()
