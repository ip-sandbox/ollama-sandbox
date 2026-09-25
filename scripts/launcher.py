#!/usr/bin/env python3
"""Interactive model preparation and Podman launcher for the Cline sandbox."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import termios
import tty
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar


ROOT = Path(__file__).resolve().parents[1]
CONFIG_FILE = ROOT / "scripts" / "config.sh"
MODELS_FILE = ROOT / "scripts" / "models.json"
WORKSPACE = ROOT / "sandbox" / "workspace"
IMPORT_SCRIPT = ROOT / "scripts" / "import_gguf_model.sh"
PROXY_SCRIPT = ROOT / "scripts" / "proxy.sh"
ENTRYPOINT_MODEL = "smollm:135m"
BACK = object()


def load_config(path: Path = CONFIG_FILE) -> dict[str, str]:
    """config.sh の KEY="${KEY:-値}" 行から既定値を読み、環境変数があればそちらを使う。"""
    config: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r'(\w+)="\$\{\1:-(.*)\}"', line.strip())
        if match:
            key, default = match.groups()
            config[key] = os.environ.get(key, default)
    return config


CONFIG = load_config()
IMAGE = CONFIG["SANDBOX_IMAGE"]
MODEL_VOLUME = CONFIG["MODEL_VOLUME"]


@dataclass(frozen=True)
class GgufSource:
    """Ollama registry に無い量子化を、HF の GGUF と公式タグのテンプレートから組み立てる。"""

    url: str
    sha256: str
    size: int
    template_from: str
    parameters: tuple[str, ...] = ()


@dataclass(frozen=True)
class Model:
    label: str
    tag: str
    gguf: GgufSource | None = None


def load_models(path: Path = MODELS_FILE) -> list[Model]:
    data = json.loads(path.read_text(encoding="utf-8"))
    models = []
    for entry in data["models"]:
        gguf = entry.get("gguf")
        source = None
        if gguf is not None:
            source = GgufSource(
                url=gguf["url"],
                sha256=gguf["sha256"],
                size=int(gguf["size"]),
                template_from=gguf["template_from"],
                parameters=tuple(gguf.get("parameters", ())),
            )
        models.append(Model(entry["label"], entry["tag"], source))
    return models


MODELS = load_models()
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


def prepare_command(model: Model) -> list[str]:
    command = [
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
    ]
    if model.gguf is None:
        return command + [IMAGE, "ollama", "pull", model.tag]
    source = model.gguf
    return command + [
        # serve 起動時の未参照 blob 掃除で、取得途中の GGUF を消されないようにする
        "-e",
        "OLLAMA_NOPRUNE=1",
        "-v",
        f"{IMPORT_SCRIPT}:/opt/import_gguf_model.sh:ro",
        IMAGE,
        "bash",
        "/opt/import_gguf_model.sh",
        model.tag,
        source.url,
        source.sha256,
        str(source.size),
        source.template_from,
        *source.parameters,
    ]


def prepare_model(model: Model) -> None:
    ensure_volume()
    print(f"\n{model.tag} をモデルvolumeへダウンロードします。")
    print("この操作には大容量の通信とディスク容量が必要です。\n")
    run(prepare_command(model))


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
    # entrypoint の起動ログと使い方の表示が先に出るので、ollama list の見出し行より後だけを読む
    models: set[str] = set()
    in_table = False
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "NAME":
            in_table = True
        elif in_table:
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
    # 一覧から外したモデル（例: mistral-nemo）も、volume に残っていれば削除できるようにする
    known = {model.tag for model in MODELS}
    available += [Model("一覧外のモデル", tag) for tag in sorted(downloaded - known)]
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


def launch_command(model: Model, *, allow_network: bool = False) -> list[str]:
    """sandbox の起動コマンド。allow_network なら許可リスト付きプロキシ経由（scripts/proxy.sh）。"""
    options = [
        "-it",
        "-v",
        f"{WORKSPACE}:/workspace:rw",
        "-v",
        f"{MODEL_VOLUME}:/models",
        "-e",
        "OLLAMA_MODELS=/models",
        "-e",
        f"CLINE_MODEL={model.tag}",
        IMAGE,
    ]
    if allow_network:
        return ["bash", str(PROXY_SCRIPT), "run", *options]
    return ["podman", "run", "--rm", "--network=none", *options]


def launch(model: Model, *, allow_network: bool = False) -> None:
    if not model_is_available(model):
        raise RuntimeError(
            f"{model.tag} は未ダウンロードです。先に「モデルをダウンロード」を実行してください。"
        )
    if allow_network:
        print(
            "\n★ ネットワーク許可モードです。sandbox から sandbox/proxy/allowlist のドメインへ"
            "通信できます（それ以外・ホスト・DNS は遮断）。"
        )
    print(f"\n{model.tag} でsandboxを起動します。終了するにはコンテナ内でexitしてください。\n")
    run(launch_command(model, allow_network=allow_network))


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
                    ("sandboxを起動（ネットワーク許可: 許可リストのみ）", "launch_proxy"),
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
            if action == "launch_proxy":
                launch(model, allow_network=True)
    except KeyboardInterrupt:
        print("\n終了しました。")
        return 130
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"\nエラー: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
