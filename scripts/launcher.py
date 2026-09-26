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
ENTRYPOINT = ROOT / "sandbox" / "scripts" / "entrypoint.sh"
INSTALL_SCRIPT = ROOT / "sandbox" / "scripts" / "install.sh"
CONTAINER_MARKERS = (Path("/.dockerenv"), Path("/run/.containerenv"))
ENTRYPOINT_MODEL = "smollm:135m"
BACK = object()


def load_config(path: Path = CONFIG_FILE) -> dict[str, str]:
    """config.sh の KEY="${KEY:-値}" 行から既定値を読み、環境変数があればそちらを使う。

    既定値の中の $HOME などは、シェルと同じように展開する。
    """
    config: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r'(\w+)="\$\{\1:-(.*)\}"', line.strip())
        if match:
            key, default = match.groups()
            config[key] = os.environ.get(key, os.path.expandvars(default))
    return config


def detect_backend(setting: str) -> str:
    """podman: sandbox コンテナで動かす。native: すでにコンテナ内なので、直接動かす。"""
    if setting in ("podman", "native"):
        return setting
    if setting != "auto":
        raise RuntimeError(f"SANDBOX_BACKEND は auto / podman / native のどれかです: {setting}")
    return "podman" if shutil.which("podman") else "native"


def inside_container() -> bool:
    return any(marker.exists() for marker in CONTAINER_MARKERS) or "COLAB_RELEASE_TAG" in os.environ


CONFIG = load_config()
IMAGE = CONFIG["SANDBOX_IMAGE"]
MODEL_VOLUME = CONFIG["MODEL_VOLUME"]
BACKEND = detect_backend(CONFIG["SANDBOX_BACKEND"])
NATIVE_MODELS_DIR = Path(CONFIG["NATIVE_MODELS_DIR"])
NATIVE_WORKSPACE = Path(CONFIG["NATIVE_WORKSPACE"]) if CONFIG["NATIVE_WORKSPACE"] else WORKSPACE


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
    if BACKEND == "native":
        ensure_native_tools()
        NATIVE_WORKSPACE.mkdir(parents=True, exist_ok=True)
        return
    if shutil.which("podman") is None:
        raise RuntimeError("podman が見つかりません。先にPodmanをインストールしてください。")
    if not WORKSPACE.exists():
        WORKSPACE.mkdir(parents=True)


def ensure_native_tools() -> None:
    """Ollama・Cline・Codex が検証済みの版で入っていなければ、install.sh で入れる。"""
    # 子プロセス（cline --version など）に、メニューへの入力を読ませない
    check = subprocess.run(
        ["bash", str(INSTALL_SCRIPT), "--check"], stdin=subprocess.DEVNULL, cwd=ROOT
    )
    if check.returncode == 0:
        return
    if os.geteuid() != 0:
        raise RuntimeError(f"root で `bash {INSTALL_SCRIPT}` を実行してから、もう一度起動してください。")
    print("\nnative モードには Ollama・Cline CLI・Codex CLI が必要です（ネットワークから取得します）。")
    confirmation = select_option(
        f"{INSTALL_SCRIPT.relative_to(ROOT)} を実行してインストールしますか？",
        [("インストールする", True), ("終了", False)],
    )
    if confirmation is not True:
        raise RuntimeError("必要なツールがインストールされていません。")
    run(["bash", str(INSTALL_SCRIPT)])


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
    if BACKEND == "native":
        NATIVE_MODELS_DIR.mkdir(parents=True, exist_ok=True)
        return
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


def container_command(
    tag: str,
    command: list[str],
    *,
    network: str = "none",
    env: tuple[str, ...] = (),
    mounts: tuple[str, ...] = (),
    agent_setup: bool = False,
) -> list[str]:
    """モデル volume と CLINE_MODEL を渡して、sandbox の entrypoint 経由で command を実行する。

    podman: 使い捨てのコンテナで実行する。
    native: コンテナを使わず entrypoint.sh を直接実行する（mounts と network は使わない）。
            HOME の設定が残るので、agent_setup（sandbox の起動）のとき以外は
            Cline / Codex の設定を書き換えない（SANDBOX_SKIP_AGENT_SETUP）。
    """
    if BACKEND == "native":
        setup = [] if agent_setup else ["SANDBOX_SKIP_AGENT_SETUP=1"]
        return [
            "env",
            f"OLLAMA_MODELS={NATIVE_MODELS_DIR}",
            *env,
            *setup,
            f"CLINE_MODEL={tag}",
            "bash",
            str(ENTRYPOINT),
            *command,
        ]
    options = ["podman", "run", "--rm", f"--network={network}"]
    for mount in mounts:
        options += ["-v", mount]
    options += ["-v", f"{MODEL_VOLUME}:/models", "-e", "OLLAMA_MODELS=/models"]
    for item in env:
        options += ["-e", item]
    return options + ["-e", f"CLINE_MODEL={tag}", IMAGE, *command]


