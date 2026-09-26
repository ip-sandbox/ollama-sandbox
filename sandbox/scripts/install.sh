#!/bin/bash
# install.sh - Ollama・Cline CLI・Codex CLI・Copilot CLI を検証済みの版で入れる（root で実行）
#
#   install.sh [--with-smollm | --check]
#
# sandbox イメージのビルド（Containerfile）と、すでにコンテナ内にいる環境での native モード
# （scripts/launcher.py）の両方がこれを使う。版の定義はここだけに置く。
# 入っている版が一致する部品は入れ直さないので、何度実行してもよい。
#   --with-smollm : entrypoint の既定モデル smollm:135m も取得する（イメージをオフラインで使うため）
#   --check       : 何も入れずに、すべて検証済みの版で入っているかだけを確かめる（root 不要）
set -euo pipefail

OLLAMA_VERSION="${OLLAMA_VERSION:-0.34.2}"
CLINE_VERSION="${CLINE_VERSION:-3.0.64}"
CODEX_VERSION="${CODEX_VERSION:-0.156.1}"
COPILOT_VERSION="${COPILOT_VERSION:-1.0.88}"
NODE_MAJOR="${NODE_MAJOR:-22}"
PRELOAD_DIR=/usr/local/lib/cline
# Cline CLI は起動のたびに（--version でも）npm の最新版を確かめて自動更新するので、止めて版を固定する
export CLINE_NO_AUTO_UPDATE=1
# Copilot CLI も自動更新を止める（npm 版は新しい版を知らせるだけだが、念のため）
export COPILOT_AUTO_UPDATE=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

node_ok()   { [ "$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')" = "$NODE_MAJOR" ]; }
ollama_ok() { ollama --version 2>&1 | grep -q "version is $OLLAMA_VERSION\$"; }
agents_ok() {
    [ "$(cline --version 2>/dev/null)" = "$CLINE_VERSION" ] \
        && [ "$(codex --version 2>/dev/null)" = "codex-cli $CODEX_VERSION" ] \
        && [ "$(copilot --version 2>/dev/null | sed -n 1p)" = "GitHub Copilot CLI $COPILOT_VERSION." ]
}
preload_ok() { [ -f "$PRELOAD_DIR/bun-fetch-no-timeout.js" ]; }

WITH_SMOLLM=0
case "${1:-}" in
    --with-smollm) WITH_SMOLLM=1 ;;
    --check)
        ok=0
        node_ok    || { echo "[install] Node.js $NODE_MAJOR がありません" >&2; ok=1; }
        ollama_ok  || { echo "[install] Ollama $OLLAMA_VERSION がありません" >&2; ok=1; }
        agents_ok  || { echo "[install] cline $CLINE_VERSION / codex $CODEX_VERSION / copilot $COPILOT_VERSION がありません" >&2; ok=1; }
        preload_ok || { echo "[install] $PRELOAD_DIR/bun-fetch-no-timeout.js がありません" >&2; ok=1; }
        exit "$ok"
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "[install] root で実行してください（apt と /usr/local への導入を行います）" >&2
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive

# 1. 基本ツール（python3 は launcher.py と import_gguf_model.sh が使う。
#    pciutils は Ollama のインストーラが GPU を検出するのに使う）
missing=()
for pkg in curl ca-certificates git procps tar zstd python3 pciutils; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "[install] apt: ${missing[*]}"
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
fi

# 2. Node.js
if ! node_ok; then
    echo "[install] Node.js $NODE_MAJOR"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y --no-install-recommends nodejs
    rm -rf /var/lib/apt/lists/*
fi
node --version

# 3. Ollama（systemd が無い環境では、公式スクリプトはサービス登録を飛ばすだけ）
if ! ollama_ok; then
    echo "[install] Ollama $OLLAMA_VERSION"
    curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$OLLAMA_VERSION" sh
fi
ollama --version 2>&1 | grep 'version is'

# 4. Cline CLI / Codex CLI / Copilot CLI
#    Copilot CLI は初回起動時に本体（約 165MB）を ~/.cache/copilot に展開する。--version でここで済ませておく
if ! agents_ok; then
    echo "[install] cline $CLINE_VERSION / codex $CODEX_VERSION / copilot $COPILOT_VERSION"
    npm install -g "cline@${CLINE_VERSION}" "@openai/codex@${CODEX_VERSION}" "@github/copilot@${COPILOT_VERSION}"
fi
echo "cline $(cline --version)"
codex --version
copilot --version | sed -n 1p

# 4.1 Cline CLI (Bun) の fetch 既定 300 秒タイムアウトを Ollama 宛てだけ外す preload
#     BUN_OPTIONS はイメージでは ENV、native モードでは entrypoint.sh が設定する
install -D -m 0644 "$SCRIPT_DIR/bun-fetch-no-timeout.js" "$PRELOAD_DIR/bun-fetch-no-timeout.js"

# 5. SmolLM 135M の事前取得（イメージ用）
if [ "$WITH_SMOLLM" = 1 ]; then
    ollama serve >/dev/null 2>&1 &
    serve_pid=$!
    until curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; do sleep 1; done
    ollama pull smollm:135m
    kill "$serve_pid"
    wait "$serve_pid" 2>/dev/null || true
fi

echo "[install] 完了"
