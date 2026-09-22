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
        ├── SmolLM 135M (事前キャッシュ済み、完全オフライン動作)
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
* **LLM**: SmolLM 135M (~91MB / 完全オフライン事前焼き込み)

---

## クイックスタート

### 1. サンドボックスコンテナのビルド

```bash
podman build -t cline-sandbox:v2 -f sandbox/Containerfile sandbox
```

※イメージ内に `smollm:135m` が焼き込まれるため、起動後は完全オフラインで動作します。

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
