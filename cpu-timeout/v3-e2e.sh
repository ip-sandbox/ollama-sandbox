#!/usr/bin/env bash
# v3-e2e.sh - cline-sandbox:v3 の既定設定のまま、実モデル（CPU）で Codex / Cline の実タスクを完走させる
#
#   v3-e2e.sh codex|cline
#
# launcher.py の launch() と同じ podman run（--network=none、ollama-models volume）で起動する。
# 追加のマウントや環境変数は付けない。コンテナは毎回新規なので、モデルは cold から始まる。
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

AGENT="${1:?usage: $0 codex|cline}"
IMAGE="${IMAGE_V3:-localhost/cline-sandbox:v3}"
MAX="${E2E_MAX_SEC:-5400}"
tag="$(date +%Y%m%d-%H%M%S)-$AGENT"
d="$CT_STATE/v3-e2e/$tag"
mkdir -p "$d/ws"
PROMPT='Create a file named hello.txt in the current directory containing exactly the text: hello from gemma4 on cpu. Then finish the task.'
printf '%s\n' "$PROMPT" >"$d/ws/.prompt.txt"

case "$AGENT" in
  codex) CMD='codex exec --skip-git-repo-check -c approval_policy="\"never\"" - </workspace/.prompt.txt' ;;
  cline) CMD='cat /workspace/.prompt.txt | cline --thinking none' ;;
  *) ct_die "unknown agent: $AGENT" ;;
esac

ct_log "v3 E2E $tag"
st=$(date +%s)
set +e
timeout "$MAX" podman run --rm --network=none \
  -v "$d/ws:/workspace:rw" \
  -v "$MODEL_VOLUME:/models" \
  -e OLLAMA_MODELS=/models \
  -e CLINE_MODEL="$CLINE_MODEL" \
  "$IMAGE" \
  bash -c "$CMD; rc=\$?; cp /var/log/ollama.log /workspace/.ollama.log; exit \$rc" >"$d/run.log" 2>&1
rc=$?
set -e
el=$(( $(date +%s) - st ))

{
  echo "tag=$tag"
  echo "elapsed_sec=$el rc=$rc"
  echo "hello.txt=$(cat "$d/ws/hello.txt" 2>/dev/null || echo '(なし)')"
  echo "error=$(grep -avE '^\[entrypoint\]|^  ' "$d/run.log" | grep -aiE -m1 'timed out|timeout|error' | cut -c1-200 || echo none)"
  echo "--- ollama requests"
  grep -E 'POST +"/(v1/responses|api/chat)"' "$d/ws/.ollama.log" 2>/dev/null | sed -E 's/.*\| *([0-9]+) \| *([^|]+)\|.*(POST[^"]*"[^"]+").*/status=\1 duration=\2 \3/' || true
  echo "--- prefill (llama.cpp slot)"
  grep -E 'prompt eval time|truncated' "$d/ws/.ollama.log" 2>/dev/null | sed -E 's/.*prompt eval time = *([0-9.]+) ms \/ *([0-9]+) tokens.*/prefill \2 tok in \1 ms/; s/.*n_tokens = ([0-9]+), truncated = ([0-9]+).*/  ctx=\1 truncated=\2/' || true
} | tee "$d/summary.txt"
