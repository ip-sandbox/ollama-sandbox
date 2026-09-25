#!/usr/bin/env bash
# devstral-import.sh - Devstral Small 2 24B の IQ4_XS を取り込み、公式タグの Go テンプレートを移植する
#
# launcher の prepare_model と同じ形（--network=host、ollama-models volume）でコンテナを起動する。
# 手順は ip-sandbox/colab-ollama devstral-vibe/11_server_ollama.sh が元。違いは重みの置き方だけ:
#
#   - `ollama pull hf.co/...` は Ollama 0.34.2 では使えない。HF が別ホストの CDN（xet）へ
#     リダイレクトし、Ollama が "blocked redirect to a different host" で拒否する。
#   - 参照手順の curl + `ollama create FROM <file>` は GGUF を blob store に複製する（+12.8GB）。
#   - そこで GGUF を curl で volume に落とし、sha256 を確かめてから blobs/sha256-<digest> に置く。
#     ollama create のクライアントは同じ digest の blob がサーバにあればアップロードしないので、
#     複製は起きない（ディスクは GGUF 1 本分だけ）。
#
#   devstral-import.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

IMAGE="${IMAGE_V3:-localhost/cline-sandbox:v3}"
HF_URL="${HF_URL:-https://huggingface.co/unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF/resolve/main/Devstral-Small-2-24B-Instruct-2512-IQ4_XS.gguf}"
GGUF_SHA256="${GGUF_SHA256:-6b8270a839e7a1263f34a799c18fb9eb0ca6f1d039cdbfa4a11f9ac9552a118a}"
GGUF_SIZE="${GGUF_SIZE:-12780424352}"
OFFICIAL_TAG="${OFFICIAL_TAG:-devstral-small-2:24b-instruct-2512-q4_K_M}"
TARGET="${TARGET:-devstral-small-2:24b-iq4_xs}"
d="$CT_STATE/devstral-import/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$d"

before=$(df -B1 --output=avail / | tail -1)
ct_log "import $HF_URL -> $TARGET (template: $OFFICIAL_TAG) -> $d"
# OLLAMA_NOPRUNE: serve 起動時の未参照 blob 掃除で、落とし途中のファイルを消されないように
podman run --rm --network=host \
  -v "$MODEL_VOLUME:/models" \
  -v "$CT_DIR:/opt/cpu-timeout:ro" \
  -v "$d:/work:rw" \
  -e OLLAMA_MODELS=/models \
  -e OLLAMA_NOPRUNE=1 \
  -e CLINE_MODEL="$TARGET" \
  "$IMAGE" bash -c "
    set -e
    ollama --version
    blob=/models/blobs/sha256-$GGUF_SHA256
    if [ ! -f \"\$blob\" ]; then
      mkdir -p /models/.import
      part=/models/.import/$GGUF_SHA256.partial
      curl -fL -C - --retry 5 --retry-delay 5 --retry-all-errors -sS -o \"\$part\" '$HF_URL'
      [ \"\$(stat -c%s \"\$part\")\" = '$GGUF_SIZE' ] || { echo \"size mismatch: \$(stat -c%s \"\$part\")\"; exit 1; }
      echo '$GGUF_SHA256  '\"\$part\" | sha256sum -c -
      mv \"\$part\" \"\$blob\"
    fi
    echo \"blob: \$(ls -la \$blob)\"
    python3 /opt/cpu-timeout/fetch_ollama_template.py '$OFFICIAL_TAG' /work
    {
      printf 'FROM %s\n' \"\$blob\"
      printf 'TEMPLATE \"\"\"'; cat /work/template.gotmpl; printf '\"\"\"\n'
      printf 'PARAMETER temperature 0.15\n'
      printf 'PARAMETER min_p 0.01\n'
    } >/work/Modelfile
    ollama create '$TARGET' -f /work/Modelfile
    ollama list
    ollama show '$TARGET' --modelfile | grep -E '^(FROM|PARAMETER)'
    ls -la /models/blobs
  " 2>&1 | tr '\r' '\n' | grep -avE '^\s*$|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏' | tee "$d/import.log"
after=$(df -B1 --output=avail / | tail -1)
ct_log "disk used by import: $(( (before - after) / 1024 / 1024 )) MiB (GGUF 12,188 MiB)"
