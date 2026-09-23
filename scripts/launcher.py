#!/usr/bin/env python3
"""Interactive model preparation and Podman launcher for the Cline sandbox."""

from __future__ import annotations

import shutil
import subprocess
import sys
import termios
import tty
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar


IMAGE = "localhost/cline-sandbox:v2"
MODEL_VOLUME = "ollama-models"
ENTRYPOINT_MODEL = "smollm:135m"
ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT / "sandbox" / "workspace"
BACK = object()


@dataclass(frozen=True)
class Model:
    label: str
    tag: str


MODELS = [
    Model("Qwen3 8B", "qwen3:8b"),
    Model("Gemma 4 12B IT QAT", "gemma4:12b-it-qat"),
    Model("GPT-OSS 20B", "gpt-oss:20b"),
    Model("Mistral Nemo 12B Q4_K_M", "mistral-nemo:12b-instruct-2407-q4_K_M"),
]
Option = TypeVar("Option")


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        cwd=ROOT,
        env=None,
    )


def ensure_prerequisites() -> None:
    if shutil.which("podman") is None:
        raise RuntimeError("podman が見つかりません。先にPodmanをインストールしてください。")
    if not WORKSPACE.exists():
        WORKSPACE.mkdir(parents=True)


def select_option(prompt: str, options: list[tuple[str, Option]]) -> Option | None:
    """Select an option with arrow keys when attached to a terminal."""
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print(f"\n{prompt}")
        for index, (label, _) in enumerate(options, start=1):
            print(f"  {index}) {label}")
        answer = input("番号を入力してください（qで終了）: ").strip().lower()
        if answer == "q":
            return None
        try:
            return options[int(answer) - 1][1]
        except (ValueError, IndexError):
            print("無効な選択です。")
            return select_option(prompt, options)

    selected = 0
    while True:
        print("\033[2J\033[H", end="")
        print(prompt)
        print("矢印キーで選択し、Enterで決定（qで終了）\n")
        for index, (label, _) in enumerate(options):
            marker = ">" if index == selected else " "
            print(f" {marker} {label}")

        sys.stdout.flush()
        old_settings = termios.tcgetattr(sys.stdin)
        try:
            tty.setraw(sys.stdin.fileno())
            key = sys.stdin.read(1)
            if key == "\x03":
                raise KeyboardInterrupt
            if key.lower() == "q":
                return None
            if key in ("\r", "\n"):
                return options[selected][1]
            if key == "\x1b":
                sequence = sys.stdin.read(2)
                if sequence == "[A":
                    selected = (selected - 1) % len(options)
                elif sequence == "[B":
                    selected = (selected + 1) % len(options)
        finally:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)


def select_model() -> Model | None | object:
    downloaded = downloaded_models()
    options: list[tuple[str, Model | object]] = [
        (
            f"{model.label} [{model.tag}] "
            f"{'✓ ダウンロード済み' if model.tag in downloaded else '未ダウンロード'}",
            model,
        )
        for model in MODELS
    ]
    options.append(("← 前の画面に戻る", BACK))
    return select_option(
        "使用するモデルを選択してください",
        options,
    )


