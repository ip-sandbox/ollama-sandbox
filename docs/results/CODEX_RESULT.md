# Codex CLI 対応 結果（cline-sandbox:v3）

> **注（2026-09-25 のファイル整理）:** 本文中のスクリプト名・パスは検証当時のものです。`cpu-timeout/` は `research/` に役割別に再編し、`scripts/test-*.sh` は `tests/sandbox/` に移しました。旧名と新名の対応は [research/README.md](../../research/README.md) を参照してください。

計画: [CODEX_PLAN.md](../plans/CODEX_PLAN.md)

---

## 段階1: 切り分け（実モデル不使用）

### 結論

- **v3 イメージで Cline と Codex の両方が `--network=none` 下で動き、400 秒の無音（CPU prefill 相当）を最後まで待てた**（コンテナ内実測）。
- **Codex には Cline のような「300 秒の壁」は無い。** 最初のバイトまでの待ち時間は、`stream_idle_timeout_ms` を 60 秒にしても縛られなかった。縛られるのは SSE イベント間の間隔だけ。
- **Codex は `num_ctx` を送らない。** プロンプトは約 9,700 トークンで、Cline（4,450）の約 2 倍ある。`OLLAMA_CONTEXT_LENGTH` の指定は必須で、entrypoint で 32768 を設定した。

### v3 イメージの構成

| 項目 | 値 |
|---|---|
| ベース | Ubuntu 24.04 / Node.js 22 / Python 3.12.3（システム同梱） |
| Ollama | 0.34.2（`OLLAMA_VERSION` で固定。以前は install.sh が最新を取っていた） |
| Cline CLI | 3.0.64（固定） |
| Codex CLI | 0.156.1（固定） |
| サイズ | 3.93GB（v2: 3.28GB）。初期疎通用の SmolLM 135M を焼き込み済み |

層の順序を「Ollama → エージェント」に変えた。エージェントの版を上げても、約 2GB ある Ollama の層は再ダウンロードされない。

### entrypoint が起動時に行うこと

| 対象 | 設定 | 理由 |
|---|---|---|
| Ollama | `OLLAMA_LOAD_TIMEOUT=30m` / `OLLAMA_KEEP_ALIVE=-1` / `OLLAMA_CONTEXT_LENGTH=32768`（いずれも `-e` で上書き可） | ロード停滞対策、prompt cache 維持、Codex の切り詰め防止 |
| Cline | `cline auth -p ollama` を実行してから `providers.json` に `timeout=1800000` と `lastUsedProvider=ollama` を設定 | Cline 側の 300 秒対策。**`-P ollama` 無しの素の `cline` でも Ollama に行く**ことを確認した |
| Cline | `ENV BUN_OPTIONS=--preload /usr/local/lib/cline/bun-fetch-no-timeout.js`（Containerfile） | Bun fetch 側の 300 秒対策。ENV なので hub daemon にも効く |
| Codex | `~/.codex/config.toml` を生成（下記） | プロバイダ `ollama-local`、`wire_api=responses`、`danger-full-access`、承認 `on-request` |

旧 entrypoint が書いていた `~/.cline/settings.json` は 3.x では読まれないので廃止した。

```toml
model = "<CLINE_MODEL>"
model_provider = "ollama-local"          # "ollama" は予約済みで使えない
model_context_window = 32768             # OLLAMA_CONTEXT_LENGTH と同じ
approval_policy = "on-request"           # CODEX_APPROVAL_POLICY で変更可
sandbox_mode = "danger-full-access"      # コンテナが隔離境界
check_for_update_on_startup = false
[model_providers.ollama-local]
base_url = "http://127.0.0.1:11434/v1"
wire_api = "responses"
stream_idle_timeout_ms = 1800000         # CODEX_STREAM_IDLE_TIMEOUT_MS で変更可
request_max_retries = 0                  # CPU で 10 分超の prefill を再送させない
stream_max_retries = 0
[projects."/workspace"]
trust_level = "trusted"
```

`codex exec --strict-config`（未知のキーがあるとエラーにするオプション）で、すべてのキーが有効なことを確認した。

### 承認ポリシーの切り替え（利用者が起動後に変えられる）

| 方法 | 書き方 |
|---|---|
| コンテナ起動時 | `-e CODEX_APPROVAL_POLICY=never` |
| TUI 起動時 | `codex -a never` |
| 非対話 | `codex exec -c approval_policy='"never"' "<prompt>"`（exec に `-a` は無い） |
| セッション中 | TUI で `/permissions` |

### 実測 1: Codex のタイムアウト（ホスト、`probe-codex-timeout.sh`）

同じ codex 0.156.1 を `.state/codex-npm` に隔離して入れ、`CODEX_HOME` も隔離した。ホストの `~/.codex` には触れていない。

