# Cline CLI + Ollama Podman Sandbox 構築計画

## 1. 目的

Oracle Linux / x86_64 のオンプレミスLinux環境上に、AIコーディングエージェントである Cline CLI をPodmanコンテナ内に隔離して実行する環境を構築する。

LLMバックエンドには Ollama を使用し、CPUのみで動作する小型のtool-calling対応モデルを使用する。

初期モデルは `FunctionGemma 270M` を第一候補とする。

最終的な構成では、Cline CLI、Ollama、LLMを同一のPodmanサンドボックス内に配置し、Clineから外部ネットワークへアクセスできない状態を実現する。

主目的は高性能なコーディング環境の構築ではなく、

* Cline CLIの動作確認
* Ollamaとの連携確認
* tool calling / agent loopの確認
* Podmanによるファイルシステム隔離
* Podmanによるネットワーク隔離
* 外部ネットワークへの情報流出防止
* ホストOSへのアクセス範囲の制限

を検証することである。

---

# 2. 前提環境

## 2.1 ホスト

対象:

* Oracle Linux
* x86_64
* CPUのみ
* NVIDIA GPU等は使用しない
* Podmanを使用する
* rootless Podmanを第一候補とする

Oracle Linuxの具体的なバージョンは実機上で確認する。

最初に以下を確認すること。

```bash
cat /etc/os-release
uname -m
uname -r
id
podman --version
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
        │   └── FunctionGemma 270M
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

1. ホスト環境確認
2. Podman動作確認
3. Cline CLI単体確認
4. Ollama単体確認
5. FunctionGemma 270M確認
6. Cline → Ollama確認
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
FunctionGemma 270M
```

理由:

* 非常に小型
* CPUで動作させやすい
* function/tool calling用途を想定したモデル
* 今回はLLMの性能検証ではなくsandbox/tool executionの検証が目的

ただし、270Mモデルなので高度なコーディングエージェントとしての能力は期待しない。

目的は、

```text
Cline
  ↓
LLM
  ↓
tool call
  ↓
file operation / command
```

というagent loopの確認である。

---

# 6. モデルの代替候補

FunctionGemma 270MでClineのagent loopを正常に成立させることが難しい場合、以下を候補とする。

優先順位:

1. FunctionGemma 270M
2. Qwen2.5 0.5B
3. Qwen2.5 1.5B
4. その他、Ollamaでtool callingに対応するCPU向け小型モデル

モデル変更は、FunctionGemmaが「小さすぎる」ことによる問題と、Podman/Cline/Ollamaの構成問題を混同しないよう、Phaseごとに判断する。

---

# 7. Phase 0 — ホスト環境調査

まずOracle Linux環境を調査する。

確認項目:

```bash
cat /etc/os-release
uname -a
uname -m
lscpu
free -h
df -h
podman --version
```

さらに以下を確認する。

```bash
command -v podman
command -v curl
command -v git
command -v node
command -v npm
command -v ollama
```

確認したい事項:

* Oracle Linuxのバージョン
* CPU architecture
* CPU core数
* RAM容量
* disk空き容量
* Podmanのバージョン
* Node.js/npmの有無
* SELinuxの状態
* rootless containerが利用可能か

SELinux:

```bash
getenforce
```

rootless Podman:

```bash
podman info
```

を確認する。

---

# 8. Phase 1 — Podman基本動作確認

まず単純なコンテナを起動する。

例:

```bash
podman run --rm docker.io/library/alpine:latest uname -a
```

ただし、この段階では外部registryからイメージを取得する必要がある。

ネットワークアクセス可能な準備段階と、最終的なsandbox実行段階を明確に分離する。

確認:

```bash
podman run --rm alpine:latest echo "podman works"
```

成功条件:

* Podmanでコンテナを起動できる
* rootlessで問題なく動作する
* SELinuxによる問題が発生していない

---

# 9. Phase 2 — Cline CLIの導入方法を確定

Cline CLIの現在の公式インストール方法を調査する。

