#!/usr/bin/env bash
# container-probe.sh - v3 イメージの既定設定のまま、Cline と Codex が長い無音に耐えるかをコンテナ内で確かめる
#
# コンテナ内の ollama を止めて 11434 に遅延スタブ（コンテナ内の Python 3.11 で実行）を立て、
# entrypoint が生成した設定（Cline: preload + timeout / Codex: config.toml）そのままで投げる。
#
#   container-probe.sh [delay_sec]      # 既定 400（Cline/Bun の 300 秒を超える値）
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"

DELAY="${1:-400}"
d="$RS_STATE/container-probe/$(date +%Y%m%d-%H%M%S)-${DELAY}s"
mkdir -p "$d/ws"

rs_log "container probe: $IMAGE delay=${DELAY}s -> $d"
podman run --rm --network=none \
  -v "$d/ws:/workspace:rw" \
  -v "$RS_DIR:/opt/research:ro" \
  -e CLINE_MODEL="$CLINE_MODEL" \
  -e CLINE_NO_FETCH_TIMEOUT_DEBUG=1 \
  "$IMAGE" bash -c "
    python3 --version
    pkill -x ollama; sleep 2
    STUB_DELAY_SEC=$DELAY STUB_DELAY_ALL=1 STUB_MODE=silent STUB_MODEL=\"\$CLINE_MODEL\" \
      STUB_LOG=/workspace/stub.jsonl python3 /opt/research/stubs/slow_ollama_stub.py 2>/workspace/stub.err &
    sleep 2
    for agent in cline codex; do
      s=\$(date +%s)
      if [ \$agent = cline ]; then
        echo 'say ok' | cline >/workspace/\$agent.log 2>&1
      else
        codex exec --strict-config --skip-git-repo-check -c approval_policy='\"never\"' 'say ok' </dev/null >/workspace/\$agent.log 2>&1
      fi
      rc=\$?
      echo \"RESULT agent=\$agent elapsed=\$(( \$(date +%s)-s ))s rc=\$rc\"
    done
  " 2>&1 | tee "$d/run.log" | grep -E "RESULT|Python"
echo "--- stub events"; grep -E '"chat_done"|"client_disconnected"' "$d/ws/stub.jsonl" || true
for a in cline codex; do echo "--- $a (tail)"; tail -3 "$d/ws/$a.log"; done