| stream_idle_timeout_ms | 上流 | 経過 | exit | 結果 |
|---:|---|---:|---:|---|
| 1800000 | 5s 無音 | 7s | 0 | 完走 |
| **60000** | **400s 無音**（先頭バイトまで） | 402s | 0 | **完走** ← idle は先頭バイトまでの時間を縛らない |
| 30000 | 最初のイベント即、その後 90s 無音 | 31s | 1 | **30.2s で切断** ← 縛るのはイベント間の間隔 |
| 1800000 | 400s 無音 | 402s | 0 | 完走 |
| 1800000 | ヘッダ即・本文 700s | 702s | 0 | 完走 |
| 1800000 | 1200s 無音 | 1201s | 0 | 完走（20 分の無音でも OK） |

どのケースでも再送は 0 回（`request_max_retries=0`、`/v1/responses` は 1 回だけ）。

**段階2で確認が要る点**: 本物の Ollama が `/v1/responses` で prefill の前に `response.created` などのイベントを先に送るなら、prefill 全体がイベント間の間隔になる。その場合は `stream_idle_timeout_ms` に当たる。そのため 1800000 に設定してある。実際の挙動は段階2で見る。

### 実測 2: v3 コンテナ内で Cline と Codex（`container-probe.sh`）

v3 の既定設定のまま、コンテナ内の Ollama を止めて遅延スタブ（コンテナ内の Python 3.12 で実行）に差し替えた。

| エージェント | 上流 | 経過 | exit | 結果 |
|---|---|---:|---:|---|
| `cline`（`-P` 無しの素の起動） | 400s 無音 | 404s | 0 | 完走（preload 読み込みを確認） |
| `codex exec` | 400s 無音 | 406s | 0 | 完走 |

### 実測 3: Codex のリクエスト内容（スタブで記録）

| 項目 | 値 |
|---|---|
| instructions | 16,979 文字 |
| input | 3 項目 / 3,897 文字（skills 説明と environment_context を含む） |
| tools | 9 個 / 17,785 文字: `exec_command`, `write_stdin`, `request_user_input`, `view_image`, `multi_agent_v1`, `get_goal`, `create_goal`, `update_goal`, `web_search` |
| 概算トークン | **約 9,700**（Cline の約 2.2 倍） |
| `num_ctx` / `options` | **無し**。Ollama 側の `OLLAMA_CONTEXT_LENGTH` がそのまま効く |
| 起動時の通信 | `/v1/models` と `/v1/responses` だけ。`--network=none` のコンテナで、外部への通信待ちによる停滞は無かった（モデル不在のエラーが 1 秒で返った） |

この機械の prefill 速度（8 tok/s）だと、**Codex の 1 ターン目は prefill だけで約 20 分**かかる見込み。オフラインで使えないツール（`web_search`、`multi_agent_v1` など）を無効化すればプロンプトを縮められる可能性がある。段階2で検討する。

### 統合テスト

- `scripts/test-sandbox.sh`（v3、TEST 5 に Codex を追加）: **全 5 テスト PASS**
- `python3 -m unittest discover -s tests`: 2 テスト OK

### 変更したファイル

| ファイル | 変更 |
|---|---|
| `sandbox/Containerfile` | Ollama・Cline・Codex の版を固定、層の順序を変更、preload の COPY と `ENV BUN_OPTIONS` |
| `sandbox/scripts/entrypoint.sh` | Ollama の環境変数、Cline の providers.json、Codex の config.toml、起動時の案内 |
| `sandbox/scripts/bun-fetch-no-timeout.js` | 新規（`cpu-timeout/` からコピー） |
| `scripts/launcher.py` / `scripts/run.sh` / `scripts/test-sandbox.sh` | イメージを v3 に変更、TEST 5（Codex）を追加 |
| `cpu-timeout/slow_ollama_stub.py` | `/v1/responses`（SSE）と `/v1/models`、`gap` モードを追加 |
| `cpu-timeout/probe-codex-timeout.sh` / `container-probe.sh` | 新規 |

README の更新は段階2で行う。

### 片付け

- 不要なイメージ（タグなし × 3、v1）と、中断したビルドの作業コンテナ 13 個を削除した。残りは v3 / v2。空きは 19GB。

---

## 段階2: 実モデル E2E

### 結論

**v3 コンテナ（`--network=none`、既定設定のまま）で、Codex と Cline の両方が gemma4:12b-it-qat の CPU 推論で hello.txt タスクを完走した。** 文脈の切り詰めも無かった（`truncated = 0`）。

### 1. Ollama の `/v1/responses` は prefill が終わるまで何も送らない（`sse_timing.py`）

段階1で残った疑問を確かめた。本物の Ollama が prefill の前に SSE イベントを送るなら、prefill 全体が Codex の `stream_idle_timeout_ms` に当たる。

