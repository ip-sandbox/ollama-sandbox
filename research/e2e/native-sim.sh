#!/usr/bin/env bash
# native-sim.sh - native モード（すでにコンテナ内の環境）の検証用に、Colab の端末を模したコンテナを用意する
#
#   native-sim.sh setup     コンテナを作り（無ければ）、中で root として sandbox/scripts/install.sh を実行する
#   native-sim.sh exec ...  動いているコンテナの中でコマンドを実行する（無ければ setup を促す）
#   native-sim.sh rm        コンテナを削除する
#
# 素の ubuntu:22.04（Colab と同じ版）に install.sh を当てるだけで、sandbox イメージの entrypoint や ENV は無い。
# イメージにせず動かし続けるコンテナにしているのは、4GB 近い導入物をイメージへ commit する容量が要らないため
# （HOME や Ollama の serve が実行をまたいで残るのも、実際の native モードと同じ）。
#   /repo      : このリポジトリ（読み取り専用。今の entrypoint.sh・launcher.py を使う）
#   /models    : model volume（sandbox と共有。NATIVE_MODELS_DIR=/models）
#   /state     : research/.state（ワークスペースを置く。/workspace はここへのシンボリックリンク）
# ネットワークは使える（native モードの実環境と同じ）。e2e.sh --backend native と tests/sandbox/test-native.sh が使う。
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/env.sh"

NATIVE_SIM="${NATIVE_SIM:-ollama-native-sim}"

case "${1:-}" in
  setup)
    if ! podman container exists "$NATIVE_SIM"; then
      rs_log "create $NATIVE_SIM (ubuntu:22.04)"
      # --init: 止めた ollama などのゾンビを回収させる（PID 1 が sleep だと残り続ける）
      podman run -d --init --name "$NATIVE_SIM" \
        -v "$RS_REPO:/repo:ro" -v "$MODEL_VOLUME:/models" -v "$RS_STATE:/state" \
        -e NATIVE_MODELS_DIR=/models -e NATIVE_WORKSPACE=/workspace \
        docker.io/library/ubuntu:22.04 sleep infinity >/dev/null
    fi
    podman start "$NATIVE_SIM" >/dev/null
    podman exec "$NATIVE_SIM" bash /repo/sandbox/scripts/install.sh
    podman exec "$NATIVE_SIM" bash /repo/sandbox/scripts/install.sh --check && rs_log "$NATIVE_SIM ready"
    ;;
  exec)
    shift
    podman container exists "$NATIVE_SIM" || rs_die "$NATIVE_SIM がありません。先に $0 setup を実行してください"
    podman start "$NATIVE_SIM" >/dev/null
    exec podman exec -i "$NATIVE_SIM" "$@"
    ;;
  rm)
    podman rm -f "$NATIVE_SIM"
    ;;
  *)
    sed -n '2,15p' "$0"; exit 2 ;;
esac
