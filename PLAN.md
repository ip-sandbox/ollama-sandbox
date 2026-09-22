# Cline CLI + Ollama Podman Sandbox 構築計画

## 1. 目的

Oracle Linux / x86_64 のオンプレミスLinux環境上に、AIコーディングエージェントである Cline CLI をPodmanコンテナ内に隔離して実行する環境を構築する。

LLMバックエンドには Ollama を使用し、CPUのみで動作する超小型モデルを使用する。

初期モデルは `SmolLM 135M` を第一候補とする。なお、tool callingは最初のステップでは検証対象外とし、まず Cline CLI と Ollama の疎通および sandbox 隔離の検証を最優先とする。

最終的な構成では、Cline CLI、Ollama、LLMを同一のPodmanサンドボックス内に配置し、Clineから外部ネットワークへアクセスできない状態を実現する。

主目的は高性能なコーディング環境の構築ではなく、

* Cline CLIの動作確認
* Ollamaとの連携・疎通確認
* Podmanによるファイルシステム隔離
* Podmanによるネットワーク隔離
* 外部ネットワークへの情報流出防止
* ホストOSへのアクセス範囲の制限
* （※tool calling / agent loopの検証は初期ステップでは対象外とし、疎通・隔離成立後の将来ステップとする）

を検証することである。

---

# 2. 前提環境

## 2.1 ホスト

対象:

* Oracle Linux 9.4
* x86_64
* CPUのみ（AMD Ryzen 5 PRO 4650G 4コア等）
* メモリ: 30GB
* NVIDIA GPU等は使用しない
* Podmanを使用する
* rootless Podmanを第一候補とする
* SELinux: **Disabled を前提とする**（現状のホスト環境でDisabledに設定されているため、SELinux起因のパーミッション調整は前提としない）

最初に以下を確認すること。

```bash
cat /etc/os-release
uname -m
uname -r
id
getenforce
podman --version 2>/dev/null || echo "podman not installed"
```

※Podmanが未インストールの場合は、以下でインストールを行う。

```bash
sudo dnf install -y podman
```

x86_64であることを確認する。

---

# 3. 最終目標アーキテクチャ

最終的には以下の構成を目指す。

```text
Oracle Linux Host
│
├── Project / workspace
│       │
│       └── sandbox対象ディレクトリ
│
└── Podman
    │
    └── Cline Sandbox Container
        │
        ├── Cline CLI
        │
        ├── Ollama
        │   │
        │   └── SmolLM 135M
        │
        ├── /workspace
        │
        └── localhost
              │
              └── Ollama :11434
```

ネットワークは最終的に、

```text
Cline
  │
  ├── localhost → Ollama       OK
  │
  ├── localhost → その他       必要に応じて許可
  │
  └── Internet / LAN           NG
```

とする。

特に、

```text
Cline → GitHub
Cline → arbitrary HTTP/HTTPS
Cline → 外部API
Cline → インターネット
```

を禁止する。

---

# 4. 設計方針

## 4.1 最初から完全なセキュリティ構成にしない

以下の順番で構築する。

1. ホスト環境確認・Podman導入
2. Podman動作確認（rootless）
3. Cline CLI仕様確認（Node.js 22 + npm cline）
4. Ollama単体確認（curl install script）
5. SmolLM 135M確認（超小型モデルでの推論・疎通確認）
6. Cline → Ollama疎通確認（※tool callingは初期ステップでは検証対象外）
7. Podmanコンテナ化
8. workspace mount
9. ネットワーク遮断
10. セキュリティ検証
11. 必要に応じてread-only / capabilities / seccomp等を強化

各段階で動作確認を行う。

問題が発生した場合、最後に追加した制約を疑えるようにする。

---

# 5. モデル選定

## 第一候補

```text
SmolLM 135M (Ollama: smollm:135m)
```

理由:

* 非常に小型（約270MB）でダウンロード・起動が高速
* CPUのみでも負荷が極めて小さく、動作確認が素早く行える
* 本計画の初期ステップの主目的は「Cline CLIとOllamaの通信疎通」「Podmanによるファイルシステム隔離」「Podmanによるネットワーク遮断」の確認であるため、まずは軽量モデルで疎通を成立させる
* **tool calling は最初のステップでは検証対象外とする**（SmolLM 135M には複雑な推論や高度な tool calling / agent loop 能力は求めない）

