#!/usr/bin/env bash
# container-e2e.sh - 既存イメージ・既存ファイルを変えずに、コンテナ内で対策込みの E2E を 1 回通す
#
# scripts/launcher.py の launch() と同じ podman run（--network=none, モデル volume）に、
# 次の 3 点だけを足している:
#   -v cpu-timeout:/opt/cpu-timeout:ro                 preload と set-timeout.sh を渡す
#   -e BUN_OPTIONS=--preload .../bun-fetch-no-timeout.js  ① Bun fetch の 300 秒を外す
#                                                        （起動時に渡すので hub daemon にも効く）
#   -e OLLAMA_KEEP_ALIVE=-1                            ターン間のアンロード防止
# コンテナ内で set-timeout.sh を実行し（② Cline の 300 秒）、cline を実行する。
# 前提: ホストの ollama が 11434 を使っていても、コンテナは別 netns なので衝突しない
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

TMO="${E2E_TIMEOUT_MS:-1800000}"
tag="$(date +%Y%m%d-%H%M%S)-container"
d="$CT_STATE/e2e/$tag"
mkdir -p "$d/ws"
printf '%s\n' 'Create a file named hello.txt in the current directory containing exactly the text: hello from gemma4 on cpu. Then finish the task.' >"$d/ws/.prompt.txt"

ct_log "container E2E $tag"
st=$(date +%s)
set +e
podman run --rm --network=none \
  -v "$d/ws:/workspace:rw" \
  -v "$MODEL_VOLUME:/models" \
  -e OLLAMA_MODELS=/models \
  -e CLINE_MODEL="$CLINE_MODEL" \
  -v "$CT_DIR:/opt/cpu-timeout:ro" \
  -e BUN_OPTIONS="--preload /opt/cpu-timeout/bun-fetch-no-timeout.js" \
  -e CLINE_NO_FETCH_TIMEOUT_DEBUG=1 \
  -e OLLAMA_KEEP_ALIVE=-1 \
  "$IMAGE" \
  bash -c "
    bash /opt/cpu-timeout/set-timeout.sh --timeout-ms $TMO &&
    cp ~/.cline/data/settings/providers.json /workspace/.providers.json &&
    cat /workspace/.prompt.txt | cline -P ollama -m \"\$CLINE_MODEL\" --thinking none --cwd /workspace --auto-approve true;
    rc=\$?; cp /var/log/ollama.log /workspace/.ollama.log; exit \$rc
  " >"$d/run.log" 2>&1
rc=$?
set -e
el=$(( $(date +%s) - st ))

{
  echo "tag=$tag"
  echo "elapsed_sec=$el rc=$rc"
  echo "hello.txt=$(cat "$d/ws/hello.txt" 2>/dev/null || echo '(なし)')"
  echo "error=$(grep -aiE -m1 'timed out|abort|error' "$d/run.log" | cut -c1-200 || echo none)"
  echo "--- ollama /api/chat durations"
  grep 'POST *"/api/chat"' "$d/ws/.ollama.log" 2>/dev/null | sed -E 's/.*\| *([0-9]+) \| *([^|]+)\|.*/status=\1 duration=\2/' || true
} | tee "$d/summary.txt"
