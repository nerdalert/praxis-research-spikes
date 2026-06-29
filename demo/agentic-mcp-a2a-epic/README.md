# Praxis MCP/A2A Agentic Epic

Epic: [praxis-proxy/praxis#24](https://github.com/praxis-proxy/praxis/issues/24)

## Overview

This epic adds protocol-aware MCP and A2A support to Praxis.
The work is split into small PRs covering parser reuse, header
safety, protocol classification, broker behavior, stateless MCP
profile support, A2A task-ownership routing, and future external
state. Normal proxy pass-through mode is preserved throughout.

MCP (Model Context Protocol) support turns Praxis into a gateway
that understands tool catalogs, method routing, and protocol
versioning. A2A (Agent-to-Agent) support adds task-ownership
tracking so follow-up operations route to the backend that
created the task.

Both protocols sit on top of JSON-RPC 2.0 over HTTP. The shared
parser and durable metadata infrastructure are built first, then
each protocol builds its own classifier, routing, and state
layer.

## PR Stack

| # | Name | Outcome | Status |
|---|------|---------|--------|
| 1 | `agentic-foundation` | Reusable `pub(crate)` JSON-RPC parser, durable `filter_metadata` bag | Merged as [PR #101](https://github.com/praxis-proxy/praxis/pull/101) |
| 2 | `agentic-safety` | Reserved internal-header hygiene (`x-praxis-*`/`x-mcp-*`/`x-a2a-*`), StreamBuffer >64 KiB regression | Complete before PR #353 |
| 3 | `mcp-classifier` | MCP method/name/session extraction, `Mcp-Method`/`Mcp-Name` header/body validation (`-32001`) | Complete before PR #353 |
| 4 | `mcp-static-broker` | Pipeline/StreamBuffer infrastructure, static configured catalog, broker responses | Implemented in [PR #353](https://github.com/praxis-proxy/praxis/pull/353) |
| 5 | `mcp-profile-plumbing` | MCP protocol profile/version config fields; no behavior change | Complete in latest mainline |
| 6 | `a2a-classifier` | A2A v1.0 PascalCase method classification, v0.3 alias config, task ID extraction, SSE pass-through | Complete in latest mainline |
| 7 | `a2a-task-routing` | Local task route capture from non-streaming `SendMessage` JSON responses | Merged in [PR #480](https://github.com/praxis-proxy/praxis/pull/480) |
| 8 | `mcp-version-promotion` | Promote MCP protocol version consistently in classifier mode | Merged |
| 9 | `a2a-streaming-task-capture` | Capture task IDs from `SendStreamingMessage`/`SubscribeToTask` SSE responses | Complete in [PR #538](https://github.com/praxis-proxy/praxis/pull/538) |
| 10 | `mcp-stateless-profile-2026-07-28` | Configurable 2026-07-28 MCP RC stateless profile; preserves current defaults | Implemented in [PR #706](https://github.com/praxis-proxy/praxis/pull/706); waiting on merge |
| 11 | `mcp-tools-call-routing` | Stateless `tools/call` routing: catalog lookup, cluster selection, path rewrite, prefix stripping, multi-backend proof | Implemented locally; ready to push after PR #706 merges |
| 12 | `agentic-state-redis` | Redis/Valkey state for A2A multi-replica task routing | Deferred |
| 13 | `mcp-legacy-session-compat` | Optional legacy Streamable HTTP session behavior | Deferred (compatibility only) |
| 14 | `mcp-advanced-parity` | Dynamic catalog, virtual tools, tool annotations, subscriptions/SSE, conformance | Not started |
| A | `a2a-agent-card-routing-example` | Example config + tests for `/.well-known/agent-card.json` discovery | Optional parallel PR |

## Dependency Graph

```text
            PR 1: Parser + Metadata (#101)
                      |
            PR 2: Header Hygiene + StreamBuffer Regression
                 /                              \
                /                                \
  PR 3: MCP Classifier                  PR 6: A2A Classifier
       |                                        |
  PR 4: MCP Static Broker (#353)                |
       |                                        |
  PR 5: MCP Profile Plumbing                    |
       |                                        |
  PR 8: MCP Version Promotion                   |
       |                                        |
  PR 10: Stateless Profile 2026-07-28    PR 7: A2A Task Routing (#480)
       |                                        |
  PR 11: tools/call Routing              PR 9: SSE Task Capture (#538)
                                                |
                                         PR 12: Redis/Valkey State

  PR 13: Legacy MCP Sessions — optional, separate from both lanes.
  PR 14: Advanced MCP Parity — depends on PR 10/11.
  PR A:  A2A Agent Card Example — independent of task routing.
```

MCP and A2A share the foundation (PRs 1-2) then diverge into
independent lanes. The MCP lane builds toward a full stateless
gateway. The A2A lane builds toward task-ownership routing with
eventual external state for multi-replica deployments.

## Technical Capability Summary

### MCP Classifier (PRs 3, 8)

Extracts protocol metadata from JSON-RPC request bodies and
promotes it to internal headers and durable metadata:

- `mcp.method` — JSON-RPC method (`tools/call`, `tools/list`, etc.)
- `mcp.name` — tool/resource/prompt name from `params.name` or `params.uri`
- `mcp.protocol_version` — from `MCP-Protocol-Version` header or `initialize` body
- `mcp.session_id` — from `MCP-Session-Id` header (presence only, not raw value)

Validates `Mcp-Method` and `Mcp-Name` headers against the body
per the MCP transport spec. Mismatches return HTTP 400 with
JSON-RPC error code `-32001` (`HeaderMismatch`).

### MCP Static Broker (PR 4)

Adds configured catalog behavior under the `mcp` filter with
a `servers:` config block:

- `initialize` — returns gateway capabilities and protocol version
- `notifications/initialized` — accepted with HTTP 202
- `tools/list` — returns aggregated prefixed tools from configured servers
- `ping` — responds with JSON-RPC success
- Unsupported methods — controlled `-32601` response
- StreamBuffer body mutation infrastructure for prefix stripping

### MCP Stateless Profile (PR 10)

Adds the `2026-07-28` MCP release-candidate stateless profile
as an explicit configuration option:

- `server/discover` — returns supported versions, capabilities, and server info
- Cacheable `tools/list` with `ttlMs` and `cacheScope` metadata
- Required stateless headers: `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`
- No `initialize`/`MCP-Session-Id` handshake in stateless mode
- Current-profile behavior preserved as the default

### MCP tools/call Routing (PR 11)

Completes the stateless MCP gateway path:

- Looks up the exposed tool name in the configured catalog
- Selects the backend cluster that owns the tool
- Rewrites the request path to the backend's configured MCP path
- Strips the tool prefix from `params.name` before forwarding
- Updates the forwarded `Mcp-Name` header to the backend tool name
- Repairs `Content-Length` after body mutation
- Multi-backend integration test proves correct tool-to-cluster routing

### A2A Classifier (PR 6)

Extracts A2A protocol metadata from JSON-RPC request bodies:

- Method classification using v1.0 PascalCase names (`SendMessage`,
  `SendStreamingMessage`, `GetTask`, `CancelTask`, `SubscribeToTask`, etc.)
- Optional v0.3 slash-delimited aliases via `method_aliases` config
- Task ID extraction from `params.id` and `params.taskId`
- `A2A-Version` header preservation
- Streaming method detection for SSE pass-through

### A2A Task Routing (PRs 7, 9)

Captures task ownership from response bodies and routes
follow-up operations to the backend that created the task:

**Non-streaming capture (PR 7):**
- Parses `SendMessage` JSON responses for task IDs
- Supports `result.task.id` and direct `result.id` + `result.status` shapes
- Stores task → cluster mappings in a local in-process store
- Routes `GetTask`, `CancelTask`, `SubscribeToTask`, and push-notification
  config methods by stored task ownership
- Terminal task states use configurable TTL/immediate removal

**Streaming capture (PR 9):**
- Parses `SendStreamingMessage` and `SubscribeToTask` SSE responses
- Handles all A2A v1.0 `StreamResponse` shapes: `task`, `statusUpdate`,
  `artifactUpdate` (the `message` shape carries no task ownership)
- Bounded incremental SSE scanner handles arbitrary chunk boundaries,
  multi-line `data:` fields, CRLF/LF/CR, and comment lines
- Response bytes pass through the proxy unchanged
- Overflow clears capture state without failing the proxy
- Completed payloads before an overflow are preserved and stored

## What Is Intentionally Deferred

| Area | Why deferred |
|------|-------------|
| Redis/Valkey shared state (PR 12) | A2A task routing works locally. External state is needed only for multi-replica correctness. |
| Legacy MCP session compatibility (PR 13) | The MCP RC removes protocol-level sessions. Legacy session support is optional compatibility work. |
| MCP dynamic discovery/catalog refresh (PR 14) | Static catalog is sufficient for current use and makes tests deterministic. |
| MCP subscriptions/SSE/conformance (PR 14) | Depends on finalized MCP spec and stateless profile. |
| MCP tool annotations, virtual tools (PR 14) | Later parity features after core routing is complete. |

## How to Read This Stack

**MCP operating modes are additive, not replacing:**
Current MCP behavior (pass-through, classifier, broker with
`initialize`/`tools/list`) is preserved by default. The
`2026-07-28` stateless profile is opt-in via configuration.
Operators choose which profile to expose.

**A2A task routing is local/in-process:**
Task → cluster mappings live in a `RwLock<HashMap>` inside
the `A2aFilter` instance. This works for single-replica
deployments. Multi-replica correctness requires Redis/Valkey
state (PR 12), which is not yet implemented.

**Normal proxy mode is always available:**
Listeners without `mcp` or `a2a` filters continue to work
as standard HTTP reverse proxies. The agentic filters are
opt-in per filter chain.

## Related Resources

- Planning doc: `~/praxxis/agentic/praxis-mcp-a2a-implementation-plan.md`
- A2A task routing demo: `demo/a2a-task-routing/`
- A2A streaming task capture demo: `demo/a2a-streaming-task-capture/`
- Epic issue: [praxis-proxy/praxis#24](https://github.com/praxis-proxy/praxis/issues/24)
- MCP spec: [modelcontextprotocol.io](https://modelcontextprotocol.io/specification/draft/basic/transports)
- A2A v1.0 spec: [a2a-protocol.org](https://a2a-protocol.org/latest/specification/)
