#!/usr/bin/env bash
# Shared variables for Track B demo scripts.
# Source this file; do not execute it directly.

# The Track B implementation tree.
: "${TRACK_B_DIR:?Set TRACK_B_DIR to the Track B implementation checkout}"

PRAXIS_DIR="${TRACK_B_DIR}/praxis"
EPP_DIR="${TRACK_B_DIR}/repos/llm-d-router"
SIM_BIN="${TRACK_B_DIR}/../llm-d-benchmarks/repos/llm-d-inference-sim/bin/llm-d-inference-sim"

LOCAL_SMOKE="${TRACK_B_DIR}/e2e/local-go-epp/run-smoke.sh"
KIND_SMOKE="${TRACK_B_DIR}/e2e/kind-go-epp/run-kind-smoke.sh"
KIND_CLEANUP="${TRACK_B_DIR}/e2e/kind-go-epp/cleanup-kind.sh"
