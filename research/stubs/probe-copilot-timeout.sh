#!/usr/bin/env bash
# probe-copilot-timeout.sh - 遅いスタブ（/v1/responses）に対し Copilot CLI が何秒で切るかを測る（実モデル不要）
#
# Copilot CLI は Node の単一実行ファイルなので、Cline（Bun）の preload も Codex の
# stream_idle_timeout_ms も効かない。何秒で切るか、1 ターン目のプロンプトがどれくらいの大きさかを実測する。
# ホストの ~/.copilot には触れない（HOME を検証ごとに隔離し、.state/copilot-npm に入れた版固定の copilot を使う）。
#
# 使い方:
#   probe-copilot-timeout.sh "<silent|headers|gap>:<delay_sec>" ...
#     silent  : 最初のバイトまで無音（CPU prefill 相当）
#     headers : ヘッダ即・最初のイベントまで無音
#     gap     : 最初のイベント即・その後無音（生成が途切れる状況）
#   PROBE_ENV="K=V ..."  copilot に追加で渡す環境変数（タイムアウト設定の探索用）
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"

COPILOT_VERSION="${COPILOT_VERSION:-1.0.88}"
COPILOT_PREFIX="$RS_STATE/copilot-npm"
COPILOT="$COPILOT_PREFIX/bin/copilot"
PORT="${OLLAMA_HOST##*:}"
OUT="$RS_STATE/probe-copilot"
TSV="$OUT/results.tsv"
MARGIN="${PROBE_MARGIN_SEC:-120}"

[ $# -gt 0 ] || { sed -n '2,14p' "$0"; exit 2; }

if ! "$COPILOT" --version 2>/dev/null | grep -q "CLI $COPILOT_VERSION\."; then
  npm install -g --prefix "$COPILOT_PREFIX" "@github/copilot@$COPILOT_VERSION" >/dev/null
fi
ss -ltn "sport = :$PORT" | grep -q LISTEN && rs_die "$OLLAMA_HOST が使用中です"

mkdir -p "$OUT"
[ -f "$TSV" ] || printf 'case\tmode\tdelay_sec\telapsed_sec\trc\tstub_disconnect_sec\tresponses_requests\tverdict\terror\n' >"$TSV"

STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true; }
trap cleanup EXIT

for c in "$@"; do
  IFS=: read -r mode delay <<<"$c"
  name="${mode}-${delay}s${PROBE_ENV:+-env}"
  d="$OUT/$name"
  rm -rf "$d"; mkdir -p "$d/ws" "$d/home"
  rs_log "=== $name ${PROBE_ENV:+($PROBE_ENV)} ==="

  STUB_PORT="$PORT" STUB_DELAY_SEC="$delay" STUB_MODE="$mode" STUB_MODEL="$CLINE_MODEL" \
  STUB_LOG="$d/stub.jsonl" STUB_DUMP_DIR="$d/dump" \
    "$RS_PY" "$RS_DIR/stubs/slow_ollama_stub.py" 2>"$d/stub.err" &
  STUB_PID=$!
  for _ in $(seq 20); do curl -s -m 1 "http://$OLLAMA_HOST/v1/models" >/dev/null && break; sleep 0.5; done

  st=$(date +%s)
  set +e
  # shellcheck disable=SC2086
  env -i PATH="$PATH" HOME="$d/home" TERM=dumb \
    COPILOT_PROVIDER_BASE_URL="http://127.0.0.1:$PORT/v1" \
    COPILOT_PROVIDER_WIRE_API=responses \
    COPILOT_MODEL="$CLINE_MODEL" \
    COPILOT_OFFLINE=true \
    COPILOT_AUTO_UPDATE=false \
    ${PROBE_ENV:-} \
    timeout "$((delay + MARGIN))" \
    "$COPILOT" -p "say ok" --allow-all-tools -C "$d/ws" --log-dir "$d/logs" --log-level debug \
    </dev/null >"$d/run.log" 2>&1
  rc=$?
  set -e
  el=$(( $(date +%s) - st ))
  kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""

  disc="$(grep -m1 '"client_disconnected"' "$d/stub.jsonl" 2>/dev/null | sed -nE 's/.*"after_sec": ?([0-9.]+).*/\1/p' || true)"
  nreq="$(grep -c '"path": "/v1/responses"' "$d/stub.jsonl" 2>/dev/null || true)"
  err="$(grep -aiE -m1 'timed out|timeout|abort|error|disconnect' "$d/run.log" | tr '\t' ' ' | cut -c1-160 || true)"
  if [ "$rc" -eq 124 ]; then verdict="HUNG(${delay}+${MARGIN}s)"
  elif grep -q '"chat_done"' "$d/stub.jsonl" 2>/dev/null && [ "$rc" -eq 0 ]; then verdict="COMPLETED"
  elif [ -n "$disc" ]; then verdict="CUT@${disc}s"
  else verdict="FAILED"; fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$mode" "$delay" "$el" "$rc" "${disc:--}" "${nreq:-0}" "$verdict" "$err" >>"$TSV"
  rs_log "$name: elapsed=${el}s rc=$rc disconnect=${disc:--} requests=${nreq:-0} -> $verdict"
  if [ -n "$err" ]; then rs_log "   $err"; fi
done
