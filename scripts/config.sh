# config.sh - sandbox の共通設定（run.sh・テスト・launcher.py・research/ が読む唯一の定義）
#
# launcher.py は KEY="${KEY:-値}" の形の行を読んで既定値を取り出す。形を変えないこと。
# 環境変数で上書きできる（例: SANDBOX_IMAGE=localhost/cline-sandbox:v4 ./scripts/run.sh）。

SANDBOX_IMAGE="${SANDBOX_IMAGE:-localhost/cline-sandbox:v3}"
MODEL_VOLUME="${MODEL_VOLUME:-ollama-models}"

# ネットワーク許可モード（scripts/proxy.sh）。sandbox は外に出られない内部ネットワークだけにつなぎ、
# 外向き通信は許可リスト付きプロキシ（sandbox/proxy/）を経由させる
SANDBOX_PROXY_IMAGE="${SANDBOX_PROXY_IMAGE:-localhost/cline-sandbox-proxy:v1}"
SANDBOX_PROXY_NAME="${SANDBOX_PROXY_NAME:-cline-sandbox-proxy}"
SANDBOX_INTERNAL_NET="${SANDBOX_INTERNAL_NET:-cline-sandbox-internal}"
SANDBOX_EGRESS_NET="${SANDBOX_EGRESS_NET:-cline-sandbox-egress}"
