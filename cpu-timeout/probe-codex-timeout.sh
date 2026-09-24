#!/usr/bin/env bash
# probe-codex-timeout.sh - 遅いスタブ（/v1/responses）に対し Codex CLI が何秒で切るかを測る（実モデル不要）
#
# Codex は Rust 製なので、Cline（Bun）の 2 層の 300 秒は当てはまらない。何が効くかを実測する。
# ホストの ~/.codex / ~/.local/bin/codex には触れない（CODEX_HOME を隔離し、
# .state/codex-npm に入れた版固定の codex を使う）。
#
# 使い方:
#   probe-codex-timeout.sh "<idle_ms>:<silent|headers|gap>:<delay_sec>" ...
#     idle_ms : config.toml の stream_idle_timeout_ms
#     silent  : 最初のバイトまで無音（CPU prefill 相当）
#     headers : ヘッダ即・最初のイベントまで無音
#     gap     : 最初のイベント即・その後無音（生成が途切れる状況）
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

CODEX_VERSION="${CODEX_VERSION:-0.156.1}"
CODEX_PREFIX="$CT_STATE/codex-npm"
CODEX="$CODEX_PREFIX/bin/codex"
PORT="${OLLAMA_HOST##*:}"
OUT="$CT_STATE/probe-codex"
TSV="$OUT/results.tsv"
MARGIN="${PROBE_MARGIN_SEC:-120}"

[ $# -gt 0 ] || { sed -n '2,14p' "$0"; exit 2; }

if [ "$("$CODEX" --version 2>/dev/null)" != "codex-cli $CODEX_VERSION" ]; then
  npm install -g --prefix "$CODEX_PREFIX" "@openai/codex@$CODEX_VERSION" >/dev/null
fi
ss -ltn "sport = :$PORT" | grep -q LISTEN && ct_die "$OLLAMA_HOST が使用中です"

mkdir -p "$OUT"
[ -f "$TSV" ] || printf 'case\tidle_ms\tmode\tdelay_sec\telapsed_sec\trc\tstub_disconnect_sec\tresponses_requests\tverdict\terror\n' >"$TSV"

STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true; }
trap cleanup EXIT

for c in "$@"; do
  IFS=: read -r idle mode delay <<<"$c"
  name="idle${idle}-${mode}-${delay}s"
  d="$OUT/$name"
  rm -rf "$d"; mkdir -p "$d/ws" "$d/home"
  ct_log "=== $name ==="

  cat >"$d/home/config.toml" <<EOF
model = "$CLINE_MODEL"
model_provider = "ollama-local"
model_context_window = 32768
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[model_providers.ollama-local]
name = "Ollama (local)"
base_url = "http://127.0.0.1:$PORT/v1"
wire_api = "responses"
stream_idle_timeout_ms = $idle
request_max_retries = 0
stream_max_retries = 0
EOF

  STUB_PORT="$PORT" STUB_DELAY_SEC="$delay" STUB_MODE="$mode" STUB_MODEL="$CLINE_MODEL" \
  STUB_LOG="$d/stub.jsonl" STUB_DUMP_DIR="$d/dump" \
    "$CT_PY" "$CT_DIR/slow_ollama_stub.py" 2>"$d/stub.err" &
  STUB_PID=$!
  for _ in $(seq 20); do curl -s -m 1 "http://$OLLAMA_HOST/v1/models" >/dev/null && break; sleep 0.5; done

  st=$(date +%s)
  set +e
  CODEX_HOME="$d/home" timeout "$((delay + MARGIN))" \
    "$CODEX" exec --strict-config --skip-git-repo-check -C "$d/ws" "say ok" </dev/null >"$d/run.log" 2>&1
  rc=$?
  set -e
  el=$(( $(date +%s) - st ))
  kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""

  disc="$(grep -m1 '"client_disconnected"' "$d/stub.jsonl" 2>/dev/null | sed -nE 's/.*"after_sec": ?([0-9.]+).*/\1/p' || true)"
  nreq="$(grep -c '"path": "/v1/responses"' "$d/stub.jsonl" 2>/dev/null || true)"
  err="$(grep -aiE -m1 'timed out|timeout|idle|error|disconnect' "$d/run.log" | tr '\t' ' ' | cut -c1-160 || true)"
  if [ "$rc" -eq 124 ]; then verdict="HUNG(${delay}+${MARGIN}s)"
  elif grep -q '"chat_done"' "$d/stub.jsonl" 2>/dev/null && [ "$rc" -eq 0 ]; then verdict="COMPLETED"
  elif [ -n "$disc" ]; then verdict="CUT@${disc}s"
  else verdict="FAILED"; fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$idle" "$mode" "$delay" "$el" "$rc" "${disc:--}" "${nreq:-0}" "$verdict" "$err" >>"$TSV"
  ct_log "$name: elapsed=${el}s rc=$rc disconnect=${disc:--} requests=${nreq:-0} -> $verdict"
  if [ -n "$err" ]; then ct_log "   $err"; fi
done
