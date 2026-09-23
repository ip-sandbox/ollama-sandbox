# env.sh - cpu-timeout 検証スクリプト共通の環境（source して使う）

CT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT_STATE="$CT_DIR/.state"
CT_LOGS="$CT_STATE/logs"

NODE_VERSION="${NODE_VERSION:-v22.23.3}"
NODE_HOME="$HOME/.local/opt/node-$NODE_VERSION-linux-x64"
NPM_PREFIX="$HOME/.npm-global"
CLINE_VERSION="${CLINE_VERSION:-3.0.64}"

# ホストの ~/.cline を汚さないよう、検証用の cline 状態は隔離する
CLINE_DATA="${CLINE_DATA:-$CT_STATE/cline}"

# Python はホストが 3.9 なので uv で作った venv を使う
CT_VENV="$CT_DIR/.venv"
CT_PY="$CT_VENV/bin/python"

# Ollama はイメージから取り出したものを使う（コンテナと同じ版）
IMAGE="${IMAGE:-localhost/cline-sandbox:v2}"
OLLAMA_ROOT="$CT_STATE/ollama"
MODEL_VOLUME="${MODEL_VOLUME:-ollama-models}"
CLINE_MODEL="${CLINE_MODEL:-gemma4:12b-it-qat}"

export PATH="$NODE_HOME/bin:$NPM_PREFIX/bin:$OLLAMA_ROOT/bin:$PATH"
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"

mkdir -p "$CT_LOGS"

ct_log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
ct_die() { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; exit 1; }

# cline --data-dir 配下の providers.json（版によって位置が違うので両方見る）
ct_providers_json() {
  local d="${1:-$CLINE_DATA}"
  for p in "$d/settings/providers.json" "$d/data/settings/providers.json"; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  printf '%s\n' "$d/settings/providers.json"
}