def ensure_volume() -> None:
    result = subprocess.run(
        ["podman", "volume", "inspect", MODEL_VOLUME],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        subprocess.run(
            ["podman", "volume", "create", MODEL_VOLUME],
            check=True,
            stdout=subprocess.DEVNULL,
            text=True,
            cwd=ROOT,
        )


def prepare_model(model: Model) -> None:
    ensure_volume()
    print(f"\n{model.tag} をモデルvolumeへダウンロードします。")
    print("この操作には大容量の通信とディスク容量が必要です。\n")
    run(
        [
            "podman",
            "run",
            "--rm",
            "--network=host",
            "-v",
            f"{MODEL_VOLUME}:/models",
            "-e",
            "OLLAMA_MODELS=/models",
            "-e",
            f"CLINE_MODEL={model.tag}",
            IMAGE,
            "ollama",
            "pull",
            model.tag,
        ],
    )


def downloaded_models() -> set[str]:
    """Return model tags currently stored in the shared Ollama volume."""
    ensure_volume()
    result = subprocess.run(
        [
            "podman",
            "run",
            "--rm",
            "--network=none",
            "-v",
            f"{MODEL_VOLUME}:/models",
            "-e",
            "OLLAMA_MODELS=/models",
            "-e",
            f"CLINE_MODEL={ENTRYPOINT_MODEL}",
            IMAGE,
            "ollama",
            "list",
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=ROOT,
    )
    models: set[str] = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0] != "NAME" and not fields[0].startswith("["):
            models.add(fields[0])
    return models


def delete_model(model: Model) -> None:
    print(f"\n{model.tag} を削除します。")
    confirmation = select_option(
        "削除してよいですか？",
        [("削除する", True), ("キャンセル", False)],
    )
    if confirmation is not True:
        return
    ensure_volume()
    run(
        [
            "podman",
            "run",
            "--rm",
            "--network=none",
            "-v",
            f"{MODEL_VOLUME}:/models",
            "-e",
            "OLLAMA_MODELS=/models",
            "-e",
            f"CLINE_MODEL={model.tag}",
            IMAGE,
            "ollama",
            "rm",
            model.tag,
        ],
    )
    print(f"{model.tag} を削除しました。")


def select_downloaded_model() -> Model | None | object:
    downloaded = downloaded_models()
    available = [model for model in MODELS if model.tag in downloaded]
    if not available:
        print("\nダウンロード済みの選択可能なモデルはありません。")
        return BACK
    return select_option(
        "削除するモデルを選択してください",
        [(f"{model.label} [{model.tag}]", model) for model in available]
        + [("← 前の画面に戻る", BACK)],
    )


def model_is_available(model: Model) -> bool:
    ensure_volume()
    result = subprocess.run(
        [
            "podman",
            "run",
            "--rm",
            "--network=none",
            "-v",
            f"{MODEL_VOLUME}:/models",
            "-e",
            "OLLAMA_MODELS=/models",
            "-e",
            f"CLINE_MODEL={model.tag}",
            IMAGE,
            "ollama",
            "show",
            model.tag,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def launch(model: Model) -> None:
    if not model_is_available(model):
        raise RuntimeError(
            f"{model.tag} は未ダウンロードです。先に「モデルをダウンロード」を実行してください。"
        )
    print(f"\n{model.tag} でsandboxを起動します。終了するにはコンテナ内でexitしてください。\n")
    run(
        [
            "podman",
            "run",
            "--rm",
            "-it",
            "--network=none",
            "-v",
            f"{WORKSPACE}:/workspace:rw",
            "-v",
            f"{MODEL_VOLUME}:/models",
            "-e",
            "OLLAMA_MODELS=/models",
            "-e",
            f"CLINE_MODEL={model.tag}",
            IMAGE,
        ],
    )


def main() -> int:
    try:
        ensure_prerequisites()
        while True:
            action = select_option(
                "Cline Sandbox Launcher",
                [
                    ("モデルをダウンロード", "prepare"),
                    ("sandboxを起動", "launch"),
                    ("ダウンロードしてsandboxを起動", "prepare_launch"),
                    ("ダウンロード済みモデルを削除", "delete"),
                    ("終了", "exit"),
                ],
            )
            if action in (None, "exit"):
                return 0
            if action == "delete":
                model = select_downloaded_model()
                if model is BACK:
                    continue
                if model is None:
                    return 0
                delete_model(model)
                continue

            model = select_model()
            if model is None:
                return 0
            if model is BACK:
                continue
            if action in ("prepare", "prepare_launch"):
                prepare_model(model)
            if action in ("launch", "prepare_launch"):
                launch(model)
    except KeyboardInterrupt:
        print("\n終了しました。")
        return 130
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"\nエラー: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
