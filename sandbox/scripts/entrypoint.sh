#!/bin/bash
set -e

if [ -z "${CLINE_MODEL:-}" ]; then
    echo "[entrypoint] Error: CLINE_MODEL is not set." >&2
    echo "[entrypoint] Select a model with the launcher or pass -e CLINE_MODEL=<model>." >&2
    exit 1
fi

# Ollama の設定（-e で上書き可）
#   LOAD_TIMEOUT   : モデルロードの停滞許容時間。CPU 機のロードで既定 5m に当たらないように
#   KEEP_ALIVE     : CPU では 1 ターンが 5 分を超えるので常駐させ、prompt cache を活かす
#   CONTEXT_LENGTH : Codex（/v1/responses）は num_ctx を送らないため、既定（CPU では 4k）だと
#                    プロンプトが黙って切り詰められる。Cline は自分で 32768 を送る
export OLLAMA_LOAD_TIMEOUT="${OLLAMA_LOAD_TIMEOUT:-30m}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"

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

# --- Cline CLI -------------------------------------------------------------
# 3.x の設定は ~/.cline/data/settings/providers.json。cline auth に作らせてから、
# Ollama リクエストのタイムアウト（settings.timeout, ms。既定 300000）を延ばす。
# Bun fetch 側の 300 秒は Containerfile の BUN_OPTIONS preload で外している。
CLINE_TIMEOUT_MS="${CLINE_TIMEOUT_MS:-1800000}"
CLINE_PROVIDERS="$HOME/.cline/data/settings/providers.json"
if ! grep -q '"ollama"' "$CLINE_PROVIDERS" 2>/dev/null; then
    echo "[entrypoint] Configuring Cline for Ollama ($CLINE_MODEL, timeout ${CLINE_TIMEOUT_MS}ms)..."
    cline auth -p ollama -m "$CLINE_MODEL" -k ollama > /dev/null
    node - "$CLINE_PROVIDERS" "$CLINE_TIMEOUT_MS" <<'JS'
const fs = require("fs");
const [pj, ms] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(pj, "utf8"));
cfg.providers.ollama.settings.timeout = Number(ms);
cfg.lastUsedProvider = "ollama";
fs.writeFileSync(pj, JSON.stringify(cfg, null, 2) + "\n");
JS
fi

# --- Codex CLI -------------------------------------------------------------
# プロバイダ ID "ollama" は Codex の組み込みで予約済みなので ollama-local とする。
# wire_api は "responses" のみ有効（"chat" は 0.154 以降起動時に拒否される）。
# コンテナ自体が隔離境界であり、Codex の seccomp/landlock はコンテナ内で動かないため
# sandbox_mode は danger-full-access。承認は既定 on-request。全自動にするには
#   起動時 -e CODEX_APPROVAL_POLICY=never / codex -a never / codex exec -c approval_policy='"never"'
#   / TUI 内で /permissions
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-on-request}"
CODEX_STREAM_IDLE_TIMEOUT_MS="${CODEX_STREAM_IDLE_TIMEOUT_MS:-1800000}"
if [ ! -f "$CODEX_HOME/config.toml" ]; then
    echo "[entrypoint] Configuring Codex for Ollama ($CLINE_MODEL, approval $CODEX_APPROVAL_POLICY)..."
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<EOF
model = "$CLINE_MODEL"
model_provider = "ollama-local"
model_context_window = $OLLAMA_CONTEXT_LENGTH
approval_policy = "$CODEX_APPROVAL_POLICY"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[model_providers.ollama-local]
name = "Ollama (local)"
base_url = "http://127.0.0.1:11434/v1"
wire_api = "responses"
stream_idle_timeout_ms = $CODEX_STREAM_IDLE_TIMEOUT_MS
request_max_retries = 0
stream_max_retries = 0

[projects."/workspace"]
trust_level = "trusted"
EOF
fi

cat <<EOF
[entrypoint] Ready. model=$CLINE_MODEL
  cline                                  # Cline CLI（プロンプトは引数かパイプで渡す）
  codex                                  # Codex CLI（承認: $CODEX_APPROVAL_POLICY）
  codex -a never                         # Codex を全自動で起動（セッション中は /permissions で変更）
  codex exec -c approval_policy='"never"' "<prompt>"   # 非対話・全自動
  ※ CPU 推論では 1 ターン目に 10 分以上かかることがあります
EOF

# コマンド引数があれば実行、なければ bash を起動
if [ $# -gt 0 ]; then
    echo "[entrypoint] Executing command: $@"
    exec "$@"
else
    exec /bin/bash
fi
