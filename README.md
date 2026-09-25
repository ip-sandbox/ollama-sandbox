# Cline CLI / Codex CLI + Ollama Podman Sandbox

Linux (x86_64) 環境向けに、AIコーディングエージェント Cline CLI・Codex CLI と超小型ローカルLLM（Ollama + SmolLM 135M）を同一の Podman コンテナ内に隔離して実行するサンドボックス環境です。

`--network=none` により、コンテナから外部インターネットやLANへの通信を完全に遮断しつつ、コンテナ内部の loopback (`127.0.0.1`) を介して各エージェントと Ollama 間の推論通信を成立させます。

---

## 構成概要

```text
Linux Host
│
├── sandbox/
│   ├── workspace/              ← ホスト側の作業ディレクトリ
│   └── Containerfile
│
└── Podman (--network=none)
    │
    └── Cline Sandbox Container (cline-sandbox:v3)
        ├── Cline CLI (v3.0.64 / Node.js 22 LTS)
        ├── Codex CLI (v0.156.1)
        ├── Ollama Server (v0.34.2)
        ├── Ollama model volume (選択したモデルを事前キャッシュ)
        ├── /workspace (マウント)
        └── localhost:11434 (内部loopback通信のみ許可)
```

---

## 検証済み環境

* **ホストOS**: Linux (x86_64)
* **Podman**: version 5.8.2 (Rootless)
* **SELinux**: Disabled 前提
* **コンテナOS**: Ubuntu 24.04 LTS ベース
* **Node.js**: v22.23.2
* **Cline CLI**: 3.0.64
* **Codex CLI**: 0.156.1
* **Ollama**: 0.34.2
* **初期疎通用LLM**: SmolLM 135M (~91MB / イメージに焼き込み)

### 次期モデル検証結果

`qwen3:8b` を別のPodman named volumeへ保存し、`--network=none` 下で検証しました。

* Ollama `/api/chat` + `tools`: `get_weather(city="Tokyo")` のtool call生成に成功
* Clineエージェントループ: `editor` toolによる `/workspace/hello.txt` 作成と完了応答を確認
* CPUのみでは初回Cline推論に約5分を要するため、`--thinking none` の指定を推奨
* モデルが指定内容を厳密に再現せず、要求した `hello from qwen3` ではなく `hello` を書き込んだため、内容忠実性は未検証

`qwen3:8b` はイメージには焼き込んでいません。再現する場合は、モデルを保存したvolumeを `/models` にマウントし、`OLLAMA_MODELS=/models` を設定してください。

## モデルの準備とTUIランチャー

`entrypoint.sh` はモデルが見つからない場合に自動pullしません。モデルのダウンロードは、ネットワークを有効にした準備操作で明示的に行います。モデルを選択するだけで準備と起動を行うには、ホストで以下を実行してください。

コンテナを直接起動する場合は、使用するモデルを`CLINE_MODEL`環境変数で必ず指定してください。未指定の場合、entrypointはエラー終了します。

```bash
./scripts/run.sh
```

Python標準ライブラリだけで動作するTUIで、次のモデルを選択できます。

* `qwen3:8b`
* `gemma4:12b-it-qat`
* `gpt-oss:20b`
* `devstral-small-2:24b-iq4_xs`（Devstral Small 2 24B Instruct 2512 の IQ4_XS）

`devstral-small-2:24b-iq4_xs` は Ollama registry に無い量子化なので、`ollama pull` ではなく `scripts/import_gguf_model.sh` で取り込みます。
* 重み: Unsloth の GGUF（12,187 MiB）を Hugging Face から取得し、sha256 を照合する。
* テンプレート: Ollama 公式タグ `devstral-small-2:24b-instruct-2512-q4_K_M` の Go テンプレートを移植する。
* 詳細は `docs/DEVSTRAL_RESULT.md` を参照してください。

`mistral-nemo:12b-instruct-2407-q4_K_M` は一覧から外しました。Cline・Codex のどちらでもツールを正しく呼べなかったためです（`docs/MODEL_E2E_RESULT.md` / `docs/MODEL_E2E_CODEX_RESULT.md`）。既にダウンロード済みの場合は「ダウンロード済みモデルを削除」から削除できます。

「ダウンロードしてsandboxを起動」を選ぶと、モデルを `ollama-models` named volumeへpullした後、同じモデルを `--network=none` のsandboxで起動します。「モデルをダウンロード」と「sandboxを起動」を別々に選ぶこともできます。モデルを追加する場合は、ネットワークを有効にしたダウンロード操作が必要です。

モデル選択画面には、各モデルのダウンロード済み／未ダウンロード状態が表示されます。メインメニューの「ダウンロード済みモデルを削除」から、不要なモデルを選択して削除できます。削除前には確認画面が表示され、モデルvolume自体は削除されません。

ランチャーのunit testは、追加依存なしで標準ライブラリの`unittest`を使って実行できます。

```bash
python3 -m unittest discover -s tests -v
```

---

## クイックスタート

### 1. サンドボックスコンテナのビルド

```bash
podman build -t cline-sandbox:v3 -f sandbox/Containerfile sandbox
```