目的は、

```text
Cline
  ↓
Ollama (localhost:11434)
  ↓
SmolLM 135M
  ↓
LLM Response
  ↓
Cline
```

という、sandbox内でのプロセス間通信・プロンプト/レスポンス疎通の確認である。

---

# 6. モデルの代替候補

SmolLM 135M での疎通が確認でき、次のステップとしてより高度な応答や将来的に tool calling を検証する場合の候補：

優先順位:

1. `smollm:135m`（初期ステップ：超軽量疎通・sandbox検証用）
2. `smollm:360m`（初期ステップ：少し語彙・推論力を上げたい場合）
3. `qwen2.5:0.5b`（初期ステップ〜中間ステップ：小型LLM）
4. `qwen2.5-coder:1.5b` / `qwen2.5-coder:7b`（将来ステップ：tool calling / コーディングエージェントループの本格検証用）

初期フェーズでは tool calling は検証対象外とし、まずは `smollm:135m` による環境構築とネットワーク・ファイルシステム隔離の成立に集中する。

---

# 7. Phase 0 — ホスト環境調査 & Podman導入

まずOracle Linux環境を調査し、Podmanがなければ導入する。

確認項目:

```bash
cat /etc/os-release
uname -a
uname -m
lscpu
free -h
df -h
getenforce
stat -fc %T /sys/fs/cgroup/
podman --version 2>/dev/null || echo "podman not installed"
```

※実機確認結果（反映済み）:
- OS: Oracle Linux Server 9.4 (x86_64)
- CPU: AMD Ryzen 5 PRO 4650G (4 cores)
- RAM: 30GiB (空き28GiB)
- Disk: /dev/sda3 71G (空き34G)
- SELinux: Disabled
- Node.js: ホスト側はv16.20.2だが、**コンテナ内にNode.js 22を入れる**
- Podman: ホスト未インストールのため、以下でインストールする

```bash
sudo dnf install -y podman
```

rootless Podman の確認:

```bash
podman info
```

---

# 8. Phase 1 — Podman基本動作確認

まず単純なコンテナを起動する。

```bash
podman run --rm docker.io/library/alpine:latest uname -a
```

※SELinuxは **Disabled を前提とする**。

確認:

```bash
podman run --rm alpine:latest echo "podman works"
```

成功条件:

* Podmanでコンテナを起動できる
* rootlessで問題なく動作する

---

# 9. Phase 2 — Cline CLIの導入方法を確定

Cline CLIの仕様およびコンテナ内導入方法：

* **コンテナ内で Node.js 22 を入れることを明記する**（ホスト環境のNode.jsバージョンに依存させない）。

パッケージおよび起動仕様:

```text
パッケージ名:  cline（npm install -g cline）
最新バージョン: 3.0.64（2026年9月時点）
CLI起動:      cline（インタラクティブ）
              cline "task" --auto-approve true（ヘッドレス）
設定ファイル:  ~/.cline/settings.json
Ollamaサポート: ネイティブ対応（provider: ollama）
```

設定ファイル例 (`~/.cline/settings.json`):
```json
{
  "apiProvider": "ollama",
  "ollamaModelId": "smollm:135m",
  "ollamaBaseUrl": "http://127.0.0.1:11434"
}
```

---

# 10. Phase 3 — Ollama導入

Ollamaをコンテナ内にインストールする。

Ollamaは、以下コマンドでコンテナ内に最新バージョンを入れる。

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

バージョン確認:

```bash
ollama --version
```

Ollama serverを起動し、

```text
127.0.0.1:11434
```

でAPIにアクセスできることを確認する（`curl http://127.0.0.1:11434/api/tags`）。

---

# 11. Phase 4 — SmolLM 135M確認

SmolLM 135M を取得する。

```bash
ollama pull smollm:135m
```

モデル一覧:

```bash
ollama list
```

単純な推論確認:

```bash
ollama run smollm:135m "Hello, who are you?"
```

を実行し、CPU上で超小型モデルが即座に応答することを確認する。

---

# 12. Phase 5 — Ollama 疎通確認（※初期ステップ）

Clineと接続する前に、Ollama API経由でプロンプトを送信し、正常なレスポンスが得られることを確認する。

