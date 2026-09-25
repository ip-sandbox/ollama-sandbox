#!/usr/bin/env bash
# apply-patch-e2e.sh - model_catalog_json で apply_patch ツールを載せた状態で、Codex の実タスクを走らせる
#
# model-e2e-codex.sh（カタログ無し = fallback metadata）と同じ条件・同じプロンプトで、
# カタログだけを足して比べる。カタログは probe-apply-patch.sh が保存した fallback 時の
# instructions をそのまま使うので、違いは apply_patch_tool_type（= apply_patch ツールの有無）だけ。
#
#   apply-patch-e2e.sh <model-tag> <responses-dump.json>
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

MODEL="${1:?usage: $0 <model-tag> <responses-dump.json>}"
DUMP="${2:?usage: $0 <model-tag> <responses-dump.json>}"
IMAGE="${IMAGE_V3:-localhost/cline-sandbox:v3}"
MAX="${E2E_MAX_SEC:-5400}"
SAFE_MODEL="$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9._-' '-')"
tag="$(date +%Y%m%d-%H%M%S)-$SAFE_MODEL-freeform"
d="$CT_STATE/apply-patch-e2e/$tag"
mkdir -p "$d/ws"
PROMPT='Create a file named hello.txt in the current directory containing exactly the text: hello from codex. Then finish the task.'
printf '%s\n' "$PROMPT" >"$d/ws/.prompt.txt"
"$CT_PY" "$CT_DIR/make_codex_catalog.py" "$MODEL" freeform "$DUMP" >"$d/ws/.catalog.json"

CMD='codex exec --strict-config --skip-git-repo-check -c approval_policy="\"never\"" -c model_catalog_json="\"/workspace/.catalog.json\"" - </workspace/.prompt.txt'

ct_log "apply_patch E2E $tag"
st=$(date +%s)
set +e
timeout "$MAX" podman run --rm --network=none \
  -v "$d/ws:/workspace:rw" \
  -v "$MODEL_VOLUME:/models" \
  -e OLLAMA_MODELS=/models \
  -e CLINE_MODEL="$MODEL" \
  -e RUST_LOG=codex_core=debug \
  "$IMAGE" \
  bash -c "$CMD; rc=\$?; cp /var/log/ollama.log /workspace/.ollama.log; exit \$rc" >"$d/run.log" 2>&1
rc=$?
set -e
el=$(( $(date +%s) - st ))

{
  echo "tag=$tag"
  echo "elapsed_sec=$el rc=$rc"
  echo "hello.txt=$(cat "$d/ws/hello.txt" 2>/dev/null || echo '(なし)')"
  echo "--- apply_patch / tool router"
  grep -aE 'unsupported|apply_patch|custom_tool_call|function_call' "$d/run.log" | grep -avE '^\[entrypoint\]' | cut -c1-240 | head -20 || true
  echo "--- ollama requests"
  grep -E 'POST +"/v1/responses"' "$d/ws/.ollama.log" 2>/dev/null | sed -E 's/.*\| *([0-9]+) \| *([^|]+)\|.*(POST[^"]*"[^"]+").*/status=\1 duration=\2 \3/' || true
  echo "--- prefill"
  grep -E 'prompt eval time|truncated' "$d/ws/.ollama.log" 2>/dev/null | sed -E 's/.*prompt eval time = *([0-9.]+) ms \/ *([0-9]+) tokens.*/prefill \2 tok in \1 ms/; s/.*n_tokens = ([0-9]+), truncated = ([0-9]+).*/  ctx=\1 truncated=\2/' || true
} | tee "$d/summary.txt"
