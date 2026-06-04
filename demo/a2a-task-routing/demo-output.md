# A2A Task Routing Demo Output

Captured from a live run against Praxis on branch
`feat/a2a-local-task-routing` with two mock A2A agents.

Setup:
- agent-a on `:9101` (returns task `task-demo-123` for `SendMessage`)
- agent-b on `:9102` (fallback, returns `"fallback agent-b handled <method>"`)
- Praxis on `:8090` with `task_routing.enabled: true`

---

## Step 1: SendMessage routed to agent-a

The initial `SendMessage` is routed to agent-a by the static
router rule matching `x-praxis-a2a-method: SendMessage`.
Praxis parses the JSON response body and stores
`task-demo-123 -> agent-a` in the local task route store.

```console
$ curl -s http://127.0.0.1:8090/ -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":"Hello agent"}}' | python3 -m json.tool
{
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "task": {
            "id": "task-demo-123",
            "contextId": "ctx-demo-1",
            "status": {
                "state": "TASK_STATE_WORKING"
            },
            "artifacts": []
        }
    }
}
```

## Step 2: GetTask routes back to agent-a by stored task ownership

The follow-up `GetTask` carries `params.id: "task-demo-123"`.
Praxis looks up that task ID in the local store, finds
`agent-a`, and injects `x-praxis-a2a-route-cluster: agent-a`
as an internal header. The router matches that header and
selects the `agent-a` cluster. The response comes from
agent-a, not the fallback.

```console
$ curl -s http://127.0.0.1:8090/ -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":2,"method":"GetTask","params":{"id":"task-demo-123"}}' | python3 -m json.tool
{
    "jsonrpc": "2.0",
    "id": 2,
    "result": {
        "task": {
            "id": "task-demo-123",
            "contextId": "ctx-demo-1",
            "status": {
                "state": "TASK_STATE_COMPLETED"
            },
            "artifacts": [
                {
                    "parts": [
                        {
                            "text": "result from agent-a"
                        }
                    ]
                }
            ]
        }
    }
}
```

## Step 3: Unknown task falls through to agent-b

`GetTask` for `unknown-task` has no entry in the local store.
No route header is injected, so the router falls through to
the default route which selects the `agent-b` cluster.

```console
$ curl -s http://127.0.0.1:8090/ -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":3,"method":"GetTask","params":{"id":"unknown-task"}}' | python3 -m json.tool
{
    "jsonrpc": "2.0",
    "id": 3,
    "result": {
        "message": {
            "role": "ROLE_AGENT",
            "parts": [
                {
                    "text": "fallback agent-b handled GetTask"
                }
            ]
        }
    }
}
```

## Step 4: Client-spoofed route header is rejected

A client attempts to inject `x-praxis-a2a-route-cluster: agent-a`
directly. The protocol layer's reserved-header rejection guard
detects the `x-praxis-` prefix and returns HTTP 400 before the
request reaches the filter pipeline. The client cannot influence
task routing by spoofing internal headers.

```console
$ curl -s -o /dev/null -w "HTTP status: %{http_code}\n" http://127.0.0.1:8090/ -X POST \
    -H "Content-Type: application/json" \
    -H "x-praxis-a2a-route-cluster: agent-a" \
    -d '{"jsonrpc":"2.0","id":4,"method":"GetTask","params":{"id":"unknown-task"}}'
HTTP status: 400
```
