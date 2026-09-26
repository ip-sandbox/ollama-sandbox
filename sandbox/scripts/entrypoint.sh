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

# Ollama サーバーをバックグラウンドで起動する。
# native モード（コンテナを使わず launcher.py から実行）では、すでに起動している serve を使い回す
OLLAMA_LOG="${OLLAMA_LOG:-/var/log/ollama.log}"
if ! { : >>"$OLLAMA_LOG"; } 2>/dev/null; then
    OLLAMA_LOG="$HOME/.ollama/serve.log"
    mkdir -p "$(dirname "$OLLAMA_LOG")"
fi
if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
    echo "[entrypoint] Ollama server is already running."
else
    echo "[entrypoint] Starting Ollama server in background (log: $OLLAMA_LOG)..."
    # 別セッションにして、端末の Ctrl-C（エージェントの中断）で serve まで止まらないようにする
    setsid ollama serve < /dev/null > "$OLLAMA_LOG" 2>&1 &

    # Ollama API のヘルスチェック（起動完了待ち）
    echo "[entrypoint] Waiting for Ollama API to be ready..."
    TIMEOUT=30
    COUNT=0
    until curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do
        sleep 1
        COUNT=$((COUNT + 1))
        if [ $COUNT -ge $TIMEOUT ]; then
            echo "[entrypoint] Error: Timeout waiting for Ollama server."
            cat "$OLLAMA_LOG"
            exit 1
        fi
    done
    echo "[entrypoint] Ollama API is ready."
fi

# モデルの管理（ollama list / pull / rm など）だけのときは、Cline / Codex の設定を飛ばす。
# native モードの launcher.py が指定する（HOME の設定を、起動中のモデル以外に書き換えないため）
if [ "${SANDBOX_SKIP_AGENT_SETUP:-0}" = 1 ] && [ $# -gt 0 ]; then
    exec "$@"
fi

# --- Cline CLI -------------------------------------------------------------
# 3.x の設定は ~/.cline/data/settings/providers.json。初回は cline auth に作らせる。
# 毎回、モデルと Ollama リクエストのタイムアウト（settings.timeout, ms。既定 300000）を合わせる
# （native モードでは HOME が残るので、モデルを切り替えたときに古い設定を使わないように）。
# Bun fetch 側の 300 秒は BUN_OPTIONS の preload で外す（イメージでは Containerfile の ENV）。
# Cline の自動更新（起動のたびに npm から最新版を入れる）は止めて、検証済みの版に固定する
export CLINE_NO_AUTO_UPDATE="${CLINE_NO_AUTO_UPDATE:-1}"
CLINE_PRELOAD=/usr/local/lib/cline/bun-fetch-no-timeout.js
if [ -z "${BUN_OPTIONS:-}" ] && [ -f "$CLINE_PRELOAD" ]; then
    export BUN_OPTIONS="--preload $CLINE_PRELOAD"
fi
CLINE_TIMEOUT_MS="${CLINE_TIMEOUT_MS:-1800000}"
CLINE_PROVIDERS="$HOME/.cline/data/settings/providers.json"
echo "[entrypoint] Configuring Cline for Ollama ($CLINE_MODEL, timeout ${CLINE_TIMEOUT_MS}ms)..."
if ! grep -q '"ollama"' "$CLINE_PROVIDERS" 2>/dev/null; then
    cline auth -p ollama -m "$CLINE_MODEL" -k ollama > /dev/null
fi
node - "$CLINE_PROVIDERS" "$CLINE_MODEL" "$CLINE_TIMEOUT_MS" <<'JS'
const fs = require("fs");
const [pj, model, ms] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(pj, "utf8"));
cfg.providers.ollama.settings.model = model;
cfg.providers.ollama.settings.timeout = Number(ms);
cfg.lastUsedProvider = "ollama";
fs.writeFileSync(pj, JSON.stringify(cfg, null, 2) + "\n");
JS

# --- Codex CLI -------------------------------------------------------------
# プロバイダ ID "ollama" は Codex の組み込みで予約済みなので ollama-local とする。
# wire_api は "responses" のみ有効（"chat" は 0.154 以降起動時に拒否される）。
# コンテナ（native モードでは外側のコンテナ）自体が隔離境界であり、Codex の seccomp/landlock はコンテナ内で動かないため
# sandbox_mode は danger-full-access。承認は既定 on-request。全自動にするには
#   起動時 -e CODEX_APPROVAL_POLICY=never / codex -a never / codex exec -c approval_policy='"never"'
#   / TUI 内で /permissions
# 設定は毎回書き直す（Cline と同じ理由）。ただし、この entrypoint が書いたもの（先頭の目印行）
# 以外の既存の config.toml は、利用者自身の設定とみなして触らない。
# 信頼するディレクトリは作業ディレクトリ（イメージでは /workspace）。
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-on-request}"
CODEX_STREAM_IDLE_TIMEOUT_MS="${CODEX_STREAM_IDLE_TIMEOUT_MS:-1800000}"
CODEX_CONFIG="$CODEX_HOME/config.toml"
CODEX_MARKER="# managed by cline-sandbox entrypoint.sh"
if [ -f "$CODEX_CONFIG" ] && [ "$(head -1 "$CODEX_CONFIG")" != "$CODEX_MARKER" ]; then
    echo "[entrypoint] Warning: $CODEX_CONFIG は既存の設定なので変更しません（Codex は Ollama を使わない可能性があります）。" >&2
    echo "[entrypoint]          CODEX_HOME を別のディレクトリにすると、そこに Ollama 用の設定を作ります。" >&2