※**tool calling は最初のステップでは検証対象外とする**。まずはHTTP APIとしてのプロンプト疎通が成立することを最優先とする。

API疎通確認例:

```bash
curl -s http://127.0.0.1:11434/api/generate -d '{
  "model": "smollm:135m",
  "prompt": "Say hello in one word",
  "stream": false
}'
```

成功条件:

```text
HTTP 200レスポンスが返り、JSON内の response フィールドにテキストが含まれること
```

---

# 13. Phase 6 — Cline + Ollama 疎通確認

Cline CLIを起動し、Ollama (`smollm:135m`) をbackendとして疎通を確認する。

※**tool calling は最初のステップでは検証対象外とする**。ここではCline CLIからOllamaへのリクエストが通り、LLMの応答をClineが受信して表示できることを確認する。

確認項目:

* モデル名設定 (`smollm:135m`)
* Ollama API endpoint (`http://127.0.0.1:11434`)
* streaming応答の確認
* CLIの起動とタスク投入の疎通

最初のテスト:

```bash
cline "Hello, this is a connectivity test." --auto-approve true
```

成功条件:

1. ClineがOllama (SmolLM 135M) にpromptを送る
2. Ollamaから応答が返り、Clineがその出力を正常に受け取って完了する（通信エラーやAPI接続エラーが発生しないこと）
---

# 14. Phase 7 — Sandbox Container作成

ここからPodman sandboxを構築する。

推奨構成:

```text
sandbox/
├── Containerfile
├── scripts/
│   ├── entrypoint.sh
│   └── ...
└── README.md
```

Containerfileには以下を含める。

* Oracle Linux互換または適切なLinux base image
* **Node.js 22**（公式NodeSourceまたはdnf/tarballで導入）
* Cline CLI (`npm install -g cline`)
* Ollama (`curl -fsSL https://ollama.com/install.sh | sh` で最新版を導入)
* 必要なruntime dependencies (`curl`, `git`, `procps` 等)

モデル（SmolLM 135M: 約270MB）については、以下の2方式を比較する。

### 方式A: コンテナ起動後にpull

```text
container
  ↓
ollama pull smollm:135m
```

利点:

* imageが小さい

欠点:

* 初回起動時にnetworkが必要
* 完全offline実行ができない

### 方式B: モデルをimageに含める

```text
Container Image
├── Cline
├── Ollama
└── SmolLM 135M
```

利点:

* 起動後完全offline可能
* 再現性が高い（サイズも約270MBの追加で済むため負担が極めて少ない）

欠点:

* build時にモデルダウンロードが必要

今回の最終目標は方式B。

ただし、まず方式Aでコンテナ内外の動作確認を行い、その後方式Bに移行する。

---

# 15. Phase 8 — ClineとOllamaの同一コンテナ化

最初は同一コンテナに配置する。

理由:

* localhost通信だけで済む
* Podman networkingの複雑性が少ない
* Cline → Ollama間の通信経路が明確
* 外部network禁止（`--network=none`）下でも、コンテナ内部のloopback (`127.0.0.1`) は完全に有効なため、localhost通信がそのまま動作する

構成:

```text
container
│
├── Cline CLI
│
├── Ollama server
│
├── SmolLM 135M
│
└── /workspace
```

Ollamaはコンテナ内部の

```text
127.0.0.1:11434
```

でlistenする。

Clineからlocalhostで接続する。

---

# 16. Phase 9 — Ollama serverの起動管理とプロセス管理

Cline起動前にOllama serverが起動している必要がある。

entrypointでの順序:

```text
start Ollama (background)
    ↓
wait until Ollama API ready (health check)
    ↓
start Cline CLI
```

単純なsleepではなく、health checkを使用する。

```bash
until curl -s http://127.0.0.1:11434/api/tags > /dev/null; do
  sleep 1
done
```

等でOllama APIが利用可能になるまで待つ。

### プロセス管理設計（tini / supervisord の扱い）

同一コンテナ内で複数プロセス（バックグラウンドのOllamaデーモンとフォアグラウンドのCline CLI）を実行する場合、PID 1問題（ゾンビプロセスの回収漏れ）やシグナル伝播（コンテナ停止時のSIGTERM処理）、Ollamaクラッシュ時の監視が課題となる。

