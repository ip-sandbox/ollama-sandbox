#!/bin/bash
# proxy.sh - ネットワーク許可モード: 許可リストのドメインにだけ出られる状態で sandbox を動かす
#
#   proxy.sh run [podman run のオプション...] IMAGE [コマンド...]
#       プロキシを用意して sandbox を起動し、終わったらプロキシを片付ける
#   proxy.sh up | down | status
#
# 構成:
#   sandbox ──(内部ネットワーク: 外への経路も外部 DNS も無い)── proxy ──(出口ネットワーク)── 外部
#
#   - sandbox は $SANDBOX_INTERNAL_NET（podman network create --internal）だけにつなぐ。
#     外部 IP への直接接続・外部名の DNS 解決・ホストへの接続はできない。
#   - proxy（tinyproxy）は内部と出口 $SANDBOX_EGRESS_NET の両方につなぎ、
#     sandbox/proxy/allowlist に一致するホストだけを中継する。それ以外は 403。
#   - 出口ネットワークは既定の "podman" ではなく専用に作る。DNS を有効にした専用ネットワークを
#     先につながないと、proxy の名前解決が内部ネットワーク側の DNS（外部名を解決しない）に向いてしまう。
#   - sandbox には HTTP(S)_PROXY と NO_PROXY=127.0.0.1,localhost を渡す。
#     Cline / Codex からコンテナ内 Ollama への通信はプロキシを通らない。
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/scripts/config.sh"
ALLOWLIST="$DIR/sandbox/proxy/allowlist"
PROXY_URL="http://$SANDBOX_PROXY_NAME:8888"
NO_PROXY_HOSTS="127.0.0.1,localhost,::1"

ensure_network() {  # ensure_network <name> [--internal]
  podman network exists "$1" || podman network create "${@:2}" "$1" >/dev/null
}

up() {
  if ! podman image exists "$SANDBOX_PROXY_IMAGE"; then
    echo "[proxy] イメージをビルドします: $SANDBOX_PROXY_IMAGE（初回のみ、ネットワークが必要）"
    podman build -q -t "$SANDBOX_PROXY_IMAGE" "$DIR/sandbox/proxy" >/dev/null
  fi
  ensure_network "$SANDBOX_INTERNAL_NET" --internal
  ensure_network "$SANDBOX_EGRESS_NET"
  if [ "$(podman container inspect -f '{{.State.Running}}' "$SANDBOX_PROXY_NAME" 2>/dev/null)" != true ]; then
    podman rm -f "$SANDBOX_PROXY_NAME" >/dev/null 2>&1 || true
    # 出口ネットワークを先に指定する（DNS の順序。冒頭のコメント参照）
    podman run -d --rm --name "$SANDBOX_PROXY_NAME" \
      --network "$SANDBOX_EGRESS_NET" --network "$SANDBOX_INTERNAL_NET" \
      -v "$ALLOWLIST:/etc/tinyproxy/allowlist:ro" \
      "$SANDBOX_PROXY_IMAGE" >/dev/null
  fi
  echo "[proxy] 起動中: $SANDBOX_PROXY_NAME（許可リスト: $ALLOWLIST）"
}

down() {
  # 他の sandbox がまだ内部ネットワークを使っていれば止めない
  local others
  others="$(podman ps --filter "network=$SANDBOX_INTERNAL_NET" --format '{{.Names}}' | grep -cvx "$SANDBOX_PROXY_NAME" || true)"
  if [ "${others:-0}" -gt 0 ]; then
    echo "[proxy] 他の sandbox が使用中のため、プロキシは止めません"
    return 0
  fi
  podman rm -f "$SANDBOX_PROXY_NAME" >/dev/null 2>&1 || true
}

status() {
  podman ps -a --filter "name=^$SANDBOX_PROXY_NAME\$" --format '{{.Names}} {{.Status}}'
  echo "許可リスト:"
  grep -vE '^\s*(#|$)' "$ALLOWLIST" | sed 's/^/  /'
  echo "最近の拒否:"
  podman logs "$SANDBOX_PROXY_NAME" 2>&1 | grep -E 'refused on filtered' | tail -10 | sed 's/^/  /' || true
}

run_sandbox() {
  up
  echo "[proxy] 許可されている接続先:"
  grep -vE '^\s*(#|$)' "$ALLOWLIST" | sed 's/^/    /'
  set +e
  podman run --rm \
    --network "$SANDBOX_INTERNAL_NET" \
    -e HTTP_PROXY="$PROXY_URL" -e HTTPS_PROXY="$PROXY_URL" \
    -e http_proxy="$PROXY_URL" -e https_proxy="$PROXY_URL" \
    -e NO_PROXY="$NO_PROXY_HOSTS" -e no_proxy="$NO_PROXY_HOSTS" \
    "$@"
  local rc=$?
  set -e
  down
  return $rc
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  run) shift; run_sandbox "$@" ;;
  *) echo "usage: $0 run [podman run options...] IMAGE [command...] | up | down | status" >&2; exit 2 ;;
esac