def prepare_command(model: Model) -> list[str]:
    if model.gguf is None:
        return container_command(model.tag, ["ollama", "pull", model.tag], network="host")
    source = model.gguf
    script = str(IMPORT_SCRIPT) if BACKEND == "native" else "/opt/import_gguf_model.sh"
    return container_command(
        model.tag,
        [
            "bash",
            script,
            model.tag,
            source.url,
            source.sha256,
            str(source.size),
            source.template_from,
            *source.parameters,
        ],
        network="host",
        # serve 起動時の未参照 blob 掃除で、取得途中の GGUF を消されないようにする
        env=("OLLAMA_NOPRUNE=1",),
        mounts=(f"{IMPORT_SCRIPT}:/opt/import_gguf_model.sh:ro",),
    )


def prepare_model(model: Model) -> None:
    ensure_volume()
    print(f"\n{model.tag} をモデルvolumeへダウンロードします。")
    print("この操作には大容量の通信とディスク容量が必要です。\n")
    run(prepare_command(model))


def downloaded_models() -> set[str]:
    """Return model tags currently stored in the shared Ollama volume."""
    ensure_volume()
    result = subprocess.run(
        container_command(ENTRYPOINT_MODEL, ["ollama", "list"]),
        check=True,
        stdin=subprocess.DEVNULL,
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
    run(container_command(model.tag, ["ollama", "rm", model.tag]))
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
        container_command(model.tag, ["ollama", "show", model.tag]),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def launch_command(model: Model, *, allow_network: bool = False) -> list[str]:
    """sandbox の起動コマンド。allow_network なら許可リスト付きプロキシ経由（scripts/proxy.sh）。

    native では隔離が無く、作業ディレクトリ NATIVE_WORKSPACE でシェルを開く。
    """
    if BACKEND == "native":
        if allow_network:
            raise RuntimeError("native モードにはネットワーク許可モードがありません。")
        return ["env", "-C", str(NATIVE_WORKSPACE),
                *container_command(model.tag, [], agent_setup=True)]
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
    if BACKEND == "native":
        print(
            "\n★ native モードです。コンテナによる隔離はありません（ネットワーク・ファイルとも、"
            "この環境の制限だけが効きます）。"
            f"\n  作業ディレクトリ: {NATIVE_WORKSPACE}"
        )
    if allow_network:
        print(
            "\n★ ネットワーク許可モードです。sandbox から sandbox/proxy/allowlist のドメインへ"
            "通信できます（それ以外・ホスト・DNS は遮断）。"
        )
    where = "シェル" if BACKEND == "native" else "コンテナ"
    print(f"\n{model.tag} でsandboxを起動します。終了するには{where}でexitしてください。\n")
    run(launch_command(model, allow_network=allow_network))


def title() -> str:
    if BACKEND != "native":
        return "Cline Sandbox Launcher"
    where = "コンテナ内" if inside_container() else "podman なし"
    return f"Cline Sandbox Launcher（native モード: {where}のため、コンテナを使わず直接実行します）"


def menu_options() -> list[tuple[str, str]]:
    options = [
        ("モデルをダウンロード", "prepare"),
        ("sandboxを起動", "launch"),
        ("ダウンロードしてsandboxを起動", "prepare_launch"),
        ("sandboxを起動（ネットワーク許可: 許可リストのみ）", "launch_proxy"),
        ("ダウンロード済みモデルを削除", "delete"),
        ("終了", "exit"),
    ]
    if BACKEND == "native":
        options = [option for option in options if option[1] != "launch_proxy"]
    return options


def main() -> int:
    try:
        ensure_prerequisites()
        while True:
            action = select_option(title(), menu_options())
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
