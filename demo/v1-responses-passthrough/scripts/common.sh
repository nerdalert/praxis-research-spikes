#!/usr/bin/env bash
# Shared local-process harness for the /v1/responses passthrough demo.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESEARCH_SPIKES_DIR="$(cd "${DEMO_DIR}/../.." && pwd)"
REPO_PARENT_DIR="$(cd "${RESEARCH_SPIKES_DIR}/.." && pwd)"
PRAXIS_DIR="${PRAXIS_DIR:-${REPO_PARENT_DIR}/praxis}"

PRAXIS_PORT="${PRAXIS_PORT:-18280}"
RESPONSES_BACKEND_PORT="${RESPONSES_BACKEND_PORT:-18281}"
STREAM_BACKEND_PORT="${STREAM_BACKEND_PORT:-18282}"
CHAT_BACKEND_PORT="${CHAT_BACKEND_PORT:-18283}"
DEFAULT_BACKEND_PORT="${DEFAULT_BACKEND_PORT:-18284}"

PGIDS=()
LAST_BG_PID=""

log() {
  echo "[responses-passthrough] $*"
}

log_section() {
  echo
  echo "================================================================"
  echo "  $*"
  echo "================================================================"
  echo
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    return 1
  }
}

check_prereqs() {
  require_command bash
  require_command cargo
  require_command curl
  require_command git
  require_command python3
  require_command setsid
  [[ -f "$PRAXIS_DIR/Cargo.toml" ]] || {
    echo "ERROR: Praxis checkout not found at $PRAXIS_DIR" >&2
    echo "Set PRAXIS_DIR to the Praxis checkout containing PR 1." >&2
    return 1
  }
}

build_praxis() {
  if [[ "${SKIP_BUILD:-0}" == "1" && -x "$PRAXIS_DIR/target/debug/praxis" ]]; then
    log "Using existing Praxis binary: $PRAXIS_DIR/target/debug/praxis"
    return
  fi

  log "Building Praxis with ai-inference support ..."
  (cd "$PRAXIS_DIR" && cargo build -p praxis --features ai-inference)
}

start_bg() {
  local name="$1"
  shift
  local log_dir="${LOG_DIR:?LOG_DIR must be set before starting processes}"

  setsid "$@" >"$log_dir/$name.log" 2>&1 &
  LAST_BG_PID="$!"
  PGIDS+=("$LAST_BG_PID")
}

stop_bg() {
  local pgid="$1"
  kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if ! kill -0 "$pgid" >/dev/null 2>&1; then
      wait "$pgid" 2>/dev/null || true
      return
    fi
    sleep 0.1
  done
  kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
  wait "$pgid" 2>/dev/null || true
}

cleanup_processes() {
  local pgid
  for pgid in "${PGIDS[@]:-}"; do
    kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
  done
  sleep 0.2
  for pgid in "${PGIDS[@]:-}"; do
    kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
    wait "$pgid" 2>/dev/null || true
  done
}

wait_for_port() {
  local port="$1"
  local name="$2"
  local attempts="${3:-100}"

  for _ in $(seq 1 "$attempts"); do
    if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "ERROR: timed out waiting for $name on 127.0.0.1:$port" >&2
  return 1
}

start_mock_backends() {
  start_bg responses-backend \
    python3 "$DEMO_DIR/mock-scripts/responses-echo-mock.py" \
    --port "$RESPONSES_BACKEND_PORT" --name responses-backend
  start_bg chat-backend \
    python3 "$DEMO_DIR/mock-scripts/responses-echo-mock.py" \
    --port "$CHAT_BACKEND_PORT" --name chat-backend
  start_bg default-backend \
    python3 "$DEMO_DIR/mock-scripts/responses-echo-mock.py" \
    --port "$DEFAULT_BACKEND_PORT" --name default-backend
  start_bg streaming-backend \
    python3 "$DEMO_DIR/mock-scripts/responses-streaming-echo-mock.py" \
    --port "$STREAM_BACKEND_PORT" --name streaming-backend

  wait_for_port "$RESPONSES_BACKEND_PORT" "Responses JSON mock"
  wait_for_port "$CHAT_BACKEND_PORT" "Chat JSON mock"
  wait_for_port "$DEFAULT_BACKEND_PORT" "default JSON mock"
  wait_for_port "$STREAM_BACKEND_PORT" "Responses SSE mock"
}

write_praxis_config() {
  local profile="$1"
  local path="$2"
  local listener_port="$3"
  local database_path="${4:-}"

  {
    cat <<YAML
listeners:
  - name: responses-passthrough
    address: "127.0.0.1:${listener_port}"
    filter_chains: [responses-passthrough]

filter_chains:
  - name: responses-passthrough
    filters:
      - filter: openai_responses_format
        on_invalid: continue
        max_body_bytes: 1048576
        headers:
          format: x-praxis-ai-format
          model: x-praxis-ai-model
          stream: x-praxis-ai-stream
YAML

    case "$profile" in
      smoke|model-rewrite-noop|model-rewrite-alias)
        cat <<'YAML'
      - filter: openai_responses_model_rewrite
        default_model: "llama-3.3-70b"
        model_aliases:
          codex-mini-latest: "llama-3.3-70b"
          gpt-4.1-mini: "qwen-2.5-72b"
        headers:
          effective_model: x-praxis-ai-effective-model
          original_model: x-praxis-ai-original-model
YAML
        ;;
      full-flow)
        [[ -n "$database_path" ]] || {
          echo "ERROR: full-flow profile requires a database path" >&2
          return 1
        }
        cat <<YAML
      - filter: openai_responses_validate
      - filter: openai_response_store
        backend: sqlite
        database_url: "sqlite://${database_path}?mode=rwc"
        responses_table: openai_responses
        conversations_table: openai_conversations
YAML
        ;;
      format-route)
        ;;
      *)
        echo "ERROR: unknown Praxis profile: $profile" >&2
        return 1
        ;;
    esac

    cat <<YAML
      - filter: router
        routes:
          - path: "/v1/responses"
            headers:
              x-praxis-ai-stream: "true"
            cluster: "streaming-backend"
          - path: "/v1/responses"
            headers:
              x-praxis-ai-format: "openai_responses"
            cluster: "responses-backend"
          - path: "/v1/chat/completions"
            headers:
              x-praxis-ai-format: "openai_chat_completions"
            cluster: "chat-backend"
          - path_prefix: "/"
            cluster: "default-backend"

      - filter: load_balancer
        clusters:
          - name: "responses-backend"
            endpoints:
              - "127.0.0.1:${RESPONSES_BACKEND_PORT}"
          - name: "streaming-backend"
            endpoints:
              - "127.0.0.1:${STREAM_BACKEND_PORT}"
          - name: "chat-backend"
            endpoints:
              - "127.0.0.1:${CHAT_BACKEND_PORT}"
          - name: "default-backend"
            endpoints:
              - "127.0.0.1:${DEFAULT_BACKEND_PORT}"
YAML
  } >"$path"
}

start_praxis() {
  local profile="$1"
  local config_path="$2"
  local listener_port="$3"

  start_bg "praxis-$profile" \
    env RUST_LOG="${RUST_LOG:-praxis=warn}" \
    "$PRAXIS_DIR/target/debug/praxis" -c "$config_path"
  wait_for_port "$listener_port" "Praxis profile $profile"
}

