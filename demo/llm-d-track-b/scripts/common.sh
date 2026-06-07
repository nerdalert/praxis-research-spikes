#!/usr/bin/env bash
# Shared variables for Track B demo scripts.
# Source this file; do not execute it directly.

# The Track B implementation tree. Adjust if your checkout is elsewhere.
TRACK_B_DIR="${TRACK_B_DIR:-/home/ubuntu/praxxis/llm-d/track-b}"

PRAXIS_DIR="${TRACK_B_DIR}/praxis"
EPP_DIR="${TRACK_B_DIR}/repos/llm-d-router"
SIM_BIN="${TRACK_B_DIR}/../llm-d-benchmarks/repos/llm-d-inference-sim/bin/llm-d-inference-sim"

LOCAL_SMOKE="${TRACK_B_DIR}/e2e/local-go-epp/run-smoke.sh"
KIND_SMOKE="${TRACK_B_DIR}/e2e/kind-go-epp/run-kind-smoke.sh"
KIND_CLEANUP="${TRACK_B_DIR}/e2e/kind-go-epp/cleanup-kind.sh"
