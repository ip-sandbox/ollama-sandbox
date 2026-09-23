# Cline CLI + Ollama Podman Sandbox

Linux (x86_64) 環境向けに、AIコーディングエージェント Cline CLI と超小型ローカルLLM（Ollama + SmolLM 135M）を同一の Podman コンテナ内に隔離して実行するサンドボックス環境です。

`--network=none` により、コンテナから外部インターネットやLANへの通信を完全に遮断しつつ、コンテナ内部の loopback (`127.0.0.1`) を介して Cline と Ollama 間の推論通信を成立させます。

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
    └── Cline Sandbox Container (cline-sandbox:v2)
        ├── Cline CLI (v3.0.64 / Node.js 22 LTS)
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
* **初期疎通用LLM**: SmolLM 135M (~91MB / イメージに焼き込み)

### 次期モデル検証結果

`qwen3:8b` を別のPodman named volumeへ保存し、`--network=none` 下で検証しました。

* Ollama `/api/chat` + `tools`: `get_weather(city="Tokyo")` のtool call生成に成功
* Clineエージェントループ: `editor` toolによる `/workspace/hello.txt` 作成と完了応答を確認
* CPUのみでは初回Cline推論に約5分を要するため、`--thinking none` の指定を推奨
* モデルが指定内容を厳密に再現せず、要求した `hello from qwen3` ではなく `hello` を書き込んだため、内容忠実性は未検証

`qwen3:8b` は既存の `cline-sandbox:v2` イメージには焼き込んでいません。再現する場合は、モデルを保存したvolumeを `/models` にマウントし、`OLLAMA_MODELS=/models` を設定してください。

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
* `mistral-nemo:12b-instruct-2407-q4_K_M`

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
podman build -t cline-sandbox:v2 -f sandbox/Containerfile sandbox
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

### 3. サンドボックスの対話起動

```bash
./scripts/run.sh
```

コンテナ内に入り、`cline` コマンドで対話操作やタスク実行が可能です。

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
