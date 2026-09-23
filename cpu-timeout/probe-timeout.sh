#!/usr/bin/env bash
# probe-timeout.sh - 遅いスタブ Ollama に対し Cline CLI が何秒で切るかを測る（実モデル不要）
#
# 使い方:
#   probe-timeout.sh                          # 既定の行列を全部
#   probe-timeout.sh "none:silent:340" "1800000:silent:400"
#
# ケースは  <timeout_ms|none>:<silent|headers>:<delay_sec>[:preload]  の形式。
#   timeout_ms : providers.json の settings.timeout（none = 未設定 = 既定 300s）
#   silent     : 先頭バイトまで無音（CPU prefill 中の本物の Ollama と同じ）
#   headers    : ヘッダ即返し・本文だけ遅延
#   preload    : BUN_OPTIONS で bun-fetch-no-timeout.js を読み込む（Bun fetch の 300 秒を外す）
#
# 結果: .state/probe/results.tsv と各ケースのログ
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

PORT="${OLLAMA_HOST##*:}"
OUT="$CT_STATE/probe"
TSV="$OUT/results.tsv"
MARGIN="${PROBE_MARGIN_SEC:-120}"

if [ $# -gt 0 ]; then CASES=("$@"); else
  CASES=("none:silent:5" "none:silent:340" "1800000:silent:400" "1800000:silent:700"
         "1800000:headers:700" "1800000:silent:1200")
fi

ss -ltn "sport = :$PORT" | grep -q LISTEN \
  && ct_die "$OLLAMA_HOST が使用中です（本物の ollama が動いていると測定になりません）"

mkdir -p "$OUT"
[ -f "$TSV" ] || printf 'case\ttimeout_ms\tmode\tdelay_sec\telapsed_sec\trc\tstub_disconnect_sec\tverdict\terror\n' >"$TSV"

STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true; }
trap cleanup EXIT

for c in "${CASES[@]}"; do
  IFS=: read -r tmo mode delay pre <<<"$c"
  name="t${tmo}-${mode}-${delay}s${pre:+-$pre}"
  bun_opts=""
  [ "$pre" = preload ] && bun_opts="--preload $CT_DIR/bun-fetch-no-timeout.js"
  d="$OUT/$name"
  rm -rf "$d"; mkdir -p "$d/ws"
  ct_log "=== $name ==="

  STUB_PORT="$PORT" STUB_DELAY_SEC="$delay" STUB_MODE="$mode" STUB_MODEL="$CLINE_MODEL" \
  STUB_LOG="$d/stub.jsonl" STUB_DUMP_DIR="$d/dump" \
    "$CT_PY" "$CT_DIR/slow_ollama_stub.py" 2>"$d/stub.err" &
  STUB_PID=$!
  for _ in $(seq 20); do curl -s -m 1 "http://$OLLAMA_HOST/api/tags" >/dev/null && break; sleep 0.5; done

  if [ "$tmo" = none ]; then
    cline auth -p ollama -m "$CLINE_MODEL" -k ollama --data-dir "$d/cline" >/dev/null
  else
    bash "$CT_DIR/set-timeout.sh" --data-dir "$d/cline" --model "$CLINE_MODEL" --timeout-ms "$tmo" >/dev/null
  fi
  cp "$(ct_providers_json "$d/cline")" "$d/providers.json"

  st=$(date +%s)
  set +e
  printf 'say ok' | BUN_OPTIONS="$bun_opts" CLINE_NO_FETCH_TIMEOUT_DEBUG=1 timeout "$((delay + MARGIN))" \
    cline -P ollama -m "$CLINE_MODEL" --data-dir "$d/cline" --cwd "$d/ws" --auto-approve true \
    >"$d/run.log" 2>&1
  rc=$?
  set -e
  el=$(( $(date +%s) - st ))
  kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""

  disc="$(grep -m1 '"client_disconnected"' "$d/stub.jsonl" 2>/dev/null | sed -nE 's/.*"after_sec": ?([0-9.]+).*/\1/p' || true)"
  err="$(grep -aiE -m1 'timed out|abort|error' "$d/run.log" | tr '\t' ' ' | cut -c1-160 || true)"
  if [ "$rc" -eq 124 ]; then verdict="HUNG(${delay}+${MARGIN}s)"
  elif grep -q '"chat_done"' "$d/stub.jsonl" 2>/dev/null && [ "$rc" -eq 0 ]; then verdict="COMPLETED"
  elif [ -n "$disc" ]; then verdict="CUT@${disc}s"
  else verdict="FAILED"; fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$tmo" "$mode" "$delay" "$el" "$rc" "${disc:--}" "$verdict" "$err" >>"$TSV"
  ct_log "$name: elapsed=${el}s rc=$rc disconnect=${disc:--} -> $verdict"
  if [ -n "$err" ]; then ct_log "   $err"; fi
done

echo
awk -F'\t' '{printf "%-26s %-8s %-6s %-6s %-8s %s\n", $1, $5, $6, $7, $8, $9}' "$TSV"