※イメージ内には初期疎通用の `smollm:135m` が焼き込まれています。実用モデルはTUIランチャーでnamed volumeへ事前ダウンロードしてください。

### 2. 総合テストの実行（隔離性・推論・CLI疎通）

```bash
./scripts/test-sandbox.sh
```

このスクリプトは以下を自動検証します：
* **ネットワーク完全遮断**: DNS, HTTP, HTTPS, 外部IP直接接続がすべて遮断され、`127.0.0.1:11434` (Ollama) のみが許可されていること
* **ファイルシステム隔離**: `/workspace` のみが読み書き可能であり、ホストの機密情報やコンテナソケットへのアクセスが遮断されていること
* **オフライン推論**: 完全ネットワーク遮断下で SmolLM 135M が推論を返せること
* **Cline CLI 疎通**: Cline CLI が正常に起動すること
* **Codex CLI 起動・設定**: Codex CLI が起動し、Ollama 向けの設定が生成されていること

### 3. サンドボックスの対話起動

```bash
./scripts/run.sh
```

コンテナ内に入り、`cline` または `codex` コマンドで対話操作やタスク実行が可能です。起動時に使い方が表示されます。

```bash
cline                                         # Cline CLI（Ollama 設定済み。-P 指定は不要）
echo "<prompt>" | cline                       # 非対話（日本語は引数ではなくパイプで渡す）
codex                                         # Codex CLI（承認ポリシー: on-request）
codex -a never                                # Codex を全自動で起動（セッション中は /permissions で変更）
codex exec -c approval_policy='"never"' "<prompt>"   # 非対話・全自動
```

---

## エージェント設定（entrypoint が起動時に生成）

| 対象 | 内容 |
|---|---|
| Ollama | `OLLAMA_CONTEXT_LENGTH=32768`（Codex は `num_ctx` を送らないため必須。CPU の既定 4k では黙って切り詰められる）、`OLLAMA_KEEP_ALIVE=-1`（prompt cache 維持）、`OLLAMA_LOAD_TIMEOUT=30m` |
| Cline | `~/.cline/data/settings/providers.json` に Ollama プロバイダを登録し、リクエストタイムアウト `timeout=1800000`（30 分）を設定。Bun fetch の既定 300 秒は `BUN_OPTIONS` の preload（`/usr/local/lib/cline/bun-fetch-no-timeout.js`）で外す |
| Codex | `~/.codex/config.toml` に、プロバイダ `ollama-local`（`ollama` は予約済み）、`wire_api = "responses"`、`sandbox_mode = "danger-full-access"`（コンテナ自体が隔離境界。Codex の seccomp/landlock はコンテナ内で動かない）、`approval_policy = "on-request"` を設定 |

いずれも `podman run -e` で上書きできます: `OLLAMA_CONTEXT_LENGTH` / `OLLAMA_KEEP_ALIVE` / `CLINE_TIMEOUT_MS` / `CODEX_APPROVAL_POLICY`（`never` で全自動）/ `CODEX_STREAM_IDLE_TIMEOUT_MS`

### CPU 推論の所要時間（Ryzen 5 PRO 4650G 4 コア）

prefill（プロンプト処理）は約 8 tok/s です。**1 ターン目はエージェントのシステムプロンプト全体を処理するので長く、2 ターン目以降は prompt cache によって差分だけになります。**

| エージェント | 1 ターン目のプロンプト | 1 ターン目 | 2 ターン目以降 | hello.txt タスク全体 |
|---|---:|---:|---:|---:|
| Cline | 約 4,500 tok | 約 9 分 | 20〜55 秒 | 約 10〜11 分 |
| Codex | 約 8,400 tok | 約 18 分 | 25〜30 秒 | 約 19 分 |

上表は gemma4:12b-it-qat の値です。他のモデルの hello.txt タスク全体の所要時間:

| モデル | prefill | Cline | Codex |
|---|---:|---:|---:|
| gemma4:12b-it-qat | 約 8 tok/s | 約 10 分 | 約 19 分 |
| gpt-oss:20b | 約 20 tok/s | 約 5 分 | 約 21 分（apply_patch の失敗を 4 回挟む） |
| devstral-small-2:24b-iq4_xs | 約 4.6 tok/s | 約 20 分 | 約 28 分 |

devstral は Cline の 1 ターン目が約 19 分で、既定のリクエストタイムアウト（30 分）に近いです。長い指示を渡す場合は `-e CLINE_TIMEOUT_MS=3600000` で延ばしてください。

タイムアウト調査の詳細は `docs/RESULT.md`、Codex 対応の検証結果は `docs/CODEX_RESULT.md` を参照してください。

---

## セキュリティ特性

1. **ネットワーク完全遮断 (`--network=none`)**
   - 外部インターネット、LAN、ホスト側サービスへのアクセス不可
   - ソースコードやクレデンシャルの外部流出を物理的に防止
2. **ファイルシステム最小マウント**
   - マウントされるのは `./sandbox/workspace` のみ
   - ホストの root filesystem や `$HOME`、Docker/Podman socket (`/var/run/docker.sock`) は一切マウントされません
3. **特権モードの禁止**
   - `--privileged` は使用せず、rootless Podman で動作します
