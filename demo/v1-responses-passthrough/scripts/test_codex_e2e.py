#!/usr/bin/env python3
"""Unit tests for codex-tool-loop-mock.py and codex_e2e_verifier.py.

Run:
    python3 -m pytest test_codex_e2e.py -v
    # or without pytest:
    python3 test_codex_e2e.py
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# Add parent dirs to path for imports
SCRIPT_DIR = Path(__file__).resolve().parent
MOCK_DIR = SCRIPT_DIR.parent / "mock-scripts"
sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(MOCK_DIR))

from codex_e2e_verifier import (
    VerificationResult,
    load_json_file,
    load_jsonl_file,
    verify_backend_models,
    verify_codex_jsonl,
    verify_first_request_tools,
    verify_request_count,
    verify_second_request_fco,
    verify_proof_file,
)

# Deferred import; module uses top-level code behind __name__ guard
import importlib
codex_tool_loop_mock = importlib.import_module("codex-tool-loop-mock")


# =============================================================================
# Mock Tests
# =============================================================================


class TestMockSSEEncoding(unittest.TestCase):
    """Test SSE event encoding from the mock."""

    def test_sse_encode_produces_data_lines(self):
        events = [{"type": "response.created", "response": {"id": "r1"}}]
        encoded = codex_tool_loop_mock.sse_encode(events)
        lines = encoded.decode().strip().split("\n\n")
        self.assertEqual(len(lines), 2, "one event + [DONE]")
        self.assertTrue(lines[0].startswith("data: "), "event should start with data:")
        self.assertEqual(lines[1], "data: [DONE]")

    def test_sse_encode_valid_json_per_event(self):
        events = [{"type": "test", "value": 42}, {"type": "test2"}]
        encoded = codex_tool_loop_mock.sse_encode(events)
        for line in encoded.decode().strip().split("\n\n"):
            if line == "data: [DONE]":
                continue
            payload = line.removeprefix("data: ")
            parsed = json.loads(payload)
            self.assertIn("type", parsed)

    def test_sse_encode_empty_events(self):
        encoded = codex_tool_loop_mock.sse_encode([])
        self.assertEqual(encoded, b"data: [DONE]\n\n")


class TestMockFunctionCallEvents(unittest.TestCase):
    """Test the function_call event builder."""

    def test_function_call_events_contain_required_types(self):
        events = codex_tool_loop_mock.build_function_call_events("test-model")
        types = [e["type"] for e in events]
        self.assertIn("response.created", types)
        self.assertIn("response.output_item.added", types)
        self.assertIn("response.function_call_arguments.delta", types)
        self.assertIn("response.function_call_arguments.done", types)
        self.assertIn("response.output_item.done", types)
        self.assertIn("response.completed", types)

    def test_function_call_events_use_correct_model(self):
        events = codex_tool_loop_mock.build_function_call_events("my-model")
        created = next(e for e in events if e["type"] == "response.created")
        self.assertEqual(created["response"]["model"], "my-model")

    def test_function_call_has_exec_command_name(self):
        events = codex_tool_loop_mock.build_function_call_events("m")
        added = next(e for e in events if e["type"] == "response.output_item.added")
        self.assertEqual(added["item"]["name"], "exec_command")

    def test_function_call_arguments_are_valid_json(self):
        events = codex_tool_loop_mock.build_function_call_events("m")
        done = next(e for e in events if e["type"] == "response.function_call_arguments.done")
        args = json.loads(done["arguments"])
        self.assertIn("cmd", args)

    def test_function_call_call_id_consistent(self):
        events = codex_tool_loop_mock.build_function_call_events("m")
        added = next(e for e in events if e["type"] == "response.output_item.added")
        done = next(e for e in events if e["type"] == "response.output_item.done")
        self.assertEqual(added["item"]["call_id"], done["item"]["call_id"])

    def test_completed_event_has_usage(self):
        events = codex_tool_loop_mock.build_function_call_events("m")
        completed = next(e for e in events if e["type"] == "response.completed")
        self.assertIn("usage", completed["response"])
        self.assertIn("input_tokens", completed["response"]["usage"])


class TestMockFinalMessageEvents(unittest.TestCase):
    """Test the final message event builder."""

    def test_final_events_contain_required_types(self):
        events = codex_tool_loop_mock.build_final_message_events("m")
        types = [e["type"] for e in events]
        self.assertIn("response.created", types)
        self.assertIn("response.output_item.added", types)
        self.assertIn("response.output_text.delta", types)
        self.assertIn("response.output_text.done", types)
        self.assertIn("response.completed", types)

    def test_final_events_use_correct_model(self):
        events = codex_tool_loop_mock.build_final_message_events("final-model")
        completed = next(e for e in events if e["type"] == "response.completed")
        self.assertEqual(completed["response"]["model"], "final-model")

    def test_final_delta_matches_done_text(self):
        events = codex_tool_loop_mock.build_final_message_events("m")
        delta = next(e for e in events if e["type"] == "response.output_text.delta")
        done = next(e for e in events if e["type"] == "response.output_text.done")
        self.assertEqual(delta["delta"], done["text"])


# =============================================================================
# Verifier Tests
# =============================================================================


class TestVerificationResult(unittest.TestCase):
    """Test the VerificationResult accumulator."""

    def test_empty_result_passes(self):
        r = VerificationResult()
        self.assertTrue(r.passed)

    def test_all_pass(self):
        r = VerificationResult()
        r.check("a", True)
        r.check("b", True)
        self.assertTrue(r.passed)

    def test_one_failure_fails(self):
        r = VerificationResult()
        r.check("a", True)
        r.check("b", False, "reason")
        self.assertFalse(r.passed)

    def test_summary_contains_check_names(self):
        r = VerificationResult()
        r.check("my_check", True)
        self.assertIn("my_check", r.summary())
        self.assertIn("PASS", r.summary())


class TestLoadJsonFile(unittest.TestCase):
    """Test JSON file loading."""

    def test_valid_json(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"key": "value"}, f)
            f.flush()
            result = load_json_file(f.name)
        os.unlink(f.name)
        self.assertEqual(result, {"key": "value"})

    def test_missing_file(self):
        self.assertIsNone(load_json_file("/nonexistent/path.json"))

    def test_invalid_json(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("not json")
            f.flush()
            result = load_json_file(f.name)
        os.unlink(f.name)
        self.assertIsNone(result)


class TestLoadJsonlFile(unittest.TestCase):
    """Test JSONL file loading."""

    def test_valid_jsonl(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"a"}\n{"type":"b"}\n')
            f.flush()
            result = load_jsonl_file(f.name)
        os.unlink(f.name)
        self.assertEqual(len(result), 2)

    def test_missing_file(self):
        self.assertEqual(load_jsonl_file("/nonexistent"), [])


class TestVerifyRequestCount(unittest.TestCase):
    """Test request count verification."""

    def test_exactly_two(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-1.json").write_text("{}")
            Path(d, "backend-req-2.json").write_text("{}")
            r = VerificationResult()
            verify_request_count(d, r)
            self.assertTrue(r.passed)

    def test_three_requests_fails(self):
        with tempfile.TemporaryDirectory() as d:
            for i in (1, 2, 3):
                Path(d, f"backend-req-{i}.json").write_text("{}")
            r = VerificationResult()
            verify_request_count(d, r)
            self.assertFalse(r.passed)

    def test_one_request_fails(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-1.json").write_text("{}")
            r = VerificationResult()
            verify_request_count(d, r)
            self.assertFalse(r.passed)


class TestVerifyBackendModels(unittest.TestCase):
    """Test backend model verification."""

    def test_both_correct(self):
        with tempfile.TemporaryDirectory() as d:
            for i in (1, 2):
                Path(d, f"backend-req-{i}.json").write_text(
                    json.dumps({"model": "llama-3.3-70b"})
                )
            r = VerificationResult()
            verify_backend_models(d, "llama-3.3-70b", r)
            self.assertTrue(r.passed)

    def test_wrong_model_fails(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-1.json").write_text(
                json.dumps({"model": "wrong"})
            )
            Path(d, "backend-req-2.json").write_text(
                json.dumps({"model": "llama-3.3-70b"})
            )
            r = VerificationResult()
            verify_backend_models(d, "llama-3.3-70b", r)
            self.assertFalse(r.passed)


class TestVerifyFirstRequestTools(unittest.TestCase):
    """Test first request tool verification."""

    def test_has_exec_command(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-1.json").write_text(
                json.dumps({"tools": [{"name": "exec_command", "type": "function"}]})
            )
            r = VerificationResult()
            verify_first_request_tools(d, r)
            self.assertTrue(r.passed)

    def test_missing_exec_command(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-1.json").write_text(
                json.dumps({"tools": [{"name": "other_tool"}]})
            )
            r = VerificationResult()
            verify_first_request_tools(d, r)
            self.assertFalse(r.passed)


class TestVerifySecondRequestFco(unittest.TestCase):
    """Test second request function_call_output verification."""

    def test_has_matching_fco(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-2.json").write_text(json.dumps({
                "input": [
                    {"type": "function_call_output", "call_id": "call_001", "output": "ok"}
                ]
            }))
            r = VerificationResult()
            verify_second_request_fco(d, "call_001", r)
            self.assertTrue(r.passed)

    def test_wrong_call_id_fails(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-2.json").write_text(json.dumps({
                "input": [
                    {"type": "function_call_output", "call_id": "wrong", "output": "ok"}
                ]
            }))
            r = VerificationResult()
            verify_second_request_fco(d, "call_001", r)
            self.assertFalse(r.passed)

    def test_no_fco_fails(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "backend-req-2.json").write_text(json.dumps({
                "input": [{"type": "message", "role": "user", "content": "hi"}]
            }))
            r = VerificationResult()
            verify_second_request_fco(d, "call_001", r)
            self.assertFalse(r.passed)


class TestVerifyProofFile(unittest.TestCase):
    """Test proof file verification."""

    def test_correct_content(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
            f.write("praxis-codex-e2e")
            f.flush()
            r = VerificationResult()
            verify_proof_file(f.name, "praxis-codex-e2e", r)
        os.unlink(f.name)
        self.assertTrue(r.passed)

    def test_wrong_content_fails(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
            f.write("wrong content")
            f.flush()
            r = VerificationResult()
            verify_proof_file(f.name, "praxis-codex-e2e", r)
        os.unlink(f.name)
        self.assertFalse(r.passed)

    def test_missing_file_fails(self):
        r = VerificationResult()
        verify_proof_file("/nonexistent/proof.txt", "x", r)
        self.assertFalse(r.passed)


class TestVerifyCodexJsonl(unittest.TestCase):
    """Test Codex JSONL verification."""

    def test_valid_jsonl(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            for entry in [
                {"type": "thread.started"},
                {"type": "turn.started"},
                {"type": "item.started", "item": {"type": "command_execution"}},
                {"type": "item.completed", "item": {"type": "agent_message"}},
                {"type": "turn.completed", "usage": {}},
            ]:
                f.write(json.dumps(entry) + "\n")
            f.flush()
            r = VerificationResult()
            verify_codex_jsonl(f.name, r)
        os.unlink(f.name)
        self.assertTrue(r.passed)

    def test_missing_command_execution_fails(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            for entry in [
                {"type": "turn.started"},
                {"type": "turn.completed"},
            ]:
                f.write(json.dumps(entry) + "\n")
            f.flush()
            r = VerificationResult()
            verify_codex_jsonl(f.name, r)
        os.unlink(f.name)
        self.assertFalse(r.passed)

    def test_turn_failed_fails(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            for entry in [
                {"type": "turn.started"},
                {"type": "item.started", "item": {"type": "command_execution"}},
                {"type": "turn.failed", "error": {"message": "oops"}},
            ]:
                f.write(json.dumps(entry) + "\n")
            f.flush()
            r = VerificationResult()
            verify_codex_jsonl(f.name, r)
        os.unlink(f.name)
        self.assertFalse(r.passed)


if __name__ == "__main__":
    unittest.main()
