#!/usr/bin/env bash
# setup-host.sh - ホスト（Podman の外）に Node 22 / Cline CLI / Ollama / Python venv を用意する
#
#   - Node   : nodejs.org の公式 tarball を ~/.local/opt に展開（sudo 不要）
#   - Cline  : イメージと同じ版を ~/.npm-global に npm install -g
#   - Python : uv で cpu-timeout/.venv に 3.12 を用意（ホストは 3.9）
#   - Ollama : 既存イメージから bin と CPU 用ライブラリだけ取り出す（cuda/vulkan は除外）
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

ct_log "1. Node $NODE_VERSION"
if [ ! -x "$NODE_HOME/bin/node" ]; then
  mkdir -p "$HOME/.local/opt"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-x64.tar.xz" \
    | tar -xJ -C "$HOME/.local/opt"
fi
ct_log "   node $(node --version) / npm $(npm --version)"

ct_log "2. Cline CLI $CLINE_VERSION"
if [ "$(cline --version 2>/dev/null || true)" != "$CLINE_VERSION" ]; then
  npm install -g --prefix "$NPM_PREFIX" "cline@$CLINE_VERSION"
fi
ct_log "   cline $(cline --version)"

ct_log "3. Python venv (uv)"
if [ ! -x "$CT_PY" ]; then
  uv venv --python 3.12 "$CT_VENV"
fi
ct_log "   $("$CT_PY" --version)"

ct_log "4. Ollama（$IMAGE から取り出し）"
if [ ! -x "$OLLAMA_ROOT/bin/ollama" ]; then
  mkdir -p "$OLLAMA_ROOT/bin" "$OLLAMA_ROOT/lib"
  cid="$(podman create "$IMAGE")"
  trap 'podman rm -f "$cid" >/dev/null 2>&1 || true' EXIT
  podman cp "$cid:/usr/local/bin/ollama" "$OLLAMA_ROOT/bin/ollama"
  tmp="$CT_STATE/ollama-lib.tmp"
  rm -rf "$tmp"
  podman cp "$cid:/usr/local/lib/ollama" "$tmp"
  # GPU 用（約2GB）は要らない
  rm -rf "$tmp/cuda_v12" "$tmp/cuda_v13" "$tmp/vulkan"
  rm -rf "$OLLAMA_ROOT/lib/ollama"
  mv "$tmp" "$OLLAMA_ROOT/lib/ollama"
fi
# ollama は実行ファイルの ../lib/ollama からライブラリを探す
ct_log "   $(ollama --version 2>&1 | tail -1)"

ct_log "完了。使用量: $(du -sh "$NODE_HOME" "$NPM_PREFIX/lib/node_modules/cline" "$OLLAMA_ROOT" "$CT_VENV" 2>/dev/null | awk '{print $1}' | paste -sd' ')"
