#!/usr/bin/env bash
# devstral-probe.sh - 取り込んだ Devstral を --network=none のコンテナで軽く確かめる（実タスクの前段）
#
#   devstral-probe.sh [model]      # 既定 devstral-small-2:24b-iq4_xs
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"

MODEL="${1:-devstral-small-2:24b-iq4_xs}"
d="$RS_STATE/devstral-probe/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$d"

rs_log "probe $MODEL -> $d"
podman run --rm --network=none \
  -v "$MODEL_VOLUME:/models" \
  -v "$RS_DIR:/opt/research:ro" \
  -v "$d:/work:rw" \
  -e OLLAMA_MODELS=/models \
  -e CLINE_MODEL="$MODEL" \
  "$IMAGE" bash -c "
    PYTHONUNBUFFERED=1 PROBE_SPEED_TOKENS=${PROBE_SPEED_TOKENS:-0} python3 /opt/research/models/devstral_probe.py '$MODEL'
    echo '== ollama ps'; ollama ps
    echo '== memory'; free -m | head -2
    cp /var/log/ollama.log /work/ollama.log
  " 2>&1 | grep -vE '^\[entrypoint\]|^  (cline|codex) ' | tee "$d/probe.log"
grep -E 'truncated|error|panic' "$d/ollama.log" | tail -5 || true
