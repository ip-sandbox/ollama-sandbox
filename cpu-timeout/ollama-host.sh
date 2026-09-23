#!/usr/bin/env bash
# ollama-host.sh - ホストで ollama serve を起動・停止する（モデルは podman volume をそのまま使う）
#
#   ollama-host.sh start | stop | status
#
# 環境変数（既定値）:
#   OLLAMA_LOAD_TIMEOUT=30m   ロード停滞の許容時間（既定 5m。CPU 機のロードで当たりうる）
#   OLLAMA_KEEP_ALIVE=-1      モデル常駐（既定 5m だと CPU の長いターン間でアンロードされる）
#   OLLAMA_CONTEXT_LENGTH=32768  Cline は num_ctx=32768 を自分で送る。API 直叩き時も同じにする
#   OLLAMA_NUM_PARALLEL=1     並列 1（KV を 1 本分だけ確保し、CPU を 1 リクエストに集中）
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

PIDFILE="$CT_STATE/ollama.pid"
LOG="$CT_LOGS/ollama.log"

models_dir() {
  podman volume inspect "$MODEL_VOLUME" --format '{{.Mountpoint}}'
}

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-status}" in
  start)
    running && { ct_log "already running (pid $(cat "$PIDFILE"))"; exit 0; }
    ss -ltn "sport = :${OLLAMA_HOST##*:}" | grep -q LISTEN && ct_die "$OLLAMA_HOST は使用中です"
    export OLLAMA_MODELS="${OLLAMA_MODELS:-$(models_dir)}"
    export OLLAMA_LOAD_TIMEOUT="${OLLAMA_LOAD_TIMEOUT:-30m}"
    export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
    export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"
    export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
    ct_log "OLLAMA_MODELS=$OLLAMA_MODELS"
    ct_log "LOAD_TIMEOUT=$OLLAMA_LOAD_TIMEOUT KEEP_ALIVE=$OLLAMA_KEEP_ALIVE CONTEXT_LENGTH=$OLLAMA_CONTEXT_LENGTH NUM_PARALLEL=$OLLAMA_NUM_PARALLEL"
    nohup ollama serve >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    for _ in $(seq 60); do
      curl -s -m 1 "http://$OLLAMA_HOST/api/version" >/dev/null && { ct_log "ready (pid $(cat "$PIDFILE"), log $LOG)"; exit 0; }
      sleep 0.5
    done
    ct_die "起動しませんでした。ログ: $LOG"
    ;;
  stop)
    if running; then kill "$(cat "$PIDFILE")"; ct_log "stopped"; else ct_log "not running"; fi
    rm -f "$PIDFILE"
    ;;
  status)
    if running; then
      ct_log "running (pid $(cat "$PIDFILE"))"
      curl -s "http://$OLLAMA_HOST/api/ps"; echo
    else
      ct_log "not running"
    fi
    ;;
  *) ct_die "usage: $0 start|stop|status" ;;
esac
