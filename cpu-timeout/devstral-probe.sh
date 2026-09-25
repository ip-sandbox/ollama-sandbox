#!/usr/bin/env bash
# devstral-probe.sh - 取り込んだ Devstral を --network=none のコンテナで軽く確かめる（実タスクの前段）
#
#   devstral-probe.sh [model]      # 既定 devstral-small-2:24b-iq4_xs
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

MODEL="${1:-devstral-small-2:24b-iq4_xs}"
IMAGE="${IMAGE_V3:-localhost/cline-sandbox:v3}"
d="$CT_STATE/devstral-probe/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$d"

ct_log "probe $MODEL -> $d"
podman run --rm --network=none \
  -v "$MODEL_VOLUME:/models" \
  -v "$CT_DIR:/opt/cpu-timeout:ro" \
  -v "$d:/work:rw" \
  -e OLLAMA_MODELS=/models \
  -e CLINE_MODEL="$MODEL" \
  "$IMAGE" bash -c "
    PYTHONUNBUFFERED=1 PROBE_SPEED_TOKENS=${PROBE_SPEED_TOKENS:-0} python3 /opt/cpu-timeout/devstral_probe.py '$MODEL'
    echo '== ollama ps'; ollama ps
    echo '== memory'; free -m | head -2
    cp /var/log/ollama.log /work/ollama.log
  " 2>&1 | grep -vE '^\[entrypoint\]|^  (cline|codex) ' | tee "$d/probe.log"
grep -E 'truncated|error|panic' "$d/ollama.log" | tail -5 || true