* **対応方針**:
  * PID 1対策として、必要に応じて軽量initシステムである `tini`（Podmanの `--init` フラグまたはContainerfileへのtini導入）や supervisord の利用を検討する。
  * **優先度**: **正常に隔離環境で疎通させることを第一優先とするため、準正常系の対応（クラッシュ監視や高度なシグナル伝播など）は初期フェーズでは優先度が低い**。まずはシンプルな entrypoint シェルスクリプトで確実に起動・疎通できることを確認し、安定化フェーズで段階的に堅牢化を行う。

---

# 17. Phase 10 — workspace mount

ホスト側の専用sandbox workspaceのみをコンテナへmountする。

例:

```text
~/cline-sandbox/workspace
```

を、

```text
/workspace
```

へmountする。

それ以外のホストfilesystemをmountしない。

禁止:

```text
-v /:/host
-v $HOME:/home/user
-v ~/.ssh:/root/.ssh
-v ~/.aws:/root/.aws
```

など。

特に以下を絶対にsandboxへ渡さない。

* SSH private key
* AWS credentials
* GitHub credentials
* cloud credentials
* browser credentials
* shell history
* password store
* personal configuration

---

# 18. Phase 11 — ネットワーク完全遮断

最終sandboxでは外部networkを禁止する。

第一候補:

```bash
podman run --network=none ...
```

この状態でClineとOllamaが同一コンテナ内で動作することを確認する。

重要:

Ollamaがlocalhostで動作するため、

```text
Cline → 127.0.0.1:11434
```

は可能である。

一方、

```text
Cline → 8.8.8.8
Cline → github.com
Cline → google.com
Cline → 任意の外部API
```

は失敗することを確認する。

---

# 19. Phase 12 — ネットワーク隔離テスト

sandbox内部から以下をテストする。

DNS:

```bash
getent hosts github.com
```

HTTP:

```bash
curl -I https://github.com
```

HTTPS:

```bash
curl https://example.com
```

IP直接接続:

```bash
curl http://1.1.1.1
```

ping:

```bash
ping -c 1 8.8.8.8
```

結果は「通信できないこと」が成功条件。

ただしpingだけではネットワーク遮断を証明できないため、HTTP/HTTPS/IP/DNSを複数確認する。

---

# 20. Phase 13 — Ollamaだけは動作することを確認

network none状態で、

```bash
curl http://127.0.0.1:11434/api/tags
```

が成功することを確認する。

つまり、

```text
localhost       OK
Internet        NG
LAN             NG
```

となることを確認する。

---

# 21. Phase 14 — Cline filesystem sandbox確認

Clineに以下を依頼する。

### Test 1

```text
/workspace/test.txtを作成してください。
```

期待:

```text
成功
```

### Test 2

```text
/workspace/test.txtを読み取ってください。
```

期待:

```text
成功
```

### Test 3

```text
/workspace/test.txtを変更してください。
```

期待:

```text
成功
```

---

# 22. ホストアクセス試験

Clineにsandbox外のファイルを読み取らせるテストを行う。

例:

```text
/etc/passwdを読んでください。
```

`/etc/passwd`自体はコンテナ内部のファイルなので、単純にアクセスできることは必ずしも問題ではない。

重要なのはホストのfilesystemが見えていないこと。

例えばホスト側に、

```text
~/cline-secret-test/secret.txt
```

を作る。

そのディレクトリをmountしない状態で、

```text
/workspace/../...
```

等を利用してアクセスできないことを確認する。

---

# 23. Secret isolation test

ホスト側にテスト用の秘密情報を置く。

例:

```text
~/cline-secret-test/secret.txt
```

内容:

```text
THIS_MUST_NOT_BE_VISIBLE_TO_CLINE
```

このディレクトリをmountしない。

Clineからアクセスできないことを確認する。

さらに、

```bash
env
```

でhost credentialsが渡っていないことを確認する。

