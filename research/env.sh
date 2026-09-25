# env.sh - research/ 配下の検証スクリプト共通の環境（source して使う）
#
# 各スクリプトは `. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"` で読み込む。

RS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS_REPO="$(cd "$RS_DIR/.." && pwd)"
RS_STATE="$RS_DIR/.state"
RS_LOGS="$RS_STATE/logs"

# イメージ名と model volume は sandbox 本体と同じ定義を使う
. "$RS_REPO/scripts/config.sh"
IMAGE="$SANDBOX_IMAGE"

NODE_VERSION="${NODE_VERSION:-v22.23.3}"
NODE_HOME="$HOME/.local/opt/node-$NODE_VERSION-linux-x64"
NPM_PREFIX="$HOME/.npm-global"
CLINE_VERSION="${CLINE_VERSION:-3.0.64}"

# ホストの ~/.cline を汚さないよう、検証用の cline 状態は隔離する
CLINE_DATA="${CLINE_DATA:-$RS_STATE/cline}"

# Python はホストが 3.9 なので uv で作った venv を使う
RS_VENV="$RS_DIR/.venv"
RS_PY="$RS_VENV/bin/python"

# Cline（Bun）の fetch 300 秒タイムアウトを外す preload。本番イメージと同じファイルを使う
RS_PRELOAD="$RS_REPO/sandbox/scripts/bun-fetch-no-timeout.js"

# Ollama はイメージから取り出したものを使う（コンテナと同じ版）
OLLAMA_ROOT="$RS_STATE/ollama"
CLINE_MODEL="${CLINE_MODEL:-gemma4:12b-it-qat}"

export PATH="$NODE_HOME/bin:$NPM_PREFIX/bin:$OLLAMA_ROOT/bin:$PATH"
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"

mkdir -p "$RS_LOGS"

rs_log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
rs_die() { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; exit 1; }

# cline --data-dir 配下の providers.json（版によって位置が違うので両方見る）
rs_providers_json() {
  local d="${1:-$CLINE_DATA}"
  for p in "$d/settings/providers.json" "$d/data/settings/providers.json"; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  printf '%s\n' "$d/settings/providers.json"
}
