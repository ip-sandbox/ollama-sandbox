#!/usr/bin/env bash
# e2e.sh - sandbox イメージの既定設定のまま、実モデル（CPU）で Cline / Codex の実タスクを走らせる
#
#   e2e.sh --agent cline|codex [--model M] [--codex-catalog DUMP] [--debug]
#
#   --model          Ollama のモデル名（既定: env.sh の CLINE_MODEL）
#   --codex-catalog  Codex に model_catalog_json（apply_patch_tool_type=freeform）を渡す。
#                    DUMP は models/probe-apply-patch.sh が保存した fallback 時のリクエスト本体で、
#                    その instructions をカタログに流用する（docs/results/APPLY_PATCH_RESULT.md）
#   --debug          Codex を RUST_LOG=codex_core=debug で動かし、ツールルータのログを集計に出す
#   E2E_MAX_SEC      打ち切り秒数（既定 7200）
#
# launcher.py の launch() と同じ podman run（--network=none、model volume）で起動する。
# 追加のマウントはワークスペース以外付けない。コンテナは毎回新規なので、モデルは cold から始まる。
# 判定は rc ではなく hello.txt の中身で行う（rc=0 でもファイルを作らないモデルがある）。
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"

AGENT="" MODEL="$CLINE_MODEL" CATALOG_DUMP="" DEBUG=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --codex-catalog) CATALOG_DUMP="$2"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    *) rs_die "unknown option: $1（使い方はスクリプト冒頭のコメント参照）" ;;
  esac
done
case "$AGENT" in cline|codex) ;; *) rs_die "--agent cline|codex を指定してください" ;; esac
[ -z "$CATALOG_DUMP" ] || [ "$AGENT" = codex ] || rs_die "--codex-catalog は --agent codex 専用です"

MAX="${E2E_MAX_SEC:-7200}"
SAFE_MODEL="$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9._-' '-')"
tag="$(date +%Y%m%d-%H%M%S)-$AGENT-$SAFE_MODEL${CATALOG_DUMP:+-freeform}"
d="$RS_STATE/e2e/$tag"
mkdir -p "$d/ws"
printf 'Create a file named hello.txt in the current directory containing exactly the text: hello from %s. Then finish the task.\n' \
  "$AGENT" >"$d/ws/.prompt.txt"

case "$AGENT" in
  cline) CMD='cat /workspace/.prompt.txt | cline --thinking none' ;;
  codex)
    CMD='codex exec --skip-git-repo-check -c approval_policy="\"never\""'
    if [ -n "$CATALOG_DUMP" ]; then
      "$RS_PY" "$RS_DIR/models/make_codex_catalog.py" "$MODEL" freeform "$CATALOG_DUMP" >"$d/ws/.catalog.json"
      CMD="$CMD --strict-config -c model_catalog_json='\"/workspace/.catalog.json\"'"
    fi
    CMD="$CMD - </workspace/.prompt.txt" ;;
esac
extra_env=()
[ "$DEBUG" = 1 ] && extra_env=(-e RUST_LOG=codex_core=debug)

rs_log "E2E $tag"
st=$(date +%s)
set +e
timeout "$MAX" podman run --rm --network=none \
  -v "$d/ws:/workspace:rw" \
  -v "$MODEL_VOLUME:/models" \
  -e OLLAMA_MODELS=/models \
  -e CLINE_MODEL="$MODEL" \
  "${extra_env[@]}" \
  "$IMAGE" \
  bash -c "$CMD; rc=\$?; cp /var/log/ollama.log /workspace/.ollama.log; exit \$rc" >"$d/run.log" 2>&1
rc=$?
set -e
el=$(( $(date +%s) - st ))

{
  echo "tag=$tag"
  echo "agent=$AGENT model=$MODEL"
  echo "elapsed_sec=$el rc=$rc"
  echo "hello.txt=$(cat "$d/ws/hello.txt" 2>/dev/null || echo '(なし)')"
  echo "error=$(grep -avE '^\[entrypoint\]|^  ' "$d/run.log" | grep -aiE -m1 'timed out|timeout|error' | cut -c1-200 || echo none)"
  if [ "$AGENT" = codex ]; then
    echo "--- codex tool router"
    grep -aoE 'unsupported call: [a-z_]+|invoked with incompatible payload' "$d/run.log" | sort | uniq -c || true
  fi
  echo "--- ollama requests"
  grep -E 'POST +"/(v1/responses|api/chat)"' "$d/ws/.ollama.log" 2>/dev/null \
    | sed -E 's/.*\| *([0-9]+) \| *([^|]+)\|.*(POST[^"]*"[^"]+").*/status=\1 duration=\2 \3/' || true
  echo "--- prefill (llama.cpp slot)"
  grep -E 'prompt eval time|truncated' "$d/ws/.ollama.log" 2>/dev/null \
    | sed -E 's/.*prompt eval time = *([0-9.]+) ms \/ *([0-9]+) tokens.*/prefill \2 tok in \1 ms/; s/.*n_tokens = ([0-9]+), truncated = ([0-9]+).*/  ctx=\1 truncated=\2/' || true
} | tee "$d/summary.txt"
