#!/bin/bash
set -e

if [ -z "${CLINE_MODEL:-}" ]; then
    echo "[entrypoint] Error: CLINE_MODEL is not set." >&2
    echo "[entrypoint] Select a model with the launcher or pass -e CLINE_MODEL=<model>." >&2
    exit 1
fi

# Ollama サーバーをバックグラウンドで起動
echo "[entrypoint] Starting Ollama server in background..."
ollama serve > /var/log/ollama.log 2>&1 &
OLLAMA_PID=$!

# Ollama API のヘルスチェック（起動完了待ち）
echo "[entrypoint] Waiting for Ollama API to be ready..."
TIMEOUT=30
COUNT=0
until curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do
    sleep 1
    COUNT=$((COUNT + 1))
    if [ $COUNT -ge $TIMEOUT ]; then
        echo "[entrypoint] Error: Timeout waiting for Ollama server."
        cat /var/log/ollama.log
        exit 1
    fi
done
echo "[entrypoint] Ollama API is ready."

# Cline の設定確認・生成 (~/.cline/settings.json)
CLINE_CONFIG_DIR="$HOME/.cline"
mkdir -p "$CLINE_CONFIG_DIR"
if [ ! -f "$CLINE_CONFIG_DIR/settings.json" ]; then
    echo "[entrypoint] Initializing Cline settings for Ollama ($CLINE_MODEL)..."
    cat <<EOF > "$CLINE_CONFIG_DIR/settings.json"
{
  "apiProvider": "ollama",
  "ollamaModelId": "$CLINE_MODEL",
  "ollamaBaseUrl": "http://127.0.0.1:11434"
}
EOF
fi

# コマンド引数があれば実行、なければ bash を起動
if [ $# -gt 0 ]; then
    echo "[entrypoint] Executing command: $@"
    exec "$@"
else
    exec /bin/bash
fi