重要:

古いブログ記事や過去バージョンのインストール手順を盲目的に使用しない。

実行時点で利用可能な公式ドキュメント、公式GitHubリポジトリ、npm等を確認する。

確認項目:

* Cline CLIの正式なパッケージ名
* 推奨Node.jsバージョン
* CLI起動コマンド
* Ollama backendの設定方法
* OpenAI-compatible APIが必要か
* Ollama native APIを使用できるか
* tool calling対応状況
* 非対話モード / CLIモードの有無

この結果を実装に反映する。

---

# 10. Phase 3 — Ollama導入

Ollamaをインストールする。

ホストに恒久インストールするのではなく、最終的にはsandboxコンテナ内で動作させる。

まずは一時的にホスト側またはテスト用コンテナでOllamaの動作を確認してもよい。

確認:

```bash
ollama --version
```

Ollama serverを起動し、

```text
127.0.0.1:11434
```

でAPIにアクセスできることを確認する。

---

# 11. Phase 4 — FunctionGemma 270M確認

FunctionGemma 270Mを取得する。

例:

```bash
ollama pull functiongemma:270m
```

実際のタグ名は、実行時点のOllama registryを確認して確定する。

モデル一覧:

```bash
ollama list
```

単純な推論:

```bash
ollama run functiongemma:270m
```

を実行する。

---

# 12. Phase 5 — Ollama tool calling確認

Clineを入れる前に、Ollama単体でtool callingが成立することを確認する。

Ollama APIの現在のtool calling仕様を確認する。

必要であればPython等の簡単なテストプログラムを作る。

テストtool例:

```text
read_file(path)
write_file(path, content)
run_command(command)
```

ただし実際には安全なダミーtoolを使用する。

例:

```text
get_time()
echo(value)
```

最初からshell commandをtoolとしてLLMに渡さない。

成功条件:

```text
prompt
  ↓
FunctionGemma
  ↓
tool call JSON / API tool call
  ↓
test application
  ↓
tool result
  ↓
LLM response
```

が成立すること。

---

# 13. Phase 6 — Cline + Ollama

Cline CLIを起動し、Ollamaをbackendとして設定する。

重要:

ClineがFunctionGemma 270Mを実際にagent modelとして利用できるか確認する。

確認項目:

* モデル名設定
* Ollama API endpoint
* context length
* tool calling
* streaming
* CLIの認証要求
* timeout
* model response format

最初のテストは極小にする。

例:

```text
workspace内にhello.txtを作成してください。
内容はhello worldだけにしてください。
```

成功条件:

1. ClineがLLMにpromptを送る
2. LLMがtool callを生成する
3. Clineがtool callを実行する
4. ファイルが生成される
5. Clineが結果を認識する

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
* Node.js
* Cline CLI
* Ollama
* 必要なruntime dependencies

モデルについては、以下の2方式を比較する。

###方式A: コンテナ起動後にpull

```text
container
  ↓
ollama pull
```

利点:

* imageが小さい

欠点:

* 初回起動時にnetworkが必要
* 完全offline実行ができない

###方式B: モデルをimageに含める

```text
Container Image
├── Cline
├── Ollama
└── FunctionGemma
```

利点:

* 起動後完全offline可能
* 再現性が高い

欠点:

* imageサイズが大きくなる

今回の最終目標は方式B。

ただし、まず方式Aで動作確認し、その後方式Bに移行する。

---

# 15. Phase 8 — ClineとOllamaの同一コンテナ化

最初は同一コンテナに配置する。

理由:

* localhost通信だけで済む
* Podman networkingの複雑性が少ない
* Cline → Ollama間の通信経路が明確
* 外部network禁止が簡単

構成:

```text
container
│
├── Cline CLI
│
├── Ollama server
│
├── FunctionGemma
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

# 16. Phase 9 — Ollama serverの起動管理

Cline起動前にOllama serverが起動している必要がある。

entrypointで、

```text
start Ollama
    ↓
