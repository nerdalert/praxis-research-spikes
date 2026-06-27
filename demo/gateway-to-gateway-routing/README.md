# Gateway-to-gateway routing E2E spike

## Purpose

Validate the end-to-end architecture for
[praxis-proxy/praxis#664](https://github.com/praxis-proxy/praxis/issues/664)
before splitting the work into individual upstream Praxis PRs.

This is a spike and demo workspace. It is allowed to prove the full path first,
then extract clean PR-sized upstream changes after the behavior is understood.

## Plain-language summary

This demo proves that one Praxis gateway can safely send a request to another
Praxis gateway. The first gateway chooses a local or remote capability. The
remote gateway proves who it is with mutual TLS, validates the request came from
a trusted peer, then forwards to its own local backend.

## What the E2E proves

| Proof point | Evidence |
| --- | --- |
| Local inference route | `local-model` request to site A reaches site A mock. |
| Remote inference route | `site-b-model` and `site-c-model` requests cross mTLS to remote gateways. |
| Gateway mTLS | Direct calls to grid listeners without client certs fail at TLS layer. |
| Peer identity trust | `grid_ingress_trust` rejects CA-valid certs with wrong organization. |
| Unknown CA rejection | Client cert from a different CA is rejected at mTLS layer. |
| Header spoofing protection | Public `x-praxis-*` headers rejected with 400 before filters. |
| Capability matching | `grid_route` matches model name and MCP tool name from request metadata. |
| Freshness scoring | Fresh remote candidate beats stale remote candidate. |
| Local preference scoring | Local candidate wins when scores are otherwise equal. |
| MCP tool route | JSON-RPC `tools/call` for `weather-lookup` crosses gateway boundary. |
| Safe metadata | Route decisions logged with bounded keys/values; no prompts or secrets. |

## Non-goals

- No global membership, SWIM, gossip, CRDT replication, or operator behavior.
- No external provider fallback or credential sharing.
- No production policy engine or llm-d worker scheduling.
- No A2A routing (deferred).
- No claim that POC code is PR-ready.

## Prerequisites

- Praxis binary built from the POC branch: `nerdalert/praxis@praxis-multi-cluster-poc-v1`
- `openssl`, `python3`, `curl`

This demo expects a Praxis binary built from the POC branch. This is a **demo/validation branch only** — not an upstream PR.

## Build the POC binary

```console
# Clone the POC branch
git clone https://github.com/nerdalert/praxis.git
cd praxis
git switch praxis-multi-cluster-poc-v1
cargo build -p praxis --bin praxis

# Run demo with the POC binary
cd ../praxis-research-spikes/demo/gateway-to-gateway-routing
PRAXIS_BIN=../../../praxis/target/debug/praxis bash scripts/run-demo.sh
```

**Alternative:** If you have the Praxis POC binary built elsewhere, set `PRAXIS_BIN` to point to it:

```console
PRAXIS_BIN=/path/to/your/praxis bash scripts/run-demo.sh
```

The demo package itself uses relative paths where possible and is portable across local checkout structures.

## Running the demo

```console
# Navigate to the demo directory (adjust path if needed)
cd praxis-research-spikes/demo/gateway-to-gateway-routing

# Check prerequisites
bash scripts/check-prereqs.sh

# Generate certificates (idempotent — delete certs/ to regenerate)
bash scripts/generate-certs.sh

# Run the full demo (starts mocks, gateways, assertions, cleanup)
bash scripts/run-demo.sh

# Manual cleanup if needed
bash scripts/cleanup.sh
```

Override the binary location:

```console
PRAXIS_BIN=/path/to/praxis bash scripts/run-demo.sh
```

## Demo narrative

Use [demo-narrative.md](demo-narrative.md) as the presenter script. It explains
the architecture in plain language, walks through each assertion group, calls
out what the demo proves, and lists what should not be claimed yet.

Workflow rule: do not commit, push, or open upstream Praxis PRs from this work
until the spike demo evidence and narrative have been reviewed and explicitly
accepted.

## Process topology

```text
                       ┌─ mock-inference-a :18001 ─┐
client ──> site-a      │                            │
           :18100 pub  ├─ mock-mcp-a      :18002 ──┤  site-a backends
           :18101 grid │                            │
                       └─ mock-a2a-a      :18003 ──┘

           site-b      ┌─ mock-inference-b :18011 ─┐
           :18110 grid ├─ mock-mcp-b      :18012 ──┤  site-b backends
                       └─ mock-a2a-b      :18013 ──┘

           site-c      ┌─ mock-inference-c :18021 ─┐
           :18120 grid ├─ mock-mcp-c      :18022 ──┤  site-c backends
                       └─ mock-a2a-c      :18023 ──┘
```

All processes bind `127.0.0.1`. Site A has a public listener (plain HTTP) and
a grid listener (mTLS). Sites B and C have grid listeners only.

## Upstream PR stack

See [pr-extraction-map.md](pr-extraction-map.md) for the complete extraction
plan. Production prompts for each upstream PR are in
[claude-code-prompts.md](claude-code-prompts.md).

| Target | Status |
| --- | --- |
| G2G-01 peer identity | Validated (E2E-02) |
| G2G-02 ingress trust | Validated (E2E-02) |
| G2G-03 site descriptor | Validated (E2E-03) |
| G2G-04 route filter | Validated (E2E-03) |
| G2G-05 forwarding metadata | Partially validated (E2E-03, metadata only) |
| G2G-06 scoring/freshness | Validated (E2E-04) |
| G2G-07 MCP routing | Validated (E2E-04, MCP only; A2A deferred) |
| G2G-08 examples and docs | Planned; prompt ready (E2E-05) |

## Files in this directory

| File | Purpose |
| --- | --- |
| [README.md](README.md) | This file — run instructions and E2E overview. |
| [architecture.md](architecture.md) | E2E topology, trust boundaries, and route scenarios. |
| [implementation-notes.md](implementation-notes.md) | Detailed implementation notes and E2E results by task. |
| [demo-narrative.md](demo-narrative.md) | Presenter script and plain-language demo walkthrough. |
| [pr-extraction-map.md](pr-extraction-map.md) | Upstream PR split with evidence references. |
| [pr-stack-documentation-plan.md](pr-stack-documentation-plan.md) | Documentation contract between Claude and Codex. |
| [claude-code-prompts.md](claude-code-prompts.md) | E2E task prompts and validated production prompts. |
| [sample-output.md](sample-output.md) | Sanitized demo output. |
| `configs/` | Praxis YAML configs for three gateways. |
| `scripts/` | Demo lifecycle scripts. |
| `mocks/` | Python mock backends for inference, MCP, and A2A. |
| `.gitignore` | Excludes `certs/`, `.pids/`, `.logs/`. |
