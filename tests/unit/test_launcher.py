#!/usr/bin/env python3
"""Unit tests for the standard-library launcher."""

import sys
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
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
                "  cline                                  # Cline CLI\n"
                "  codex -a never                         # Codex\n"
                "  ※ CPU 推論では 1 ターン目に 10 分以上かかることがあります\n"
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


class PrepareCommandTests(unittest.TestCase):
    def test_registry_model_uses_ollama_pull(self):
        model = launcher.Model("Qwen3 8B", "qwen3:8b")

        command = launcher.prepare_command(model)

        self.assertIn("--network=host", command)
        self.assertEqual(command[-4:], [launcher.IMAGE, "ollama", "pull", "qwen3:8b"])
        self.assertNotIn("OLLAMA_NOPRUNE=1", command)

    def test_gguf_model_runs_import_script(self):
        source = launcher.GgufSource(
            url="https://example.com/m.gguf",
            sha256="ab" * 32,
            size=123,
            template_from="official:tag",
            parameters=("min_p=0.01",),
        )
        model = launcher.Model("M", "m:local", source)

        command = launcher.prepare_command(model)

        self.assertIn("OLLAMA_NOPRUNE=1", command)
        self.assertIn(f"{launcher.IMPORT_SCRIPT}:/opt/import_gguf_model.sh:ro", command)
        image_at = command.index(launcher.IMAGE)
        self.assertEqual(
            command[image_at + 1:],
            ["bash", "/opt/import_gguf_model.sh", "m:local", "https://example.com/m.gguf",
             "ab" * 32, "123", "official:tag", "min_p=0.01"],
        )

    def test_devstral_is_listed_and_mistral_nemo_is_not(self):
        tags = {model.tag for model in launcher.MODELS}

        self.assertIn("devstral-small-2:24b-iq4_xs", tags)
        self.assertNotIn("mistral-nemo:12b-instruct-2407-q4_K_M", tags)
        self.assertTrue(launcher.IMPORT_SCRIPT.is_file())


class SelectDownloadedModelTests(unittest.TestCase):
    @patch.object(launcher, "select_option")
    @patch.object(launcher, "downloaded_models")
    def test_unlisted_downloaded_model_can_still_be_deleted(
        self, downloaded_mock, select_mock
    ):
        downloaded_mock.return_value = {
            "gpt-oss:20b",
            "mistral-nemo:12b-instruct-2407-q4_K_M",
        }
        select_mock.side_effect = lambda prompt, options: options

        options = launcher.select_downloaded_model()

        tags = [model.tag for _, model in options if model is not launcher.BACK]
        self.assertEqual(tags, ["gpt-oss:20b", "mistral-nemo:12b-instruct-2407-q4_K_M"])


class ConfigAndModelsTests(unittest.TestCase):
    def test_config_defaults_come_from_config_sh(self):
        with patch.dict(launcher.os.environ, {}, clear=True):
            config = launcher.load_config()

        self.assertEqual(config["SANDBOX_IMAGE"], "localhost/cline-sandbox:v3")
        self.assertEqual(config["MODEL_VOLUME"], "ollama-models")
        self.assertIn("SANDBOX_PROXY_IMAGE", config)

    def test_environment_overrides_config(self):
        with patch.dict(launcher.os.environ, {"SANDBOX_IMAGE": "localhost/x:v9"}):
            config = launcher.load_config()

        self.assertEqual(config["SANDBOX_IMAGE"], "localhost/x:v9")

    def test_models_json_entries_are_well_formed(self):
        models = launcher.load_models()

        tags = [model.tag for model in models]
        self.assertEqual(len(tags), len(set(tags)))
        for model in models:
            if model.gguf is not None:
                self.assertRegex(model.gguf.sha256, r"^[0-9a-f]{64}$")
                self.assertGreater(model.gguf.size, 0)
                self.assertTrue(model.gguf.url.startswith("https://"))


class LaunchCommandTests(unittest.TestCase):
    model = launcher.Model("Qwen3 8B", "qwen3:8b")

    def test_default_launch_has_no_network(self):
        command = launcher.launch_command(self.model)

        self.assertEqual(command[:4], ["podman", "run", "--rm", "--network=none"])
        self.assertEqual(command[-1], launcher.IMAGE)
        self.assertIn("CLINE_MODEL=qwen3:8b", command)

    def test_network_mode_goes_through_proxy_script(self):
        command = launcher.launch_command(self.model, allow_network=True)

        self.assertEqual(command[:3], ["bash", str(launcher.PROXY_SCRIPT), "run"])
        self.assertNotIn("--network=none", command)
        self.assertEqual(command[-1], launcher.IMAGE)
        self.assertTrue(launcher.PROXY_SCRIPT.is_file())


if __name__ == "__main__":
    unittest.main()
