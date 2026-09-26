#!/bin/bash
# test-proxy.sh - ネットワーク許可モード（scripts/proxy.sh）の統合テスト
#
# 外部ネットワーク（pypi.org）への到達を確かめるので、オフラインの test-sandbox.sh とは分けてある。
set -e

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$DIR/tests/sandbox"
. "$DIR/scripts/config.sh"

echo "============================================================"
echo "  OLLAMA SANDBOX NETWORK ALLOWLIST TEST (proxy mode)        "
echo "============================================================"

# 検査 9 の対照: 既定のネットワーク（pasta）ならホストのサービスに届くこと。
# 届かない環境では、許可モードで「届かない」ことを確かめても意味が無いので、その旨を表示する
HOST_NAME=host.containers.internal
HOST_PORT="${TEST_HOST_PORT:-22}"
echo -n "[control] Host service $HOST_NAME:$HOST_PORT from the default network... "
if podman run --rm --entrypoint bash "$SANDBOX_IMAGE" \
    -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$HOST_NAME/$HOST_PORT'" >/dev/null 2>&1; then
    echo "reachable（検査 9 は有効）"
else
    echo "unreachable（ホストで $HOST_PORT 番が待ち受けていないため、検査 9 は判定材料になりません）"
fi

bash "$DIR/scripts/proxy.sh" run \
    -v "$TESTS_DIR:/tests:ro" \
    -e TEST_HOST_NAME="$HOST_NAME" \
    -e TEST_HOST_PORT="$HOST_PORT" \
    -e CLINE_MODEL=smollm:135m \
    "$SANDBOX_IMAGE" \
    bash /tests/test-network-proxy.sh

echo ""
echo "[proxy] プロキシが片付けられたこと"
if podman container exists "$SANDBOX_PROXY_NAME"; then
    echo "FAIL ($SANDBOX_PROXY_NAME が残っています)"
    exit 1
fi
echo "PASS"
