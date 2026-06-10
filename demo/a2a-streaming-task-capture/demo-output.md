# A2A Streaming Task Capture — Demo Output

Captured 2026-06-09. All three processes on localhost.

## Process Ports

| Service  | Port | PID scope |
| -------- | ---- | --------- |
| agent-a  | 9101 | Python    |
| agent-b  | 9102 | Python    |
| Praxis   | 8088 | Rust      |

## Step 1: SendStreamingMessage

```console
$ curl -s -D- -X POST http://127.0.0.1:8088/a2a/ \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"SendStreamingMessage","params":{"message":{"role":"user","parts":[{"text":"hello"}]}}}' \
    --max-time 5
```

### Response Headers

```
HTTP/1.1 200 OK
Server: BaseHTTP/0.6 Python/3.12.3
Date: Tue, 09 Jun 2026 23:58:46 GMT
Content-Type: text/event-stream
Cache-Control: no-cache
via: 1.1 praxis
Connection: keep-alive
```

### Response Body

```
data: {"jsonrpc": "2.0", "id": 1, "result": {"task": {"id": "task-live-stream-a", "contextId": "ctx-live-1", "status": {"state": "TASK_STATE_SUBMITTED"}}}}

data: {"jsonrpc": "2.0", "id": 1, "result": {"artifactUpdate": {"taskId": "task-live-stream-a", "contextId": "ctx-live-1", "artifact": {"artifactId": "art-1", "parts": [{"text": "Hello from agent-a"}]}}}}

data: {"jsonrpc": "2.0", "id": 1, "result": {"statusUpdate": {"taskId": "task-live-stream-a", "contextId": "ctx-live-1", "status": {"state": "TASK_STATE_WORKING"}}}}

data: {"jsonrpc": "2.0", "id": 1, "result": {"statusUpdate": {"taskId": "task-live-stream-a", "contextId": "ctx-live-1", "status": {"state": "TASK_STATE_COMPLETED"}}}}
```

All four A2A v1.0 StreamResponse shapes present:
1. `result.task` — initial Task (SUBMITTED)
2. `result.artifactUpdate` — TaskArtifactUpdateEvent
3. `result.statusUpdate` — TaskStatusUpdateEvent (WORKING)
4. `result.statusUpdate` — TaskStatusUpdateEvent (COMPLETED, terminal)

## Step 2: GetTask for Streamed Task

```console
$ curl -s -X POST http://127.0.0.1:8088/a2a/ \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":2,"method":"GetTask","params":{"id":"task-live-stream-a"}}'
```

### Result

```json
{
    "jsonrpc": "2.0",
    "id": 2,
    "result": {
        "handled_by": "agent-a",
        "id": "task-live-stream-a",
        "status": {
            "state": "TASK_STATE_COMPLETED"
        }
    }
}
```

**PASS**: `handled_by: agent-a`. GetTask routed to the backend
that created the task via SSE streaming, not the fallback.

## Step 3: Unknown Task (Negative Control)

```console
$ curl -s -X POST http://127.0.0.1:8088/a2a/ \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":3,"method":"GetTask","params":{"id":"unknown-task-xyz"}}'
```

### Result

```json
{
    "jsonrpc": "2.0",
    "id": 3,
    "result": {
        "handled_by": "agent-b",
        "id": "unknown-task-xyz",
        "method_received": "GetTask",
        "status": {
            "state": "TASK_STATE_COMPLETED"
        }
    }
}
```

**PASS**: `handled_by: agent-b`. Unknown task followed the
static fallback route to agent-b.

## Praxis Route Logs

```
DEBUG praxis_filter::builtins::http::ai::agentic::a2a: stored task route from response has_task_id=true task_id_len=18 cluster=agent-a terminal=false
DEBUG praxis_filter::builtins::http::ai::agentic::a2a: stored task route from response has_task_id=true task_id_len=18 cluster=agent-a terminal=false
DEBUG praxis_filter::builtins::http::ai::agentic::a2a: stored task route from response has_task_id=true task_id_len=18 cluster=agent-a terminal=false
DEBUG praxis_filter::builtins::http::ai::agentic::a2a: stored task route from response has_task_id=true task_id_len=18 cluster=agent-a terminal=true
DEBUG praxis_filter::builtins::http::ai::agentic::a2a: task route lookup hit has_task_id=true task_id_len=18 lookup_hit=true cluster=agent-a method="GetTask"
DEBUG praxis_filter::builtins::http::ai::agentic::a2a: task route lookup miss has_task_id=true task_id_len=16 lookup_hit=false method="GetTask"
```

Four store operations (one per SSE event), then a hit for the
known task and a miss for the unknown task.

## Automated Test Results

```
cargo test -p praxis-proxy-filter a2a
  133 passed; 0 failed

cargo test -p praxis-tests-integration --test suite a2a
  46 passed; 0 failed

cargo clippy --workspace --all-targets -- -D warnings
  0 errors

cargo +nightly fmt --all --check
  0 diffs
```
