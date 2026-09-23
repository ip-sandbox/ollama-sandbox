#!/usr/bin/env bash
# run-e2e.sh - 本物の gemma4（CPU）で Cline CLI の実タスクを完走させる
#
#   run-e2e.sh [--no-fix]
#
#   既定   : 対策あり（BUN_OPTIONS preload + providers.json timeout）
#   --no-fix: 対策なし（再現用。300 秒付近で切れるはず）
#
# 環境変数: E2E_TIMEOUT_MS（既定 1800000）, E2E_MAX_SEC（全体の打ち切り, 既定 7200）,
#           E2E_THINKING（既定 none）
# 前提: ollama-host.sh start 済み
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

FIX=1
[ "${1:-}" = "--no-fix" ] && FIX=0
TMO="${E2E_TIMEOUT_MS:-1800000}"
MAX="${E2E_MAX_SEC:-7200}"
THINKING="${E2E_THINKING:-none}"

curl -s -m 2 "http://$OLLAMA_HOST/api/version" >/dev/null || ct_die "ollama が動いていません（ollama-host.sh start）"

tag="$(date +%Y%m%d-%H%M%S)-$([ $FIX = 1 ] && echo fix || echo nofix)"
d="$CT_STATE/e2e/$tag"
mkdir -p "$d/ws"
data="$d/cline"

if [ $FIX = 1 ]; then
  bash "$CT_DIR/set-timeout.sh" --data-dir "$data" --model "$CLINE_MODEL" --timeout-ms "$TMO"
  export BUN_OPTIONS="--preload $CT_DIR/bun-fetch-no-timeout.js"
  export CLINE_NO_FETCH_TIMEOUT_DEBUG=1
else
  cline auth -p ollama -m "$CLINE_MODEL" -k ollama --data-dir "$data" >/dev/null
  unset BUN_OPTIONS
fi
cp "$(ct_providers_json "$data")" "$d/providers.json"

# 日本語をコマンドライン引数に入れると Cline 3.x は落ちるので、英語で標準入力から渡す
PROMPT='Create a file named hello.txt in the current directory containing exactly the text: hello from gemma4 on cpu. Then finish the task.'
printf '%s\n' "$PROMPT" >"$d/prompt.txt"

ollama_log="$CT_LOGS/ollama.log"
log_from=$(wc -l <"$ollama_log")

ct_log "E2E $tag  model=$CLINE_MODEL thinking=$THINKING timeout=${TMO}ms fix=$FIX"
st=$(date +%s)
set +e
# ★ ファイルのリダイレクト（< file）だと "interactive mode requires a TTY" で落ちる。パイプで渡す
cat "$d/prompt.txt" | timeout "$MAX" cline -P ollama -m "$CLINE_MODEL" --thinking "$THINKING" \
  --data-dir "$data" --cwd "$d/ws" --auto-approve true >"$d/run.log" 2>&1
rc=$?
set -e
el=$(( $(date +%s) - st ))

tail -n +"$((log_from + 1))" "$ollama_log" >"$d/ollama.log"
content="$(cat "$d/ws/hello.txt" 2>/dev/null || echo '(なし)')"
chats="$(grep -c 'POST *"/api/chat"' "$d/ollama.log" || true)"
err="$(grep -aiE -m1 'timed out|abort|error' "$d/run.log" | cut -c1-200 || true)"

{
  echo "tag=$tag"
  echo "fix=$FIX timeout_ms=$TMO thinking=$THINKING"
  echo "elapsed_sec=$el rc=$rc"
  echo "chat_requests=$chats"
  echo "hello.txt=$content"
  echo "error=${err:-none}"
  echo "--- ollama /api/chat durations"
  grep 'POST *"/api/chat"' "$d/ollama.log" | sed -E 's/.*\| *([0-9]+) \| *([^|]+)\|.*/status=\1 duration=\2/' || true
} | tee "$d/summary.txt"