else
    echo "[entrypoint] Configuring Codex for Ollama ($CLINE_MODEL, approval $CODEX_APPROVAL_POLICY)..."
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_CONFIG" <<EOF
$CODEX_MARKER
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

[projects."$PWD"]
trust_level = "trusted"
EOF
fi

# --- GitHub Copilot CLI ----------------------------------------------------
# BYOK（自前のモデル提供元）で Ollama の /v1/responses につなぐ。設定は環境変数だけで、ファイルは要らない。
# オフラインモードにして GitHub には一切接続しない（ログイン・テレメトリ・Web ツール・自動更新が無効になる）。
# API キーは設定しない（Ollama には不要で、設定すると失敗することがある）。
# Copilot CLI は無音が 600 秒続くと切って最大 5 回送り直す（変更する設定は無い）。Ollama は切られるまでに
# 処理したプロンプトをキャッシュに残すので、CPU で prefill が 600 秒を超えても送り直しのたびに続きから進む
# （docs/results/COPILOT_RESULT.md）。
export COPILOT_PROVIDER_BASE_URL="${COPILOT_PROVIDER_BASE_URL:-http://127.0.0.1:11434/v1}"
export COPILOT_PROVIDER_WIRE_API="${COPILOT_PROVIDER_WIRE_API:-responses}"
export COPILOT_MODEL="${COPILOT_MODEL:-$CLINE_MODEL}"
export COPILOT_OFFLINE="${COPILOT_OFFLINE:-true}"
export COPILOT_AUTO_UPDATE="${COPILOT_AUTO_UPDATE:-false}"
# 組み込みのカタログに無いモデルは既定の上限になるので、Ollama のコンテキスト長に合わせる
export COPILOT_PROVIDER_MAX_PROMPT_TOKENS="${COPILOT_PROVIDER_MAX_PROMPT_TOKENS:-$((OLLAMA_CONTEXT_LENGTH - 4096))}"
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS="${COPILOT_PROVIDER_MAX_OUTPUT_TOKENS:-4096}"
# 作業ディレクトリを信頼済みフォルダ（~/.copilot/config.json の trustedFolders）に追加し、起動時の確認を省く。
# 既存の設定は残して追記だけする（読めない形式なら触らない）
COPILOT_CONFIG="${COPILOT_HOME:-$HOME/.copilot}/config.json"
echo "[entrypoint] Configuring Copilot CLI for Ollama ($COPILOT_MODEL, offline=$COPILOT_OFFLINE)..."
mkdir -p "$(dirname "$COPILOT_CONFIG")"
node - "$COPILOT_CONFIG" "$PWD" <<'JS' || echo "[entrypoint] Warning: $COPILOT_CONFIG を更新できませんでした（起動時にフォルダの信頼を確認されます）。" >&2
const fs = require("fs");
const [file, dir] = process.argv.slice(2);
let cfg = {};
if (fs.existsSync(file)) {
  // Copilot CLI は先頭に // のコメント行を付けて書く
  const body = fs.readFileSync(file, "utf8").replace(/^\s*\/\/.*$/gm, "");
  cfg = body.trim() ? JSON.parse(body) : {};
}
const trusted = Array.isArray(cfg.trustedFolders) ? cfg.trustedFolders : [];
if (!trusted.includes(dir)) {
  cfg.trustedFolders = [...trusted, dir];
  fs.writeFileSync(file, "// User settings belong in settings.json.\n// This file is managed automatically.\n"
    + JSON.stringify(cfg, null, 2) + "\n");
}
JS

cat <<EOF
[entrypoint] Ready. model=$CLINE_MODEL
  cline                                  # Cline CLI（プロンプトは引数かパイプで渡す）
  codex                                  # Codex CLI（承認: $CODEX_APPROVAL_POLICY）
  codex -a never                         # Codex を全自動で起動（セッション中は /permissions で変更）
  codex exec -c approval_policy='"never"' "<prompt>"   # 非対話・全自動
  copilot                                # GitHub Copilot CLI（Ollama・オフライン。ツールの実行は都度確認）
  copilot --allow-all-tools              # Copilot を全自動で起動
  copilot -p "<prompt>" --allow-all-tools              # 非対話・全自動
  ※ CPU 推論では 1 ターン目に 10 分以上かかることがあります
EOF

# コマンド引数があれば実行、なければ bash を起動
if [ $# -gt 0 ]; then
    echo "[entrypoint] Executing command: $@"
    exec "$@"
else
    exec /bin/bash
fi
