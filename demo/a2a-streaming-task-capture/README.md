# A2A Streaming Task Capture Demo

Manual validation for A2A streaming task-route capture from
`SendStreamingMessage` SSE responses
([praxis-proxy/praxis#347](https://github.com/praxis-proxy/praxis/issues/347)).

Proves that Praxis captures task IDs from streaming SSE
events (including `Task`, `statusUpdate`, and `artifactUpdate`
shapes from A2A v1.0) and routes follow-up `GetTask` requests
back to the owning backend cluster.

## Prerequisites

- Rust toolchain (stable 1.94+)
- Python 3
- Praxis repo checked out with the `a2a-streaming-task-capture`
  branch (or equivalent)

## Ports

| Service  | Port |
| -------- | ---- |
| Praxis   | 8088 |
| agent-a  | 9101 |
| agent-b  | 9102 |

## Setup

### Terminal 1 -- agent-a

```console
python3 demo/a2a-streaming-task-capture/a2a-streaming-agent-a.py
```

Handles `SendStreamingMessage` by returning a `text/event-stream`
with four A2A v1.0 spec-shaped events:
1. `result.task` (initial Task, SUBMITTED)
2. `result.artifactUpdate` (TaskArtifactUpdateEvent)
3. `result.statusUpdate` (TaskStatusUpdateEvent, WORKING)
4. `result.statusUpdate` (TaskStatusUpdateEvent, COMPLETED / terminal)

Handles `GetTask` by returning `{"handled_by": "agent-a", ...}`.

### Terminal 2 -- agent-b (fallback)

```console
python3 demo/a2a-streaming-task-capture/a2a-streaming-agent-b.py
```

Returns `{"handled_by": "agent-b", ...}` for any request.

### Terminal 3 -- Praxis

Build and run from the praxis repo root:

```console
cargo build -p praxis
./target/debug/praxis -c <path-to-spike-repo>/demo/a2a-streaming-task-capture/a2a-streaming-demo.yaml
```

Or with debug tracing for the A2A filter:

```console
RUST_LOG=praxis_filter::builtins::http::ai::agentic::a2a=debug \
  ./target/debug/praxis -c <path-to-spike-repo>/demo/a2a-streaming-task-capture/a2a-streaming-demo.yaml
```

Wait ~3 seconds for the config file watcher to stabilize before
sending requests.

## Curl Commands

### 1. SendStreamingMessage routed to agent-a

```console
curl -s -D- -X POST http://127.0.0.1:8088/a2a/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"SendStreamingMessage","params":{"message":{"role":"user","parts":[{"text":"hello"}]}}}' \
  --max-time 5
```

Expected: HTTP 200 with `Content-Type: text/event-stream`.
Body contains four SSE data frames with the deterministic task
ID `task-live-stream-a` across all four A2A streaming event shapes.

Praxis captures `task-live-stream-a -> agent-a` in the local
task route store from the SSE data frames.

### 2. GetTask routes back to agent-a

```console
curl -s -X POST http://127.0.0.1:8088/a2a/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"GetTask","params":{"id":"task-live-stream-a"}}'
```

Expected: response from agent-a (not agent-b) with
`"handled_by": "agent-a"`.

### 3. Unknown task falls through to agent-b

```console
curl -s -X POST http://127.0.0.1:8088/a2a/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"GetTask","params":{"id":"unknown-task-xyz"}}'
```

Expected: response from agent-b (fallback) with
`"handled_by": "agent-b"`.

## Cleanup

Kill the three processes (Ctrl-C in each terminal), or:

```console
pkill -f a2a-streaming-agent
pkill -f "praxis.*a2a-streaming-demo"
```

## What This Proves

1. **SSE task capture**: `SendStreamingMessage` SSE responses
   with A2A v1.0 streaming event shapes (`result.task`,
   `result.statusUpdate`, `result.artifactUpdate`) create
   a `task_id -> cluster` mapping in the local store.
2. **Task routing**: Follow-up `GetTask` for a known task ID
   routes to the cluster that created the task via SSE, not
   the fallback.
3. **Byte-for-byte passthrough**: The SSE response body
   passes through Praxis unchanged to the client.
4. **Fallback**: Unknown task IDs follow the static router
   fallback route.
5. **All four A2A StreamResponse shapes**: The SSE stream
   exercises `Task`, `TaskStatusUpdateEvent` (working),
   `TaskArtifactUpdateEvent`, and `TaskStatusUpdateEvent`
   (terminal/completed).
