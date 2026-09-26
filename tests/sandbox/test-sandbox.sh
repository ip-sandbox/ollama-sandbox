#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$DIR/tests/sandbox"
WORKSPACE_DIR="$DIR/sandbox/workspace"
. "$DIR/scripts/config.sh"
mkdir -p "$WORKSPACE_DIR"

echo "============================================================"
echo "  CLINE SANDBOX INTEGRATION TEST SUITE (--network=none)     "
echo "============================================================"

# テストスクリプトは /tests に読み取り専用でマウントする（workspace にはコピーしない）

# ホスト側にテスト用シークレットディレクトリを一時作成（ユーザー名非依存）
SECRET_DIR=$(mktemp -d -t cline_host_secret_XXXXXX)
echo "THIS_MUST_NOT_BE_VISIBLE_IN_SANDBOX" > "$SECRET_DIR/secret.txt"

# 終了時または中断時に確実にクリーンアップ
cleanup() {
    rm -rf "$SECRET_DIR"
}
trap cleanup EXIT INT TERM

sandbox() {
    podman run --rm \
        --network=none \
        -v "$WORKSPACE_DIR:/workspace:rw" \
        -v "$TESTS_DIR:/tests:ro" \
        -e CLINE_MODEL=smollm:135m \
        "$@"
}

echo ""
echo ">>> [TEST 1] Network Isolation & Localhost Verification <<<"
sandbox "$SANDBOX_IMAGE" bash /tests/test-network.sh

echo ""
echo ">>> [TEST 2] Filesystem & Secret Isolation Verification <<<"
sandbox -e TEST_SECRET_DIR="$SECRET_DIR" "$SANDBOX_IMAGE" bash /tests/test-filesystem.sh

echo ""
echo ">>> [TEST 3] Ollama Offline Inference (SmolLM 135M) <<<"
sandbox "$SANDBOX_IMAGE" \
    curl -s --fail http://127.0.0.1:11434/api/generate -d '{"model":"smollm:135m","prompt":"Hello, answer with OK","stream":false}'

echo ""
echo ""
echo ">>> [TEST 4] Cline CLI & Ollama Connectivity Test <<<"
sandbox "$SANDBOX_IMAGE" cline --version

echo ""
echo ">>> [TEST 5] Codex CLI Startup & Config Test <<<"
sandbox "$SANDBOX_IMAGE" \
    bash -c 'codex --version && grep -q "wire_api = \"responses\"" ~/.codex/config.toml && echo "codex config OK"'

echo ""
echo ">>> [TEST 6] Copilot CLI Offline BYOK (Ollama) Test <<<"
sandbox "$SANDBOX_IMAGE" bash /tests/test-copilot.sh

echo ""
echo "============================================================"
echo "  ALL SANDBOX INTEGRATION TESTS SUCCESSFULLY COMPLETED!     "
echo "============================================================"
