#!/usr/bin/env python3
"""Structural verifier for the Codex E2E test artifacts.

Validates:
  - Exactly two backend requests were recorded.
  - Both requests have the rewritten model.
  - First request advertises exec_command in tools.
  - Second request contains function_call_output with matching call_id.
  - Sentinel file content matches exactly.
  - Codex JSONL contains command_execution and completed turn.
  - No unexpected third request.

Usage:
    python3 codex_e2e_verifier.py \\
        --log-dir /path/to/logs \\
        --codex-jsonl /path/to/codex.jsonl \\
        --proof /path/to/proof.txt \\
        --expected-model llama-3.3-70b \\
        --expected-call-id call_praxis_e2e_001 \\
        --expected-proof-content praxis-codex-e2e
"""

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class VerificationResult:
    """Accumulated verification outcome."""

    checks: list[tuple[str, bool, str]] = field(default_factory=list)

    def check(self, name: str, passed: bool, detail: str = "") -> None:
        """Record one check."""
        self.checks.append((name, passed, detail))

    @property
    def passed(self) -> bool:
        """Return True if all checks passed."""
        return all(ok for _, ok, _ in self.checks)

    def summary(self) -> str:
        """Return a human-readable summary."""
        lines = []
        for name, ok, detail in self.checks:
            status = "PASS" if ok else "FAIL"
            suffix = f" ({detail})" if detail else ""
            lines.append(f"  [{status}] {name}{suffix}")
        total = len(self.checks)
        passed = sum(1 for _, ok, _ in self.checks if ok)
        lines.append(f"\n  {passed}/{total} checks passed.")
        return "\n".join(lines)


def load_json_file(path: str) -> dict | None:
    """Load a JSON file, returning None if it does not exist."""
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def load_jsonl_file(path: str) -> list[dict]:
    """Load a JSONL file as a list of dicts."""
    entries = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    entries.append(json.loads(line))
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return entries


def verify_request_count(log_dir: str, result: VerificationResult) -> int:
    """Verify exactly two backend request files exist."""
    req1 = os.path.exists(os.path.join(log_dir, "backend-req-1.json"))
    req2 = os.path.exists(os.path.join(log_dir, "backend-req-2.json"))
    req3 = os.path.exists(os.path.join(log_dir, "backend-req-3.json"))

    result.check("exactly_two_requests", req1 and req2 and not req3,
                 f"req1={req1} req2={req2} req3={req3}")
    count = (1 if req1 else 0) + (1 if req2 else 0)
    return count


def verify_backend_models(log_dir: str, expected_model: str,
                          result: VerificationResult) -> None:
    """Verify both requests have the expected rewritten model."""
    for i in (1, 2):
        data = load_json_file(os.path.join(log_dir, f"backend-req-{i}.json"))
        if data is None:
            result.check(f"req{i}_model", False, "file missing")
            continue
        actual = data.get("model")
        result.check(f"req{i}_model_is_{expected_model}", actual == expected_model,
                     f"actual={actual}")


def verify_first_request_tools(log_dir: str, result: VerificationResult) -> None:
    """Verify the first request advertises exec_command in tools."""
    data = load_json_file(os.path.join(log_dir, "backend-req-1.json"))
    if data is None:
        result.check("req1_has_exec_command_tool", False, "file missing")
        return
    tools = data.get("tools", [])
    tool_names = [t.get("name") for t in tools if isinstance(t, dict)]
    result.check("req1_has_exec_command_tool", "exec_command" in tool_names,
                 f"tool_names={tool_names[:5]}")


def verify_second_request_fco(log_dir: str, expected_call_id: str,
                              result: VerificationResult) -> None:
    """Verify the second request contains function_call_output."""
    data = load_json_file(os.path.join(log_dir, "backend-req-2.json"))
    if data is None:
        result.check("req2_has_function_call_output", False, "file missing")
        return

    input_items = data.get("input", [])
    if not isinstance(input_items, list):
        result.check("req2_has_function_call_output", False, "input not a list")
        return

    fco_items = [
        item for item in input_items
        if isinstance(item, dict) and item.get("type") == "function_call_output"
    ]
    result.check("req2_has_function_call_output", len(fco_items) > 0,
                 f"fco_count={len(fco_items)}")

    if fco_items:
        fco = fco_items[0]
        actual_call_id = fco.get("call_id")
        result.check("req2_call_id_matches", actual_call_id == expected_call_id,
                     f"actual={actual_call_id} expected={expected_call_id}")

        output_str = fco.get("output", "")
        result.check("req2_fco_has_output", len(output_str) > 0,
                     f"output_len={len(output_str)}")


def verify_proof_file(proof_path: str, expected_content: str,
                      result: VerificationResult) -> None:
    """Verify proof file exists with exact content."""
    try:
        actual = Path(proof_path).read_text()
        result.check("proof_exists", True)
        result.check("proof_content_matches", actual == expected_content,
                     f"actual={actual!r} expected={expected_content!r}")
    except FileNotFoundError:
        result.check("proof_exists", False, "file not found")
        result.check("proof_content_matches", False, "file not found")


def verify_codex_jsonl(jsonl_path: str, result: VerificationResult) -> None:
    """Verify Codex JSONL contains expected events."""
    entries = load_jsonl_file(jsonl_path)
    result.check("codex_jsonl_not_empty", len(entries) > 0,
                 f"entries={len(entries)}")

    types = [e.get("type") for e in entries]

    result.check("codex_has_turn_started", "turn.started" in types)
    result.check("codex_has_turn_completed", "turn.completed" in types)

    has_cmd_exec = any(
        e.get("type") == "item.started"
        and isinstance(e.get("item"), dict)
        and e["item"].get("type") == "command_execution"
        for e in entries
    )
    result.check("codex_has_command_execution", has_cmd_exec)

    has_no_error = "turn.failed" not in types
    result.check("codex_no_turn_failed", has_no_error,
                 f"types={types}" if not has_no_error else "")


def run_verification(args: argparse.Namespace) -> VerificationResult:
    """Run all verification checks."""
    result = VerificationResult()

    verify_request_count(args.log_dir, result)
    verify_backend_models(args.log_dir, args.expected_model, result)
    verify_first_request_tools(args.log_dir, result)
    verify_second_request_fco(args.log_dir, args.expected_call_id, result)
    verify_proof_file(args.proof, args.expected_proof_content, result)
    verify_codex_jsonl(args.codex_jsonl, result)

    return result


def parse_cli_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description="Codex E2E transcript verifier")
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--codex-jsonl", required=True)
    parser.add_argument("--proof", required=True)
    parser.add_argument("--expected-model", default="llama-3.3-70b")
    parser.add_argument("--expected-call-id", default="call_praxis_e2e_001")
    parser.add_argument("--expected-proof-content", default="praxis-codex-e2e")
    return parser.parse_args()


def main() -> None:
    """Entry point."""
    args = parse_cli_args()
    result = run_verification(args)
    print(result.summary())
    sys.exit(0 if result.passed else 1)


if __name__ == "__main__":
    main()
