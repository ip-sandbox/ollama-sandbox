#!/usr/bin/env python3
"""Unit tests for the standard-library launcher."""

import sys
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import launcher  # noqa: E402


class DownloadedModelsTests(unittest.TestCase):
    @patch.object(launcher, "ensure_volume")
    @patch.object(launcher.subprocess, "run")
    def test_returns_model_tags_and_ignores_header(
        self, run_mock, ensure_volume_mock
    ):
        run_mock.return_value = CompletedProcess(
            args=["podman"],
            returncode=0,
            stdout=(
                "[entrypoint] Starting Ollama server in background...\n"
                "[entrypoint] Ollama API is ready.\n"
                "NAME              ID              SIZE      MODIFIED\n"
                "qwen3:8b          abc123          5.0 GB    2 hours ago\n"
                "gemma4:12b-it-qat def456          8.0 GB    1 hour ago\n"
            ),
            stderr="",
        )

        result = launcher.downloaded_models()

        self.assertEqual(result, {"qwen3:8b", "gemma4:12b-it-qat"})
        ensure_volume_mock.assert_called_once_with()
        run_mock.assert_called_once()
        self.assertEqual(run_mock.call_args.kwargs["check"], True)
        self.assertEqual(run_mock.call_args.kwargs["cwd"], launcher.ROOT)

    @patch.object(launcher, "ensure_volume")
    @patch.object(launcher.subprocess, "run")
    def test_returns_empty_set_when_ollama_has_no_models(
        self, run_mock, ensure_volume_mock
    ):
        run_mock.return_value = CompletedProcess(
            args=["podman"],
            returncode=0,
            stdout="NAME    ID    SIZE    MODIFIED\n",
            stderr="",
        )

        result = launcher.downloaded_models()

        self.assertEqual(result, set())
        ensure_volume_mock.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
