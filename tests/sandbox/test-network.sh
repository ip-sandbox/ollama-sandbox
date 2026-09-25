#!/bin/bash
echo "=========================================="
echo " Running Network Isolation Test (--network=none) "
echo "=========================================="

FAILED_ISOLATION=0

# 1. Localhost Ollama API (ALLOW expected)
echo -n "[1/5] Testing Localhost Ollama API (127.0.0.1:11434)... "
if curl -s -m 3 http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
    echo "PASS (Connected as expected)"
else
    echo "FAIL (Cannot reach localhost Ollama)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
fi

# 2. DNS Resolution (DENY expected)
echo -n "[2/5] Testing DNS lookup (github.com)... "
if getent hosts github.com > /dev/null 2>&1; then
    echo "FAIL (DNS resolution succeeded - network leak!)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
else
    echo "PASS (DNS lookup blocked)"
fi

# 3. HTTP Connection (DENY expected)
echo -n "[3/5] Testing HTTP connection (http://example.com)... "
if curl -s -m 3 http://example.com > /dev/null 2>&1; then
    echo "FAIL (HTTP connected - network leak!)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
else
    echo "PASS (HTTP connection blocked)"
fi

# 4. HTTPS Connection (DENY expected)
echo -n "[4/5] Testing HTTPS connection (https://github.com)... "
if curl -s -m 3 https://github.com > /dev/null 2>&1; then
    echo "FAIL (HTTPS connected - network leak!)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
else
    echo "PASS (HTTPS connection blocked)"
fi

# 5. Direct External IP Connection (DENY expected)
echo -n "[5/5] Testing Direct External IP (http://1.1.1.1)... "
if curl -s -m 3 http://1.1.1.1 > /dev/null 2>&1; then
    echo "FAIL (Direct IP connected - network leak!)"
    FAILED_ISOLATION=$((FAILED_ISOLATION + 1))
else
    echo "PASS (Direct IP connection blocked)"
fi

echo "=========================================="
if [ $FAILED_ISOLATION -eq 0 ]; then
    echo "RESULT: ALL NETWORK ISOLATION TESTS PASSED"
    exit 0
else
    echo "RESULT: NETWORK ISOLATION TESTS FAILED ($FAILED_ISOLATION failures)"
    exit 1
fi
