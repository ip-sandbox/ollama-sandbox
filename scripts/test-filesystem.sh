#!/bin/bash
echo "=========================================="
echo " Running Filesystem & Secret Isolation Test "
echo "=========================================="

FAILED_ISOLATION=0

# 1. /workspace write test
echo -n "[1/4] Testing /workspace write capability... "
TEST_FILE="/workspace/sandbox_test_$(date +%s).txt"
if echo "sandbox write test" > "$TEST_FILE" 2>/dev/null && [ -f "$TEST_FILE" ]; then
    echo "PASS (Successfully wrote to /workspace)"
    rm -f "$TEST_FILE"
else
    echo "FAIL (Cannot write to /workspace)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
fi

# 2. Host Secret File Access (DENY expected)
echo -n "[2/4] Testing host filesystem isolation... "
HOST_LEAK=0

# ホストから環境変数で渡されたシークレットパスの検証
if [ -n "$TEST_SECRET_DIR" ] && [ -e "$TEST_SECRET_DIR" ]; then
    HOST_LEAK=1
fi

# 一般的なホスト機密ディレクトリ (/root/.ssh, /home/*/.ssh 等) の非アクセス検証
if [ -d "/root/.ssh" ] || ls -d /home/*/.ssh > /dev/null 2>&1; then
    HOST_LEAK=1
fi

if [ $HOST_LEAK -eq 1 ]; then
    echo "FAIL (Host secret or host user directory is accessible!)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
else
    echo "PASS (Host filesystem is completely isolated)"
fi

# 3. Docker/Podman Socket Mount (DENY expected)
echo -n "[3/4] Testing Docker/Podman socket protection... "
if [ -S "/var/run/docker.sock" ] || [ -S "/run/podman/podman.sock" ]; then
    echo "FAIL (Container socket mounted inside sandbox!)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
else
    echo "PASS (No socket mounted)"
fi

# 4. Sensitive Environment Variables Leak (DENY expected)
echo -n "[4/4] Testing environment variables leak... "
LEAKED_VARS=$(env | grep -E '^(AWS_|GITHUB_|GH_|ANTHROPIC_|OPENAI_|GOOGLE_)' || true)
if [ -n "$LEAKED_VARS" ]; then
    echo "FAIL (Leaked sensitive env vars: $LEAKED_VARS)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
else
    echo "PASS (No sensitive credentials found in env)"
fi

echo "=========================================="
if [ $FAILED_ISOLATION -eq 0 ]; then
    echo "RESULT: ALL FILESYSTEM & SECRET ISOLATION TESTS PASSED"
    exit 0
else
    echo "RESULT: ISOLATION TESTS FAILED ($FAILED_ISOLATION failures)"
    exit 1
fi
