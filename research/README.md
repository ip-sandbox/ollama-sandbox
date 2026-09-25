# research/ — 検証用スクリプト

sandbox 本体（`scripts/` `sandbox/`）の動作には不要な、調査・計測用の道具です。結果は `docs/results/` に残しています。

- 共通の環境は `env.sh` にあります。イメージ名と model volume は `scripts/config.sh` を読みます。
- 生成物は `.state/` に、ホスト用の Python（uv で作った 3.12）は `.venv/` に置きます。どちらも git の管理外です。

| フォルダ | 役割 | 主なファイル |
|---|---|---|
| `host/` | ホスト上で Cline / Ollama を動かす（コンテナを使わない検証） | `setup-host.sh`（Node 22・cline・venv・ollama の用意）、`ollama-host.sh`、`set-timeout.sh`、`run-e2e.sh`、`bench_prefill.py` |
| `stubs/` | 偽 Ollama で、どの層が何秒で切るかを実モデル無しで測る | `slow_ollama_stub.py`、`probe-timeout.sh`（Cline）、`probe-codex-timeout.sh`（Codex）、`container-probe.sh`、`bun_fetch_probe.js`、`sse_timing.py` |
| `e2e/` | sandbox イメージの既定設定のまま、実モデルで実タスクを走らせる | `e2e.sh --agent cline\|codex [--model M] [--codex-catalog DUMP] [--debug]` |
| `models/` | モデル個別の調査 | `devstral-probe.sh` / `devstral_probe.py`（ツール呼び出しと速度）、`probe-apply-patch.sh` / `make_codex_catalog.py`（Codex の apply_patch） |

## 旧 `cpu-timeout/` などからの対応

`docs/results/` の本文は検証当時のファイル名で書かれています。

| 旧 | 新 |
|---|---|
| `cpu-timeout/env.sh` | `research/env.sh`（変数名は `CT_*` → `RS_*`） |
| `setup-host.sh` `ollama-host.sh` `set-timeout.sh` `run-e2e.sh` `bench_prefill.py` | `research/host/` |
| `slow_ollama_stub.py` `probe-timeout.sh` `probe-codex-timeout.sh` `container-probe.sh` `bun_fetch_probe.js` `sse_timing.py` | `research/stubs/` |
| `devstral-probe.sh` `devstral_probe.py` `make_codex_catalog.py` `probe-apply-patch.sh` | `research/models/` |
| `v3-e2e.sh <agent>` | `research/e2e/e2e.sh --agent <agent>` |
| `model-e2e.sh <model>` | `research/e2e/e2e.sh --agent cline --model <model>` |
| `model-e2e-codex.sh <model>` | `research/e2e/e2e.sh --agent codex --model <model>` |
| `apply-patch-e2e.sh <model> <dump>` | `research/e2e/e2e.sh --agent codex --model <model> --codex-catalog <dump> --debug` |
| `container-e2e.sh` | 削除（v2 にタイムアウト対策を外付けしていた検証。v3 以降はイメージに組み込み済み） |
| `bun-fetch-no-timeout.js` | 削除（本番の `sandbox/scripts/bun-fetch-no-timeout.js` を使う） |
| `devstral-import.sh` `fetch_ollama_template.py` | 削除（`scripts/import_gguf_model.sh` に統合。launcher から実行する） |
| `scripts/test-sandbox.sh` `test-network.sh` `test-filesystem.sh` | `tests/sandbox/`（テスト用スクリプトは workspace にコピーせず、`/tests` に読み取り専用でマウントする） |
| `tests/test_launcher.py` | `tests/unit/test_launcher.py` |

補足: 旧 E2E スクリプトのプロンプトは `hello from gemma4 on cpu` や `hello from cline` などでした。`e2e.sh` では `hello from <agent>` に統一しています。
