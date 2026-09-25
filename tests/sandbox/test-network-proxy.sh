#!/bin/bash
# test-network-proxy.sh - ネットワーク許可モードの sandbox 内で実行する検査（test-proxy.sh から呼ばれる）
#
# 許可リストのドメインだけに届き、それ以外・直接接続・DNS・ホストには届かないこと。
# コンテナ内の Ollama（127.0.0.1）にはプロキシを通らずに届くこと。
echo "=========================================="
echo " Running Network Allowlist Test (proxy mode) "
echo "=========================================="

FAILED=0
check() {  # check <番号> <説明> <expect: allow|deny> <コマンド...>
    local label="$1" desc="$2" expect="$3"
    shift 3
    echo -n "[$label] $desc... "
    if "$@" > /dev/null 2>&1; then got=allow; else got=deny; fi
    if [ "$got" = "$expect" ]; then
        echo "PASS ($got)"
    else
        echo "FAIL (expected $expect, got $got)"
        FAILED=$((FAILED + 1))
    fi
}

# TCP で接続できたら「届いた」とみなす（HTTP 以外のポートでも正しく判定できるように curl は使わない）
tcp() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# ホスト上のサービス（test-proxy.sh が、既定のネットワークなら届くことを確かめてから渡す）
HOST_NAME="${TEST_HOST_NAME:-host.containers.internal}"
HOST_PORT="${TEST_HOST_PORT:-22}"

check 1/9 "Proxy settings are passed"            allow test -n "$HTTPS_PROXY"
check 2/9 "Localhost Ollama bypasses the proxy"  allow curl -sf -m 5 http://127.0.0.1:11434/api/tags
check 3/9 "Allowlisted HTTPS (pypi.org)"         allow curl -sf -m 20 -o /dev/null https://pypi.org/simple/pip/
check 4/9 "Non-allowlisted HTTPS (example.com)"  deny  curl -sf -m 20 -o /dev/null https://example.com
check 5/9 "Non-allowlisted HTTP (example.com)"   deny  curl -sf -m 20 -o /dev/null http://example.com
check 6/9 "Suffix trick (pypi.org.example.com)"  deny  curl -sf -m 20 -o /dev/null https://pypi.org.example.com
check 7/9 "Direct connection without the proxy"  deny  curl -sf -m 8 --noproxy '*' -o /dev/null https://pypi.org
check 8/9 "DNS lookup of external names"         deny  getent hosts pypi.org
check 9/9 "Host service $HOST_NAME:$HOST_PORT"    deny  tcp "$HOST_NAME" "$HOST_PORT"

echo "=========================================="
if [ "$FAILED" -eq 0 ]; then
    echo "RESULT: ALL NETWORK ALLOWLIST TESTS PASSED"
    exit 0
fi
echo "RESULT: $FAILED NETWORK ALLOWLIST TEST(S) FAILED"
exit 1
