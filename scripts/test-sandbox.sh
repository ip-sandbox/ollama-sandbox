#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$DIR/sandbox/workspace"
mkdir -p "$WORKSPACE_DIR"

echo "============================================================"
echo "  CLINE SANDBOX INTEGRATION TEST SUITE (--network=none)     "
echo "============================================================"

# テストスクリプトをworkspaceに一時コピーしてコンテナ内で実行可能にする
cp "$DIR/scripts/test-network.sh" "$WORKSPACE_DIR/test-network.sh"
cp "$DIR/scripts/test-filesystem.sh" "$WORKSPACE_DIR/test-filesystem.sh"
chmod +x "$WORKSPACE_DIR/test-network.sh" "$WORKSPACE_DIR/test-filesystem.sh"

# ホスト側にテスト用シークレットディレクトリを一時作成（ユーザー名非依存）
SECRET_DIR=$(mktemp -d -t cline_host_secret_XXXXXX)
echo "THIS_MUST_NOT_BE_VISIBLE_IN_SANDBOX" > "$SECRET_DIR/secret.txt"

# 終了時または中断時に確実にクリーンアップ
cleanup() {
    rm -f "$WORKSPACE_DIR/test-network.sh" "$WORKSPACE_DIR/test-filesystem.sh"
    rm -rf "$SECRET_DIR"
}
trap cleanup EXIT INT TERM

echo ""
echo ">>> [TEST 1] Network Isolation & Localhost Verification <<<"
podman run --rm \
    --network=none \
    -v "$WORKSPACE_DIR:/workspace:rw" \
    localhost/cline-sandbox:v2 \
    /workspace/test-network.sh

echo ""
echo ">>> [TEST 2] Filesystem & Secret Isolation Verification <<<"
podman run --rm \
    --network=none \
    -v "$WORKSPACE_DIR:/workspace:rw" \
    -e TEST_SECRET_DIR="$SECRET_DIR" \
    localhost/cline-sandbox:v2 \
    /workspace/test-filesystem.sh

echo ""
echo ">>> [TEST 3] Ollama Offline Inference (SmolLM 135M) <<<"
podman run --rm \
    --network=none \
    -v "$WORKSPACE_DIR:/workspace:rw" \
    localhost/cline-sandbox:v2 \
    curl -s http://127.0.0.1:11434/api/generate -d '{"model":"smollm:135m","prompt":"Hello, answer with OK","stream":false}'

echo ""
echo ""
echo ">>> [TEST 4] Cline CLI & Ollama Connectivity Test <<<"
podman run --rm \
    --network=none \
    -v "$WORKSPACE_DIR:/workspace:rw" \
    localhost/cline-sandbox:v2 \
    cline --version

# 後片付け
rm -f "$WORKSPACE_DIR/test-network.sh" "$WORKSPACE_DIR/test-filesystem.sh"

echo ""
echo "============================================================"
echo "  ALL SANDBOX INTEGRATION TESTS SUCCESSFULLY COMPLETED!     "
echo "============================================================"
