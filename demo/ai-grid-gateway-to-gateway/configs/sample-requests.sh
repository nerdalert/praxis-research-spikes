#!/usr/bin/env bash
# Sample curl requests for the AI Grid gateway-to-gateway demo.
# These are reference commands, not a runnable script — they assume
# port-forwards or NodePort addresses from a live kind environment.
#
# Run after: cargo xtask env up && cargo xtask env deploy-consumer-gateway
# The xtask verify-gateway-e2e command exercises these paths automatically.

set -euo pipefail

# ---------------------------------------------------------------------------
# Provider baseline — direct inference-sim access
# Adjust PORT to the NodePort or port-forward for a specific cluster.
# ---------------------------------------------------------------------------

# List models on cluster-a
curl -s http://localhost:8080/v1/models \
  -H "Authorization: Bearer test-key" | python3 -m json.tool

# Chat completions on cluster-a (granite-3.3-8b)
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "granite-3.3-8b",
    "messages": [{"role": "user", "content": "hello from the AI Grid demo"}],
    "stream": false
  }' | python3 -m json.tool

# Chat completions — streaming
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "granite-3.3-8b",
    "messages": [{"role": "user", "content": "hello streaming"}],
    "stream": true
  }'

# ---------------------------------------------------------------------------
# Consumer gateway — model routing
# Replace CONSUMER_NODEPORT with the NodePort from cluster-c.
# ---------------------------------------------------------------------------

CONSUMER_NODEPORT="${CONSUMER_NODEPORT:-30080}"
CONSUMER_NODE_IP="${CONSUMER_NODE_IP:-127.0.0.1}"

# Route granite-3.3-8b → cluster-a (via consumer gateway)
curl -s -X POST "http://${CONSUMER_NODE_IP}:${CONSUMER_NODEPORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "granite-3.3-8b",
    "messages": [{"role": "user", "content": "route me to cluster-a"}],
    "stream": false
  }' | python3 -m json.tool

# Route llama-3.2-8b → cluster-b (via consumer gateway)
curl -s -X POST "http://${CONSUMER_NODE_IP}:${CONSUMER_NODEPORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "llama-3.2-8b",
    "messages": [{"role": "user", "content": "route me to cluster-b"}],
    "stream": false
  }' | python3 -m json.tool

# Unknown model — expect 404
curl -sv -X POST "http://${CONSUMER_NODE_IP}:${CONSUMER_NODEPORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "unknown-model",
    "messages": [{"role": "user", "content": "this should fail closed"}],
    "stream": false
  }'

# ---------------------------------------------------------------------------
# OpenAI Responses API — mock-providers only
# These requests work against mock-providers (--provider openai), not inference-sim.
# inference-sim does not implement /v1/responses.
# ---------------------------------------------------------------------------

# Non-streaming responses (mock-providers)
curl -s -X POST http://localhost:8080/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "gpt-4o",
    "input": "hello from the responses API",
    "stream": false
  }' | python3 -m json.tool

# Streaming responses (mock-providers)
curl -s -X POST http://localhost:8080/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{
    "model": "gpt-4o",
    "input": "hello streaming responses",
    "stream": true
  }'
