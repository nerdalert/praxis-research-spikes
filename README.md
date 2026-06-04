# Praxis Research Spikes

This repository collects research spikes for Praxis.

## Spikes

| Spike | Description |
| --- | --- |
| [Stateful Proxy Analysis](stateful-proxy/) | Research and proposal material for Praxis state management across request metadata, local runtime state, shared hot-path state, durable business state, and configuration state. |

## Demos

| Demo | Description |
| --- | --- |
| [llm-d Praxis Endpoint Picker and Native Gateway](demo/llm-d-praxis/) | Validates the Praxis-native llm-d endpoint picker path with model-aware routing, load-based scoring, KV-cache utilization, and prefix-cache affinity. |
| [Responses API Agentic Loop](demo/v1-responses/) | Validates the Praxis-owned Responses API agentic orchestration loop where Praxis acts as the orchestration engine between the client and the model. |
| [A2A Task Routing](demo/a2a-task-routing/) | Validates local A2A task-ownership routing: task capture from SendMessage responses, follow-up routing by task ID, fallback for unknown tasks, and spoofing rejection. |

## Repository Layout

Each spike lives in its own subdirectory. The subdirectory `README.md` is the primary spike document. Supporting research notes and implementation plans are stored alongside it.