特に以下を確認:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
GITHUB_TOKEN
GH_TOKEN
ANTHROPIC_API_KEY
OPENAI_API_KEY
GOOGLE_API_KEY
```

これらをsandboxへ渡さない。

---

# 24. Capability削減

基本構成が動作した後で、Linux capabilitiesを削減する。

候補:

```text
--cap-drop=ALL
```

から開始し、必要なcapabilityだけ追加する。

ただし、最初からこれを適用すると問題原因の切り分けが難しくなるため、基本構成の後に実施する。

---

# 25. Privileged禁止

絶対に、

```bash
--privileged
```

を使用しない。

また、

```text
/dev
/sys
/proc
```

などのhost device/filesystemを不用意にmountしない。

---

# 26. Rootless Podman

可能ならrootless Podmanを使用する。

確認:

```bash
podman info --format '{{.Host.Security.Rootless}}'
```

rootlessであることを確認する。

rootful Podmanが必要になる場合は、なぜ必要なのかをPLAN/READMEに記録する。

---

# 27. SELinux

本計画では、ホスト環境の実機設定に基づき **SELinux: Disabled を前提とする**。

```bash
getenforce
# -> Disabled
```

SELinuxがDisabledであるため、コンテナ起動時のボリュームマウントで `:Z` や `:z` の指定、およびSELinuxポリシー違反に起因する権限エラーの対処は当面考慮不要とする。

※将来的にSELinuxがEnforcingの環境へ移植・展開する場合には、workspace mount時に適切なコンテキストフラグ（`:z` / `:Z`）を付与し、audit logを監視して最小権限設定を行う。

---

# 28. CPU / メモリ制限

sandboxがホスト資源を無制限に使用しないよう、必要に応じてPodman resource limitsを設定する。

候補:

```text
--cpus
--memory
--pids-limit
```

SmolLM 135Mは極めて軽量（~270MB）でCPU負荷も低いため、最初から過度な制限はかけず、まず正常動作を確認した後に必要に応じてresource limitを追加する。

---

# 29. Process isolation

Clineが異常なプロセスを大量生成した場合に備える。

必要に応じて:

```text
--pids-limit
```

を設定する。

また、Clineから不要なsystem serviceを操作できないことを確認する。

---

# 30. Read-only filesystem

基本動作確認後、container root filesystemをread-onlyにする構成を検討する。

例:

```text
--read-only
```

ただしCline、Ollama、npm、temporary files等が書き込みを必要とする可能性がある。

そのため、

```text
root filesystem = read-only

/tmp             = writable tmpfs
Ollama data      = writable volume
workspace        = writable mount
必要なcache      = writable volume
```

のような構成を検討する。

これはPhase後半で実施する。

---

# 31. Ollama model storage

Ollamaモデルをcontainer imageに含める方式を最終候補とする。

ただし、開発中はvolume方式が便利。

例:

```text
cline-ollama-models
```

というPodman volumeを作り、

```text
/root/.ollama
```

等のOllama model directoryを永続化する。

最終的に、

```text
Option A:
container image + model included

Option B:
container image + local Podman volume
```

を比較する。

再現性を優先する場合はA、開発効率を優先する場合はB。

---

# 32. 完全offline起動テスト

最終構成では、ホストからも外部通信を行わずに起動できることを確認する。

理想状態:

```text
1. Podman image exists locally
2. Model exists locally
3. Network disabled
4. Start container
5. Start Ollama
6. Start Cline
7. Cline performs file operation
```

この一連の処理が成功すること。

---

# 33. 最終テストシナリオ

## Test A — Cline起動

```text
Cline CLIが起動する
```

Expected:

PASS

---

## Test B — Ollama

```text
Cline → localhost:11434 → Ollama
```

Expected:

PASS

---

## Test C — Model

```text
Ollama → SmolLM 135M
```

Expected:

PASS

---

## Test D — Connectivity / Response

```text
Cline → Ollama → SmolLM 135M → Cline Response
```

（※tool calling は初期ステップでは検証対象外とし、プロンプトに対する応答の正常受信を確認）

Expected:

PASS

---

## Test E — Workspace mount test

```text
Host workspace ↔ Container /workspace mount read/write
```

Expected:

PASS

---

## Test F — Internet

```text
Cline → https://example.com
```

Expected:

FAIL

---

## Test G — GitHub

```text
Cline → https://github.com
```

Expected:

FAIL

---

## Test H — DNS

```text
Cline → DNS lookup
```

Expected:

FAIL

またはnetwork noneによって名前解決不能。

---

## Test I — Host filesystem

```text
Cline → host secret
```

Expected:

FAIL

---

## Test J — Host credentials

```text
Cline → AWS/GitHub/etc credentials
```

Expected:

NOT AVAILABLE

---

# 34. セキュリティ上の重要事項

このsandboxは「Clineからの意図しない外部通信を防ぐ」ことを目的とする。

ただし、コンテナはVMと同じ完全なセキュリティ境界ではない。

そのため、以下を行わない。

* `--privileged`
* host root filesystem mount
* host `/run` mount
* Docker/Podman socket mount
* SSH private key mount
* cloud credential mount
* browser credential mount
* unnecessary device mount

特に、

```text
/var/run/docker.sock
```

やPodman socketをコンテナに渡さない。

これらを渡すとsandboxからhost/container runtimeを操作できる可能性があり、隔離の意味が大きく低下する。

---

# 35. Docker/Podman socket禁止

以下を禁止する。

```text
-v /var/run/docker.sock:/var/run/docker.sock
-v $XDG_RUNTIME_DIR/podman/podman.sock:...
```

Cline sandbox内からcontainer runtimeを操作できる状態を作らない。

---

# 36. Git利用

ClineのworkspaceがGit repositoryの場合、Git自体はコンテナ内で使用可能にする。

ただしnetworkを禁止するため、

```text
git clone https://...
git fetch
git push
```

などは失敗する。

これは意図した動作。

ホスト側でrepositoryを準備し、

```text
Host repository
       ↓ mount
