#!/usr/bin/env bash
# model-e2e-codex.sh - model-e2e.sh を元にした、任意の Ollama モデルで Codex CLI の実タスクを
# CPU 上で完走させる検証スクリプト（codex のみ、モデル非依存プロンプト）。
# codex 起動コマンドは v3-e2e.sh の codex ケースをそのまま使う。
#
#   model-e2e-codex.sh <model-tag>
#
# launcher.py の launch() と同じ podman run（--network=none、ollama-models volume）で起動する。
# 追加のマウントはワークスペース以外付けない。コンテナは毎回新規なので、モデルは cold から始まる。
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

MODEL="${1:?usage: $0 <model-tag>}"
IMAGE="${IMAGE_V3:-localhost/cline-sandbox:v3}"
MAX="${E2E_MAX_SEC:-5400}"
SAFE_MODEL="$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9._-' '-')"
tag="$(date +%Y%m%d-%H%M%S)-$SAFE_MODEL"
d="$CT_STATE/model-e2e-codex/$tag"
mkdir -p "$d/ws"
PROMPT='Create a file named hello.txt in the current directory containing exactly the text: hello from codex. Then finish the task.'
printf '%s\n' "$PROMPT" >"$d/ws/.prompt.txt"

CMD='codex exec --skip-git-repo-check -c approval_policy="\"never\"" - </workspace/.prompt.txt'

ct_log "model E2E (codex) $tag (model=$MODEL)"
st=$(date +%s)
set +e
timeout "$MAX" podman run --rm --network=none \
  -v "$d/ws:/workspace:rw" \
  -v "$MODEL_VOLUME:/models" \
  -e OLLAMA_MODELS=/models \
  -e CLINE_MODEL="$MODEL" \
  "$IMAGE" \
  bash -c "$CMD; rc=\$?; cp /var/log/ollama.log /workspace/.ollama.log; exit \$rc" >"$d/run.log" 2>&1
rc=$?
set -e
el=$(( $(date +%s) - st ))

{
  echo "tag=$tag"
  echo "model=$MODEL"
  echo "elapsed_sec=$el rc=$rc"
  echo "hello.txt=$(cat "$d/ws/hello.txt" 2>/dev/null || echo '(なし)')"
  echo "error=$(grep -avE '^\[entrypoint\]|^  ' "$d/run.log" | grep -aiE -m1 'timed out|timeout|error' | cut -c1-200 || echo none)"
  echo "--- ollama requests"
  grep -E 'POST +"/(v1/responses|api/chat)"' "$d/ws/.ollama.log" 2>/dev/null | sed -E 's/.*\| *([0-9]+) \| *([^|]+)\|.*(POST[^"]*"[^"]+").*/status=\1 duration=\2 \3/' || true
  echo "--- prefill (llama.cpp slot)"
  grep -E 'prompt eval time|truncated' "$d/ws/.ollama.log" 2>/dev/null | sed -E 's/.*prompt eval time = *([0-9.]+) ms \/ *([0-9]+) tokens.*/prefill \2 tok in \1 ms/; s/.*n_tokens = ([0-9]+), truncated = ([0-9]+).*/  ctx=\1 truncated=\2/' || true
} | tee "$d/summary.txt"