| 経過 | 受信 |
|---:|---|
| 0〜380.2s | **何も来ない（HTTP ヘッダも来ない）**。prefill 3,102 tok / 379.1s（8.2 tok/s） |
| 380.2s | HTTP 200、`response.created`、`response.in_progress`、`response.output_item.added` がまとめて届く |
| 384.0s | `response.completed` |

→ prefill は「最初のバイトまでの時間」になる。段階1の実測どおり、`stream_idle_timeout_ms` はこの時間を縛らない。**Codex では prefill がどれだけ長くても切れない。** idle が効くのは生成中のイベント間隔だけで、CPU の生成（約 3 tok/s）なら間隔は 1 秒未満。既定の 1800000 は十分すぎる余裕。

### 2. E2E（`v3-e2e.sh`、launcher と同じ `podman run`、毎回 cold から開始）

タスク（英語）: `hello.txt` を作り、中身を `hello from gemma4 on cpu` にする。

| エージェント | 実行コマンド | 経過 | exit | hello.txt |
|---|---|---:|---:|---|
| **Codex** | `codex exec --skip-git-repo-check -c approval_policy='"never"' -` | **1,132s（18.9 分）** | **0** | `hello from gemma4 on cpu`（完全一致） |
| **Cline** | `cline --thinking none`（`-P` 無し、パイプ入力） | **609s（10.2 分）** | **0** | `hello from gemma4 on cpu`（完全一致） |

リクエストごとの内訳（Ollama ログ。prefill は差分トークン数）:

| エージェント | ターン | 所要 | prefill | 文脈累計 | truncated |
|---|---|---:|---:|---:|---|
| Codex | 1 | 17m45s | 8,352 tok / 1,014s（8.2 tok/s） | 8,473 | 0 |
| Codex | 2 | 30.0s | 102 tok | 8,567 | 0 |
| Codex | 3 | 25.6s | 110 tok | 8,658 | 0 |
| Cline | 1 | 9m7s | 4,443 tok / 527s（8.4 tok/s） | 4,474 | 0 |
| Cline | 2 | 18.6s | 71 tok | 4,536 | 0 |
| Cline | 3 | 33.9s | 62 tok | 4,639 | 0 |

エージェントの動作:
- Codex: `exec_command` で `echo "hello from gemma4 on cpu" > hello.txt` → `cat hello.txt` で確認 → 完了報告
- Cline: `editor` で作成 → `read_files` で確認 → 完了報告

補足:
- Codex の実プロンプトは 8,352 トークン。スタブでの概算 9,700 より少し小さかった。Cline（4,443）の約 1.9 倍で、1 ターン目の時間もほぼ比例する（約 18 分 対 約 9 分）。
- 2 ターン目以降は、どちらも prompt cache で差分だけの prefill になる（`OLLAMA_KEEP_ALIVE=-1` が前提）。
- 実行時に `Model metadata for gemma4:12b-it-qat not found` という警告が出るが、動作には影響しなかった。

### 3. 最終テスト

- `scripts/test-sandbox.sh`（最終 v3 イメージ）: **全 5 テスト PASS**（ネットワーク遮断・FS 隔離・SmolLM 135M のオフライン推論・Cline 起動・Codex 起動と設定）
- `python3 -m unittest discover -s tests`: **2 テスト OK**

### 4. SmolLM 135M の焼き込みを復元（作業前からあった未コミット変更の取り消し）

作業前から、「SmolLM をイメージに焼き込むのをやめる」という未コミットの変更があった。その SmolLM 関連の部分だけを、v3/Codex 対応の変更を残したまま元に戻した。

- Containerfile: Ollama の層で `smollm:135m` を pull する処理を復元した（Ollama の版固定 0.34.2 は維持）
- `launcher.py`: `ENTRYPOINT_MODEL = "smollm:135m"`
- `test-sandbox.sh`: `CLINE_MODEL=smollm:135m`。TEST 3 を SmolLM の推論テストに戻した。元は `curl -s` だけで、モデルが無くても exit 0 で通ってしまうため、`--fail` を付けた
- README: SmolLM の記述 4 か所を復元した

再ビルドした v3 で `test-sandbox.sh` の全 5 テストが PASS した（TEST 3 で SmolLM が応答を返すことを確認）。

### 5. README

Codex の使い方、entrypoint が生成する設定、`-e` で上書きできる変数、CPU での所要時間の目安を追記した。

### 今回は扱っていないこと（必要なら別途）

- オフラインでは使えない Codex のツール（`web_search`、`multi_agent_v1` など）を無効化してプロンプトを縮め、1 ターン目を短くすること
- 起動直後に prompt cache を温めて、1 ターン目の待ち時間を隠すこと
- launcher の TUI にエージェント選択を足すこと（今はコンテナ内で `cline` / `codex` を打ち分ける）