/workspace
       ↓
Cline
```

とする。

---

# 37. Clineによるshell command実行

Clineがshell commandを実行できることを確認する。

ただし最初は安全なコマンドのみ。

例:

```bash
pwd
ls
cat
echo
python --version
```

その後、

```bash
curl
wget
ssh
git
```

などのネットワーク関連コマンドが実行されても、network isolationによって外部通信できないことを確認する。

---

# 38. 「ネットワーク禁止」と「コマンド禁止」を分離する

今回の重要な検証ポイント。

例えば、

```text
curlコマンドが存在する
```

こと自体は問題ではない。

重要なのは、

```text
curl https://example.com
```

が成功しないことである。

したがって、

```text
Command availability
```

と、

```text
Network capability
```

を別々に検証する。

---

# 39. モデル変更と将来のステップについて

初期フェーズでは `SmolLM 135M` を使用し、tool callingは検証対象外としてClineとOllamaの疎通およびPodman sandbox隔離の確認に専念する。

初期フェーズの疎通・隔離が完了した後、次のステップとしてtool callingやコーディングエージェントループを検証したい場合は、以下の順序で慎重に進める：

1. まずOllama単体でtool calling対応モデル（例: `qwen2.5-coder:1.5b` や `qwen2.5-coder:7b`）のtool calling動作を確認する。
2. 次にCline + Ollamaでのtool calling連携を確認する。
3. モデル変更とsandbox設計（ネットワーク遮断やマウント設定）の変更を同時に行わないこと。

---

# 40. ログ収集

最低限以下のログを取得できるようにする。

```text
Cline log
Ollama log
container stdout/stderr
Podman inspect
```

必要に応じて、

```bash
podman logs <container>
```

で確認できるようにする。

---

# 41. 再現性

最終的には以下をGit repositoryで管理する。

```text
cline-podman-sandbox/
├── PLAN.md
├── README.md
├── Containerfile
├── .containerignore
├── scripts/
│   ├── build.sh
│   ├── run.sh
│   ├── test-network.sh
│   ├── test-filesystem.sh
│   └── test-sandbox.sh
└── ...
```

秘密情報はrepositoryに保存しない。

---

# 42. READMEに記載する内容

READMEには以下を記載する。

* 対象OS
* 必要なCPU/RAM/disk
* Podman version
* Cline CLI version
* Ollama version
* Model name/version (SmolLM 135M)
* build方法
* model準備方法
* 起動方法
* workspace指定方法
* network isolation方法
* test方法
* security limitations
* known issues

---

# 43. 完了条件

以下をすべて満たしたら初期版完成とする。

## Environment

* [x] Linux (x86_64) 環境で動作確認済み
* [x] rootless Podman (v5.8.2) で動作確認済み
* [x] GPU不要（CPUのみで完全動作）
* [x] SELinux: Disabled前提で動作確認済み

## LLM

* [x] Ollama (v0.34.2) がコンテナ内で正常動作
* [x] SmolLM 135M がCPUで動作（イメージ焼き込み済み、完全オフライン推論確認済み）
* [x] Ollama API が localhost (127.0.0.1:11434) で利用可能

## Cline

* [x] Cline CLI (v3.0.64) がコンテナ内で起動
* [x] Cline から Ollama (SmolLM 135M) を利用可能（設定初期化およびAPI疎通確認済み）
* [] tool calling / agent loop (初期ステップでは検証対象外）

## Filesystem

* [x] `/workspace` のみ作業対象としてmount
* [x] host secret へアクセスできない（動的一時シークレットを用いた非アクセス検証PASS）
* [x] host home directory 全体をmountしていない
* [x] SSH/AWS/GitHub credential を渡していない（環境変数漏洩チェックPASS）

## Network

* [x] Internet access 不可（HTTP/HTTPS遮断PASS）
* [x] GitHub access 不可（PASS）
* [x] DNS access 不可（名前解決遮断PASS）
* [x] 任意の外部HTTP/HTTPS 不可（PASS）
* [x] localhost Ollama のみ利用可能（127.0.0.1:11434 疎通PASS）

## Container security

* [x] `--privileged` を使用していない（非特権 rootless 実行）
* [x] Docker/Podman socket をmountしていない（ソケット非マウント確認PASS）
* [x] host root filesystem をmountしていない
* [x] 不要なLinux capabilitiesを削減している（rootless Podmanデフォルト最小特権）

## Reproducibility

* [x] Containerfile を保存 (`sandbox/Containerfile`)
* [x] 起動スクリプトを保存 (`scripts/run.sh`)
* [x] test script を保存 (`scripts/test-sandbox.sh`, `scripts/test-network.sh`, `scripts/test-filesystem.sh`)
* [x] README を作成 (`README.md`)
* [x] 使用バージョンを記録（Node 22, Cline 3.0.64, Ollama 0.34.2, Podman 5.8.2）

---

# 44. 実装時のAIエージェントへの指示

このPLANを実装するAIエージェントは、以下の原則を守る。

1. まずPhase 0の環境調査・Podman導入を行う。
2. 調査結果を提示してから実装方針を確定する。
3. 一度に大量の変更を行わない。
4. 各Phase終了時に動作確認する。
5. 問題が発生したら、最後に変更した部分を優先して切り分ける。
6. 現在のCline CLI/Ollama/Podmanの仕様を公式情報で確認する。
7. 古い記事のコマンドをそのまま使用しない。
8. rootless Podmanを第一候補とする。
9. `--privileged`を使用しない。
10. host filesystemを不用意にmountしない。
11. credentialsをcontainerへ渡さない。
12. network isolationを必ず実測する。
13. 「ネットワークを設定したから安全」と判断せず、curl等による実通信テストを行う。
14. SmolLM 135Mを使用し、tool callingは初期ステップ検証対象外とすることを厳守する（モデルの推論能力不足とsandbox実装の問題を混同しない）。
15. 正常に隔離環境で疎通させることを最優先とし、準正常系の作り込みを優先しない。
16. 問題が解決しない場合、勝手に大幅な設計変更をせず、原因と代替案を報告する。

---

# 45. 最終的な成功状態

最終的に、以下の状態を実現する。

```text
                 Oracle Linux Host
                       │
                       │
                 Podman rootless
                       │
                       ▼
        ┌──────────────────────────┐
        │     Cline Sandbox        │
        │                          │
        │  Cline CLI               │
        │      │                   │
        │      │ localhost         │
        │      ▼                   │
        │  Ollama                  │
        │      │                   │
        │      ▼                   │
        │  SmolLM 135M             │
        │                          │
        │ /workspace               │
        └──────────┬───────────────┘
                   │
                   │ read/write
                   ▼
             Host workspace

Network:
    Container → localhost       ALLOW
    Container → Internet        DENY
    Container → LAN             DENY
    Container → Host services   DENY
```

この状態でClineに、

```bash
cline "Hello from sandbox test" --auto-approve true
```

と投入し、

```text
Cline request
       ↓ localhost:11434
Ollama inference (SmolLM 135M)
       ↓
Cline response display & completion
```

までエラーなく疎通できることを確認する。

同時に、Clineが意図的または偶発的に、

```text
Internet
GitHub
AWS
SSH
Host filesystem
Host credentials
```

へアクセスできないことを確認する。

これを本プロジェクトの初期完成条件とする。