wait until Ollama API ready
    ↓
start Cline CLI
```

という順序にする。

単純なsleepではなく、health checkを使用する。

例えば、

```bash
curl http://127.0.0.1:11434/api/tags
```

等でOllama APIが利用可能になるまで待つ。

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

Oracle LinuxではSELinuxを考慮する。

状態:

```bash
getenforce
```

SELinuxがEnforcingの場合、workspace mount時のlabelを適切に設定する。

必要に応じて、

```bash
:Z
```

または

```bash
:z
```

を利用する。

ただし、安易にSELinuxを無効化しない。

禁止:

```bash
setenforce 0
```

を恒久的な解決策として使用すること。

SELinux関連エラーが発生した場合は、audit log等を調査して必要最小限の対応を行う。

---

# 28. CPU / メモリ制限

sandboxがホスト資源を無制限に使用しないよう、必要に応じてPodman resource limitsを設定する。

候補:

```text
--cpus
--memory
--pids-limit
```

ただしFunctionGemma 270MはCPUのみで動作させるため、最初から厳しい制限を設定しない。

まず正常動作させ、その後resource limitを追加する。

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
Ollama → FunctionGemma 270M
```

Expected:

PASS

---

## Test D — Tool call

```text
Cline → LLM → tool call → Cline → tool execution
```

Expected:

PASS

---

## Test E — File write

```text
Cline → /workspace/test.txt
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

# 39. モデルが弱すぎる場合

FunctionGemma 270MでClineが正常にtool callを行えない場合、すぐにsandbox設計を変更しない。

まず、

```text
Ollama単体
    ↓
tool calling
```

を再確認する。

次に、

```text
Cline + Ollama
```

を再確認する。

それでもagent loopが成立しない場合のみ、

```text
Qwen2.5 0.5B
```

等へ変更する。

モデルサイズを大きくすることと、sandbox実装を変更することを同時に行わない。

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
* Model name/version
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

* [ ] Oracle Linux / x86_64で動作
* [ ] rootless Podmanで動作
* [ ] GPU不要

## LLM

* [ ] Ollamaがコンテナ内で動作
* [ ] FunctionGemma 270MがCPUで動作
* [ ] Ollama APIがlocalhostで利用可能

## Cline

* [ ] Cline CLIがコンテナ内で起動
* [ ] ClineからOllamaを利用可能
* [ ] tool callingが成立
* [ ] shell/file toolが実行可能

## Filesystem

* [ ] `/workspace`のみ作業対象としてmount
* [ ] host secretへアクセスできない
* [ ] host home directory全体をmountしていない
* [ ] SSH/AWS/GitHub credentialを渡していない

## Network

* [ ] Internet access不可
* [ ] GitHub access不可
* [ ] DNS access不可
* [ ] 任意の外部HTTP/HTTPS不可
* [ ] localhost Ollamaのみ利用可能

## Container security

* [ ] `--privileged`を使用していない
* [ ] Docker/Podman socketをmountしていない
* [ ] host root filesystemをmountしていない
* [ ] 不要なLinux capabilitiesを削減している
* [ ] SELinuxを無効化していない

## Reproducibility

* [ ] Containerfileを保存
* [ ] 起動スクリプトを保存
* [ ] test scriptを保存
* [ ] READMEを作成
* [ ] 使用バージョンを記録

---

# 44. 実装時のAIエージェントへの指示

このPLANを実装するAIエージェントは、以下の原則を守る。

1. まずPhase 0の環境調査を行う。
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
14. FunctionGemma 270Mの能力不足とsandbox実装の問題を分離して調査する。
15. 問題が解決しない場合、勝手に大幅な設計変更をせず、原因と代替案を報告する。

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
        │ FunctionGemma 270M       │
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

```text
リポジトリを調査し、必要なファイルを変更してください。
```

と指示し、

```text
LLM inference
       ↓
tool call
       ↓
Cline execution
       ↓
workspace modification
```

まで実行できることを確認する。

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
