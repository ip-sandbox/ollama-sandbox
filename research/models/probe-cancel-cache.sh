#!/usr/bin/env bash
# probe-cancel-cache.sh - prefill の途中でクライアントが切断したとき、Ollama が処理済みの分を
# prompt cache に残すか（送り直しで続きから進むか）を実モデルで確かめる
#
#   probe-cancel-cache.sh <request.json> [cut_sec]
#
#   request.json : /v1/responses のリクエスト本体（例: stubs/probe-copilot-timeout.sh のダンプ）。
#                  model は --model（既定 CLINE_MODEL）に置き換え、stream=true で送る
#   cut_sec      : 1 回目を何秒で切るか（既定 300。Copilot CLI は 600 秒無音で切って送り直す）
#
# 1 回目を cut_sec で切り、すぐに同じ本体を送り直す。Ollama の debug ログの cache slot 行
# （prompt / used / remaining）と、2 回目の最初のバイトまでの秒数を出す。
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"

REQ="${1:?request.json を指定してください}"
CUT="${2:-300}"
MODEL="${PROBE_MODEL:-$CLINE_MODEL}"
d="$RS_STATE/cancel-cache/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$d/ws"
"$RS_PY" - "$REQ" "$MODEL" >"$d/ws/req.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b["model"] = sys.argv[2]
b["stream"] = True
json.dump(b, sys.stdout)
PY

rs_log "cancel-cache model=$MODEL cut=${CUT}s -> $d"
podman run --rm --network=none \
  -v "$d/ws:/workspace:rw" -v "$MODEL_VOLUME:/models" \
  -e OLLAMA_MODELS=/models -e CLINE_MODEL="$MODEL" -e OLLAMA_DEBUG=1 \
  -e SANDBOX_SKIP_AGENT_SETUP=1 \
  "$IMAGE" bash -c '
    url=http://127.0.0.1:11434/v1/responses
    t0=$(date +%s)
    curl -s -N --max-time '"$CUT"' -H "Content-Type: application/json" -d @/workspace/req.json $url >/workspace/r1.sse
    echo "r1 rc=$? elapsed=$(( $(date +%s) - t0 ))s bytes=$(wc -c </workspace/r1.sse)"
    t1=$(date +%s)
    curl -s -N -H "Content-Type: application/json" -d @/workspace/req.json \
      -w "\nTTFB=%{time_starttransfer}\n" $url >/workspace/r2.sse
    echo "r2 rc=$? elapsed=$(( $(date +%s) - t1 ))s $(tail -1 /workspace/r2.sse)"
    cp /var/log/ollama.log /workspace/ollama.log' 2>&1 | grep -v '^\[entrypoint\]' | tee "$d/run.log"

echo "--- cache slot / prompt processing"
grep -aE 'cache slot|prompt=|used=|remaining|truncat|context canceled|aborted' "$d/ws/ollama.log" | cut -c1-240 | tail -20
echo "--- POST"
grep -aE 'POST +"/v1/responses"' "$d/ws/ollama.log" || true
