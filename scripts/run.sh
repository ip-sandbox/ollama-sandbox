#!/bin/bash
set -e

# スクリプト自身のディレクトリからプロジェクトルートを特定
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$DIR/sandbox/workspace"
. "$DIR/scripts/config.sh"
mkdir -p "$WORKSPACE_DIR"

if [ "$#" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    exec python3 "$DIR/scripts/launcher.py"
fi

# コマンドを直接渡すときは、使うモデルを CLINE_MODEL で指定する（例: CLINE_MODEL=qwen3:8b ./scripts/run.sh cline）
MODEL_ARGS=(-v "$MODEL_VOLUME:/models" -e OLLAMA_MODELS=/models)
[ -n "${CLINE_MODEL:-}" ] && MODEL_ARGS+=(-e "CLINE_MODEL=$CLINE_MODEL")

# SANDBOX_NETWORK=proxy で、許可リストのドメインにだけ出られるネットワーク許可モードになる（scripts/proxy.sh）
if [ "${SANDBOX_NETWORK:-none}" = proxy ]; then
    echo "=== Starting Ollama Sandbox (network: allowlist proxy) ==="
    exec bash "$DIR/scripts/proxy.sh" run -it \
        -v "$WORKSPACE_DIR:/workspace:rw" \
        "${MODEL_ARGS[@]}" \
        "$SANDBOX_IMAGE" \
        "$@"
fi

echo "=== Starting Ollama Sandbox (--network=none) ==="
podman run --rm -it \
    --network=none \
    -v "$WORKSPACE_DIR:/workspace:rw" \
    "${MODEL_ARGS[@]}" \
    "$SANDBOX_IMAGE" \
    "$@"
