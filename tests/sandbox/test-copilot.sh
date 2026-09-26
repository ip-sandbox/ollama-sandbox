#!/bin/bash
# test-copilot.sh - Copilot CLI が entrypoint の設定どおり Ollama（オフライン）につながるかを確かめる
#
# entrypoint.sh の設定が済んだ環境（sandbox コンテナ、または native モード）の中で、作業ディレクトリから実行する。
# smollm:135m はツール呼び出しに対応していないので、応答の中身ではなく、Copilot のリクエストが
# Ollama の /v1/responses に届くことと、GitHub に接続しないことを確かめる。
set -u
COPILOT_VERSION="${COPILOT_VERSION:-1.0.88}"
OLLAMA_LOG="${OLLAMA_LOG:-/var/log/ollama.log}"
[ -f "$OLLAMA_LOG" ] || OLLAMA_LOG="$HOME/.ollama/serve.log"
fail=0
check() {
    if eval "$2"; then echo "  ✔ $1"; else echo "  ✘ $1"; fail=1; fi
}

check "copilot --version が $COPILOT_VERSION" \
    '[ "$(copilot --version 2>/dev/null | sed -n 1p)" = "GitHub Copilot CLI $COPILOT_VERSION." ]'
check "BYOK の接続先が Ollama（$COPILOT_PROVIDER_BASE_URL）" \
    '[ "${COPILOT_PROVIDER_BASE_URL:-}" = "http://127.0.0.1:11434/v1" ] && [ "${COPILOT_PROVIDER_WIRE_API:-}" = responses ]'
check "モデルが CLINE_MODEL（$CLINE_MODEL）" '[ "${COPILOT_MODEL:-}" = "$CLINE_MODEL" ]'
check "オフライン・自動更新なし" '[ "${COPILOT_OFFLINE:-}" = true ] && [ "${COPILOT_AUTO_UPDATE:-}" = false ]'
check "作業ディレクトリ $PWD が信頼済み（~/.copilot/config.json）" \
    'sed "/^\s*\/\//d" "$HOME/.copilot/config.json" | node -e "
        const c = JSON.parse(require(\"fs\").readFileSync(0, \"utf8\"));
        process.exit((c.trustedFolders || []).includes(process.argv[1]) ? 0 : 1)" "$PWD"'

before=$(grep -c 'POST .*"/v1/responses"' "$OLLAMA_LOG" 2>/dev/null)
logdir=$(mktemp -d)
timeout 300 copilot -p "Reply with the single word OK." --allow-all-tools --no-ask-user \
    --log-dir "$logdir" </dev/null >"$logdir/out.txt" 2>&1
rc=$?
after=$(grep -c 'POST .*"/v1/responses"' "$OLLAMA_LOG" 2>/dev/null)
echo "  copilot -p: rc=$rc, 応答: $(grep -v '^\s*$' "$logdir/out.txt" | head -3 | tr '\n' ' ' | cut -c1-160)"
check "リクエストが Ollama の /v1/responses に届いた（$before → $after）" '[ "$after" -gt "$before" ]'
check "オフラインモードで動いた（GitHub に接続しない）" 'grep -q "Running in offline mode" "$logdir"/*.log'
rm -rf "$logdir"

[ "$fail" = 0 ] && echo "copilot OK"
exit "$fail"
