#!/bin/bash
set -e

# スクリプト自身のディレクトリからプロジェクトルートを特定
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$DIR/sandbox/workspace"
mkdir -p "$WORKSPACE_DIR"

echo "=== Starting Cline Sandbox (--network=none) ==="
podman run --rm -it \
    --network=none \
    -v "$WORKSPACE_DIR:/workspace:rw" \
    localhost/cline-sandbox:v2 \
    "$@"
