# A2A Task Routing Demo

Manual validation for local A2A task-ownership routing
([praxis-proxy/praxis#347](https://github.com/praxis-proxy/praxis/issues/347)).

Proves that Praxis captures task IDs from `SendMessage` JSON
responses and routes follow-up task operations back to the
owning backend cluster.

## Prerequisites

- Rust toolchain (stable 1.94+)
- Python 3
- Praxis repo checked out with the `feat/a2a-local-task-routing`
  branch (or equivalent)

## Ports

| Service  | Port |
| -------- | ---- |
| Praxis   | 8090 |
| agent-a  | 9101 |
| agent-b  | 9102 |

## Setup

### Terminal 1 -- agent-a

```console
python3 demo/a2a-task-routing/a2a-task-routing-agent-a.py
```

Returns a task with `id: task-demo-123` for `SendMessage`,
and a recognizable completed-task body for
`GetTask task-demo-123`.

### Terminal 2 -- agent-b (fallback)

```console
python3 demo/a2a-task-routing/a2a-task-routing-agent-b.py
```

Returns `"fallback agent-b handled <method>"` for any request.

### Terminal 3 -- Praxis

Build and run from the praxis repo root:

```console
cargo build -p praxis
./target/debug/praxis -c <path-to-spike-repo>/demo/a2a-task-routing/a2a-task-routing-demo.yaml
```

Or with debug tracing for the A2A filter:

```console
RUST_LOG=praxis_filter::builtins::http::ai::agentic::a2a=debug \
  ./target/debug/praxis -c <path-to-spike-repo>/demo/a2a-task-routing/a2a-task-routing-demo.yaml
```

## Curl Commands

### 1. SendMessage routed to agent-a

```console
curl -s http://127.0.0.1:8090/ -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":"Hello agent"}}'
```

Expected: response from agent-a containing
`"id": "task-demo-123"` and `"state": "TASK_STATE_WORKING"`.

```json
{
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "task": {
            "id": "task-demo-123",
            "contextId": "ctx-demo-1",
            "status": { "state": "TASK_STATE_WORKING" },
            "artifacts": []
        }
    }
}
```

Praxis captures `task-demo-123 -> agent-a` in the local
task route store.

### 2. GetTask routes back to agent-a

```console
curl -s http://127.0.0.1:8090/ -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"GetTask","params":{"id":"task-demo-123"}}'
```

Expected: response from agent-a (not agent-b) with
`"state": "TASK_STATE_COMPLETED"` and
`"text": "result from agent-a"`.

```json
{
    "jsonrpc": "2.0",
    "id": 2,
    "result": {
        "task": {
            "id": "task-demo-123",
            "contextId": "ctx-demo-1",
            "status": { "state": "TASK_STATE_COMPLETED" },
            "artifacts": [{ "parts": [{ "text": "result from agent-a" }] }]
        }
    }
}
```

### 3. Unknown task falls through to agent-b

```console
curl -s http://127.0.0.1:8090/ -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"GetTask","params":{"id":"unknown-task"}}'
```

Expected: response from agent-b (fallback) with
`"fallback agent-b handled GetTask"`.

```json
{
    "jsonrpc": "2.0",
    "id": 3,
    "result": {
        "message": {
            "role": "ROLE_AGENT",
            "parts": [{ "text": "fallback agent-b handled GetTask" }]
        }
    }
}
```

### 4. Client spoofing is rejected

```console
curl -s -o /dev/null -w "HTTP status: %{http_code}\n" http://127.0.0.1:8090/ -X POST \
  -H "Content-Type: application/json" \
  -H "x-praxis-a2a-route-cluster: agent-a" \
  -d '{"jsonrpc":"2.0","id":4,"method":"GetTask","params":{"id":"unknown-task"}}'
```

Expected: `HTTP status: 400`. The reserved-header rejection
guard rejects the request before it reaches the filter
pipeline.

### 5. SSE pass-through (out of scope)

SSE response capture is a follow-up. `SendStreamingMessage`
and `SubscribeToTask` SSE responses pass through unchanged;
no task route is captured from streaming responses in this
implementation.

## Cleanup

Kill the three processes (Ctrl-C in each terminal), or:

```console
pkill -f a2a-task-routing-agent
pkill -f "praxis.*a2a-task-routing-demo"
```

## What This Proves

1. **Task capture**: `SendMessage` JSON responses create a
   `task_id -> cluster` mapping in the local store.
2. **Task routing**: Follow-up `GetTask` for a known task ID
   routes to the cluster that created the task, not the
   fallback.
3. **Fallback**: Unknown task IDs follow the static router
   fallback route.
4. **Spoofing prevention**: Clients cannot inject the
   reserved `x-praxis-a2a-route-cluster` header to
   influence routing.
5. **Pipeline preservation**: The existing
   `a2a -> router -> load_balancer` pipeline shape is
   preserved; task routing uses an internal route header
   rather than setting `ctx.cluster` directly.
