#!/usr/bin/env bash
# set-timeout.sh - Cline CLI の Ollama リクエストタイムアウトを providers.json で設定する
#
# cline 3.0.64 の Ollama プロバイダは providers.json の
#   providers.ollama.settings.timeout (ms)
# を timeoutMs として使い、未設定なら 300000 ms（300 秒）で AbortController が
# "Ollama request timed out after 300 seconds" を投げる。バイナリパッチは不要。
#
# ホストでもコンテナ内でも動く（JSON 編集は node で行う。コンテナに python は無い）。
#
# 使い方:
#   set-timeout.sh [--data-dir DIR] [--model MODEL] [--timeout-ms MS]   # 設定
#   set-timeout.sh [--data-dir DIR] --show                             # 現在値
#   set-timeout.sh [--data-dir DIR] --unset                            # 削除（既定 300s に戻る）
#
#   DIR   : cline の --data-dir と同じもの（既定: $CLINE_DATA または ~/.cline/data）
#   MODEL : 既定 $CLINE_MODEL または gemma4:12b-it-qat
#   MS    : 既定 1800000（30 分）
set -euo pipefail

DATA_DIR="${CLINE_DATA:-$HOME/.cline/data}"
MODEL="${CLINE_MODEL:-gemma4:12b-it-qat}"
TIMEOUT_MS="${CLINE_TIMEOUT_MS:-1800000}"
MODE=set

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)   DATA_DIR="$2"; shift 2 ;;
    --model)      MODEL="$2"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
    --show)       MODE=show; shift ;;
    --unset)      MODE=unset; shift ;;
    -h|--help)    sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$TIMEOUT_MS" in ''|*[!0-9]*) echo "--timeout-ms must be a positive integer (ms)" >&2; exit 2 ;; esac

PJ="$DATA_DIR/settings/providers.json"
[ -f "$PJ" ] || [ ! -f "$DATA_DIR/data/settings/providers.json" ] || PJ="$DATA_DIR/data/settings/providers.json"

if [ "$MODE" = set ] && ! grep -q '"ollama"' "$PJ" 2>/dev/null; then
  # ollama エントリが無ければ cline 自身に作らせる（構造を手書きしない）
  cline auth -p ollama -m "$MODEL" -k ollama --data-dir "$DATA_DIR" >/dev/null
fi
[ -f "$PJ" ] || { echo "providers.json not found: $PJ" >&2; exit 1; }

node - "$PJ" "$MODE" "$TIMEOUT_MS" "$MODEL" <<'JS'
const fs = require("fs");
const [pj, mode, ms, model] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(pj, "utf8"));
const s = cfg.providers?.ollama?.settings;
if (!s) { console.error(`no providers.ollama.settings in ${pj}`); process.exit(1); }
if (mode === "set") {
  s.timeout = Number(ms);
  s.model = s.model || model;
  cfg.lastUsedProvider = "ollama";
} else if (mode === "unset") {
  delete s.timeout;
}
if (mode !== "show") fs.writeFileSync(pj, JSON.stringify(cfg, null, 2) + "\n");
const t = s.timeout;
console.log(`${pj}\n  model=${s.model} timeout=${t === undefined ? "(unset -> 300000 ms default)" : `${t} ms (${t / 1000} s)`}`);
JS
