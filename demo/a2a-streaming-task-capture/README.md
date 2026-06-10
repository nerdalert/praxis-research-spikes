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
- Python 3 with `a2a-sdk` (`pip install a2a-sdk`)
- Praxis repo checked out with the `a2a-streaming-task-capture`
  branch (or equivalent)

The agent-a backend uses the official `a2a-sdk` protobuf types
and the same camelCase serialization the SDK's JSON-RPC transport
uses, so SSE payloads are wire-format conformant with the A2A v1.0
spec rather than hand-crafted JSON.

## Basic Flow

This demo shows Praxis learning task ownership from a streaming
A2A response:

1. A client sends `SendStreamingMessage` to Praxis.
2. Praxis routes the first request to `agent-a`.
3. `agent-a` streams A2A v1.0 SSE events containing
   `task-live-stream-a`.
4. Praxis passes the stream through unchanged and remembers
   `task-live-stream-a -> agent-a`.
5. The client later sends `GetTask(task-live-stream-a)`.
6. Praxis routes that follow-up request back to `agent-a` instead
   of the default fallback backend.

An unknown task ID still falls through to `agent-b`, which proves
the known task was routed by the captured task ownership and not by
the static fallback.

## Capabilities Covered

- Uses the official `a2a-sdk` types for the streaming response
  payloads instead of hand-written event JSON.
- Exercises the A2A v1.0 stream result shapes that can teach Praxis
  task ownership: `task`, `statusUpdate`, and `artifactUpdate`.
  `message` stream payloads do not carry a task route and are covered
  by the PR's pass-through tests.
- Proves Praxis can inspect SSE `data:` frames without changing the
  bytes returned to the client.
- Proves local task ownership routing for follow-up `GetTask`
  requests.
- Keeps the demo intentionally small. It is not a full A2A
  conformance suite, and it does not test Redis/Valkey
  multi-replica routing.

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
ID `task-live-stream-a` across `task`, `artifactUpdate`, and
`statusUpdate` streaming event shapes.

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
5. **A2A route-bearing stream shapes**: The SSE stream
   exercises `Task`, `TaskArtifactUpdateEvent`,
   `TaskStatusUpdateEvent` (working), and
   `TaskStatusUpdateEvent` (terminal/completed). `Message`
   stream payloads are pass-through-only for this routing feature.
