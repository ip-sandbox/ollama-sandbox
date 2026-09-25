#!/usr/bin/env bash
# probe-apply-patch.sh - Codex が Ollama 向けリクエストに apply_patch ツールを載せるかを、実モデル無しで確かめる
#
# コンテナ内の ollama を止めて 11434 にスタブを立て、Codex の /v1/responses リクエスト本体を保存する。
# モデルカタログ（model_catalog_json）の有無と apply_patch_tool_type ごとに、送られたツール一覧を比べる。
#
#   probe-apply-patch.sh [model]      # 既定 gpt-oss:20b（スタブなのでモデルのダウンロードは不要）
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"

MODEL="${1:-gpt-oss:20b}"
d="$RS_STATE/probe-apply-patch/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$d/ws"

# 1回目: カタログ無し（fallback）。2回目: 1回目の instructions を使ったカタログで apply_patch_tool_type を変える
run_codex() {  # run_codex <variant...>
  podman run --rm --network=none \
    -v "$d/ws:/workspace:rw" \
    -v "$RS_DIR:/opt/research:ro" \
    -e CLINE_MODEL="$MODEL" \
    "$IMAGE" bash -c "
      pkill -x ollama; sleep 2
      for v in $*; do
        mkdir -p /workspace/\$v
        STUB_DELAY_SEC=0 STUB_MODEL=\"\$CLINE_MODEL\" STUB_LOG=/workspace/\$v/stub.jsonl STUB_DUMP_DIR=/workspace/\$v \\
          python3 /opt/research/stubs/slow_ollama_stub.py 2>/workspace/\$v/stub.err &
        pid=\$!; sleep 2
        cat=()
        [ \$v != default ] && cat=(-c \"model_catalog_json=\\\"/workspace/catalog-\$v.json\\\"\")
        codex exec --strict-config --skip-git-repo-check -c approval_policy='\"never\"' \"\${cat[@]}\" 'say ok' </dev/null >/workspace/\$v/codex.log 2>&1
        echo \"RESULT variant=\$v rc=\$?\"
        kill \$pid; wait \$pid 2>/dev/null
      done
    " 2>&1 | tee -a "$d/run.log" | grep RESULT || true  # 最後の wait がスタブの終了コードを返すので、失敗扱いにしない
}

rs_log "apply_patch probe: $IMAGE model=$MODEL -> $d"
run_codex default
for t in freeform function none; do
  "$RS_PY" "$RS_DIR/models/make_codex_catalog.py" "$MODEL" "$t" "$d/ws/default/responses-1.json" >"$d/ws/catalog-$t.json"
done
run_codex freeform function none

for v in default freeform function none; do
  echo "=== $v"
  grep -aE 'metadata|error|Error' "$d/ws/$v/codex.log" | head -3 || true
  f="$d/ws/$v/responses-1.json"
  [ -f "$f" ] || { echo "(リクエストなし)"; continue; }
  "$RS_PY" - "$f" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))
tools = [f"{t.get('type')}:{t.get('name', '')}" for t in b.get("tools", [])]
print("tools:", ", ".join(tools))
ap = [t for t in b.get("tools", []) if t.get("name") == "apply_patch"]
if ap:
    print("apply_patch:", json.dumps(ap[0], ensure_ascii=False)[:400])
print("instructions mention apply_patch:", b.get("instructions", "").count("apply_patch"))
EOF
done
