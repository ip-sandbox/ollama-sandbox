#!/usr/bin/env bash
# import_gguf_model.sh - Hugging Face の GGUF を Ollama に取り込み、公式タグのテンプレートを移植する
#
# launcher.py の prepare_model が、ネットワークを有効にしたコンテナ内で実行する（読み取り専用でマウント）。
#
#   import_gguf_model.sh <target-tag> <gguf-url> <sha256> <size> <template-from-tag> [PARAM=VALUE ...]
#
# `ollama pull hf.co/...` は使わない。HF が別ホストの CDN（xet）へリダイレクトし、
# Ollama 0.34.2 が "blocked redirect to a different host" で拒否するため。
# 代わりに GGUF を curl で落とし、sha256 を確かめてから blobs/sha256-<digest> に直接置く。
# ollama create は同じ digest の blob があればそれを使うので、GGUF は複製されない。
#
# テンプレートは Ollama registry の公式タグから template / params レイヤだけを取る（重みは落とさない）。
# 詳細: docs/results/DEVSTRAL_RESULT.md
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "usage: $0 <target-tag> <gguf-url> <sha256> <size> <template-from-tag> [PARAM=VALUE ...]" >&2
  exit 2
fi
TARGET="$1" URL="$2" SHA256="$3" SIZE="$4" TEMPLATE_FROM="$5"
shift 5

MODELS_DIR="${OLLAMA_MODELS:?OLLAMA_MODELS が未設定です}"
BLOB="$MODELS_DIR/blobs/sha256-$SHA256"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. 重み（途中で切れても -C - で続きから取得する）
if [ -f "$BLOB" ] && [ "$(stat -c%s "$BLOB")" = "$SIZE" ]; then
  echo "GGUF は取得済みです: $BLOB"
else
  mkdir -p "$MODELS_DIR/.import" "$MODELS_DIR/blobs"
  part="$MODELS_DIR/.import/$SHA256.partial"
  echo "GGUF を取得します（$(( SIZE / 1024 / 1024 )) MiB）: $URL"
  curl -fL -C - --retry 5 --retry-delay 5 --retry-all-errors --progress-bar -o "$part" "$URL"
  got="$(stat -c%s "$part")"
  if [ "$got" != "$SIZE" ]; then
    echo "サイズが一致しません（$got / $SIZE バイト）。もう一度実行すると続きから取得します。" >&2
    exit 1
  fi
  echo "sha256 を確認しています..."
  if ! echo "$SHA256  $part" | sha256sum -c --status -; then
    rm -f "$part"
    echo "sha256 が一致しません。壊れたファイルを削除しました。もう一度実行してください。" >&2
    exit 1
  fi
  mv "$part" "$BLOB"
  rmdir "$MODELS_DIR/.import" 2>/dev/null || true
fi

# 2. 公式タグの template / params レイヤ
python3 - "$TEMPLATE_FROM" "$WORK" <<'PY'
import json, sys, urllib.request
ref, out = sys.argv[1], sys.argv[2]
name, _, tag = ref.partition(":")
if "/" not in name:
    name = "library/" + name
base = "https://registry.ollama.ai/v2"
def get(url, headers=None):
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=60).read()
m = json.loads(get(f"{base}/{name}/manifests/{tag or 'latest'}",
                   {"Accept": "application/vnd.docker.distribution.manifest.v2+json"}))
layers = {l["mediaType"].rsplit(".", 1)[-1]: l["digest"] for l in m["layers"]}
if "template" not in layers:
    sys.exit(f"{ref} に template レイヤがありません")
open(f"{out}/template", "wb").write(get(f"{base}/{name}/blobs/{layers['template']}"))
params = json.loads(get(f"{base}/{name}/blobs/{layers['params']}")) if "params" in layers else {}
with open(f"{out}/params", "w") as f:
    for key, value in params.items():
        for v in value if isinstance(value, list) else [value]:
            f.write(f"PARAMETER {key} {json.dumps(v) if isinstance(v, str) else v}\n")
print(f"{ref} のテンプレートを取得しました（params: {params}）")
PY

# 3. Modelfile を組み立てて登録する
{
  printf 'FROM %s\n' "$BLOB"
  printf 'TEMPLATE """'; cat "$WORK/template"; printf '"""\n'
  cat "$WORK/params"
  for kv in "$@"; do printf 'PARAMETER %s %s\n' "${kv%%=*}" "${kv#*=}"; done
} >"$WORK/Modelfile"
ollama create "$TARGET" -f "$WORK/Modelfile"
ollama show "$TARGET" --modelfile | grep -E '^(FROM|PARAMETER)'
