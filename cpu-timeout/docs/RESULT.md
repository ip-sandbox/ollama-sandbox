# Cline + gemma4 CPU 推論タイムアウト 調査結果

対象: Cline CLI 3.0.64 / Ollama 0.34.2 / `gemma4:12b-it-qat` / CPU（Ryzen 5 PRO 4650G, 4 コア, AVX2, RAM 30GB）

---

## 段階1: タイムアウト箇所の切り分け（実モデル不使用）

### 結論

**300 秒の壁は 2 層ある。片方だけ直しても 300 秒で切れる。**

| # | 層 | 既定 | 症状（エラー文言） | 対策 |
|---|---|---|---|---|
| ① | **Bun の `fetch` 既定タイムアウト**（cline は Bun 1.3.13 でコンパイルされた単一バイナリ） | 300 秒 | `error: The operation timed out.` | preload `bun-fetch-no-timeout.js` を `BUN_OPTIONS` で読み込み、Ollama 宛て fetch にだけ `timeout: false` を付ける |
| ② | **Cline の Ollama プロバイダの AbortController** | 300 秒（`OLLAMA_DEFAULT_TIMEOUT_MS`） | `error: Ollama request timed out after 300 seconds` | `providers.json` の `providers.ollama.settings.timeout`（ms）。`set-timeout.sh` で設定 |

- 実際に最初に当たるのは ① のほう。**CPU 推論で出ていた `The operation timed out.` は Bun 由来**。
- ① は Cline 側に設定項目が無い。Ollama プロバイダは `fetch: withOllamaResponseTimeout(fetch, timeoutMs)` で fetch を包むだけで、Bun 独自の `timeout: false` を渡していない。
- ① はヘッダを先に返しても回避できない。本文が 300 秒無音だと、やはり切られる（`headers` モードで確認）。Ollama 側の工夫では回避できない。
- ② は 3.0.64 で設定可能。`providers.json` のスキーマに `timeout: int positive`（ms）があり、`timeoutMs: settings.timeout` として AbortController に渡る。**バイナリパッチは不要**。
- 未追跡の WIP `sandbox/workspace/33_patch_cline_timeout.sh`（参考 repo 由来）は `node_modules/**/*.js` の定数を書き換えるもの。3.0.64 が実行するのはコンパイル済みの `bin/.cline` なので、**効かない**。仮に効いても ② しか直らない。

### 実測: 遅延スタブに対する Cline CLI（`probe-timeout.sh`）

`slow_ollama_stub.py` を 127.0.0.1:11434 で動かす。最初の `/api/chat` だけ、指定秒数無音にしてから応答する。「切断」はスタブ側がソケットの切断を検知した時刻。

| timeout 設定 | preload | 上流 | 経過 | exit | 切断 | 結果 |
|---|---|---|---:|---:|---:|---|
| なし | – | 5s | 9s | 0 | – | 完走 |
| なし | – | 340s 無音 | 302s | 1 | 298.9s | `The operation timed out.` |
| 1800000 | – | 400s 無音 | 303s | 1 | 299.4s | `The operation timed out.` ← ②を直しても①で切れる |
| 1800000 | – | 700s 無音 | 302s | 1 | 299.0s | `The operation timed out.` |
| 1800000 | – | ヘッダ即・本文 700s | 303s | 1 | 299.4s | `The operation timed out.` ← ヘッダ先出しは無効 |
| 1800000 | – | 1200s 無音 | 302s | 1 | 298.8s | `The operation timed out.` |
| なし | ✔ | 400s 無音 | 304s | 1 | 300.0s | `Ollama request timed out after 300 seconds` ← ①を外すと②が出る |
| 1800000 | ✔ | 400s 無音 | 404s | 0 | – | **完走** |
| 600000 | ✔ | 700s 無音 | 603s | 1 | 600.3s | `Ollama request timed out after 600 seconds` ← settings.timeout が効いている |
| 1800000 | ✔ | ヘッダ即・本文 700s | 704s | 0 | – | **完走** |
| 1800000 | ✔ | 1200s 無音 | 1204s | 0 | – | **完走**（20 分無音でも OK） |

生データ: `.state/probe/results.tsv`、各ケースの `run.log` / `stub.jsonl` / `providers.json`

### 実測: Bun の fetch 単体（`bun_fetch_probe.js`）

cline バイナリは `BUN_BE_BUN=1` で埋め込みの Bun（1.3.13）として動く。これで fetch 単体を測った。

| 上流 | 既定 | `timeout: false` |
|---|---|---|
| 400s 無音 | 300.0s で `TimeoutError: The operation timed out.` | 400.5s で完走 |
| ヘッダ即・本文 400s | 300.0s で `TimeoutError` | – |

### preload がコンパイル済みバイナリに効くことの確認

Bun は `BUN_OPTIONS` 環境変数を CLI 引数として読む。これはコンパイル済みの単一バイナリでも同じ。
`BUN_OPTIONS="--preload .../bun-fetch-no-timeout.js" cline ...` で、`[bun-fetch-no-timeout] pid=...` が出力されることを確認した。
ホストでは cline が 1 プロセスで LLM を呼ぶ。コンテナ内の対話利用では `--cline-hub-daemon` プロセスが立つことがある（稼働中コンテナで確認）。**daemon にも効かせるには、コンテナ起動時の環境変数として渡す必要がある**（`podman run -e BUN_OPTIONS=...`）。後から shell で export しても、既に起動している daemon には効かない。

### その他の確認事項

- **Cline のプロンプトサイズ**: 1 回目の `/api/chat` は system 4,321 文字 + tools 25 個のスキーマ 18,151 文字。概算で 5,600 トークン（`team_*` 系のツール定義が大半）。正確なトークン数は段階2で `prompt_eval_count` を見る。
- **num_ctx**: Cline はリクエストに `options.num_ctx = 32768` を自分で付けている。Ollama の CPU 時の既定 4k による切り詰めは、Cline 経由では起きない。
- **`OLLAMA_LOAD_TIMEOUT`**（既定 5m）: `ollama serve --help` の説明は「モデルロードが **停滞** してから諦めるまでの時間」。prefill や推論の時間には効かないので、上の 300 秒とは無関係。ただしロードが遅い CPU 機では停滞判定に当たりうる。既存 entrypoint と同じく 30m を維持し、段階2でロード時間を実測する。
- **`OLLAMA_KEEP_ALIVE`**（既定 5m）: ターン間が 5 分空くとモデルがアンロードされ、再ロードと KV キャッシュ喪失が起きる。CPU では 1 ターン自体が 5 分を超えうるので、`-1`（常駐）を推奨。段階2で使う。

### 必要な設定（段階1時点）

```bash
# ① Bun fetch の 300 秒を外す（Ollama 宛てだけ）
export BUN_OPTIONS="--preload /path/to/cpu-timeout/bun-fetch-no-timeout.js"
# ② Cline の Ollama タイムアウトを 30 分に
bash cpu-timeout/set-timeout.sh --timeout-ms 1800000      # ~/.cline/data/settings/providers.json
# 実行時は必ずプロバイダを明示（既定はクラウドの cline プロバイダ）
cline -P ollama -m gemma4:12b-it-qat ...
```

---

## 段階2: 実モデル E2E

### 結論

**対策 ①+② で、gemma4:12b-it-qat の CPU 推論による Cline 実タスクが完走した。ホストでもコンテナでも同じ。**
対策なしでは、同じ条件で 300 秒で切れることも実モデルで再現した。

### 実モデルの速度（`bench_prefill.py`）

段階1でスタブが保存した Cline の実リクエスト（system + tools 25 個）を、本物の Ollama に直接投げて測った。

| 回 | 状態 | 全体 | ロード | prompt | prefill | 生成 |
|---|---|---:|---:|---:|---:|---:|
| 1 | cold（ロード + 全 prefill） | **612.1s** | 39.5s | 4,450 tok | 554.0s（**8.0 tok/s**） | 55 tok / 18.6s（3.0 tok/s） |
| 2 | 同一プロンプト（prompt cache） | 10.4s | 0s | 4,450 tok | 2.5s（キャッシュ命中） | 23 tok / 7.8s（2.9 tok/s） |

- Cline の 1 ターン目は **prefill だけで 9 分強**かかる。300 秒では原理的に間に合わない。
- 2 ターン目以降は、Ollama（llama.cpp）の prompt cache が効いて差分だけを prefill する。ただし `OLLAMA_KEEP_ALIVE` でモデルを常駐させておくことが前提。
- ロードは 39.5 秒。`OLLAMA_LOAD_TIMEOUT`（既定 5m の停滞判定）には程遠い。この機械では問題にならないが、既存 entrypoint の 30m 設定はそのままで害は無い。
- 1 ターン目の所要時間の見積りは、ロード 40s + prefill 554s + 出力 1024 トークン 346s ≒ 940 秒。30 分（1800000 ms）の設定なら 2 倍近い余裕がある。

### E2E（`run-e2e.sh`、ホスト、毎回 ollama を再起動して cold から開始）

タスク（標準入力で英語）: `hello.txt` を作り、中身を `hello from gemma4 on cpu` にする。`--thinking none`。

| 条件 | 経過 | exit | /api/chat | 結果 |
|---|---:|---:|---|---|
| **対策なし** | 342s | 1 | 1 回（Ollama 側 500 / 5m9s で中断） | `Ollama request timed out after 300 seconds`、ファイル無し |
| **対策あり**（preload + timeout 1800000） | **680s** | **0** | 4 回: 9m0s / 32.8s / 47.5s / 54.9s | `hello.txt` = `hello from gemma4 on cpu`（完全一致） |

対策ありの Ollama ログ（llama.cpp の slot timing）:

| ターン | 新規に prefill したトークン | prefill 時間 | コンテキスト累計 | truncated |
|---|---:|---:|---:|---|
| 1 | 4,481 | 526.9s（8.5 tok/s） | 4,497 | 0 |
| 2 | 43 | 8.4s | 4,593 | 0 |
| 3 | 185 | 26.2s | 4,769 | 0 |
| 4 | 138 | 21.6s | 4,947 | 0 |

Cline の動き: `run_commands`（ls） → `editor`（作成） → `read_files`（確認） → 完了報告。

- 対策なしでの切断は、段階1のスタブでは Bun 側（`The operation timed out.`）、実モデルでは Cline 側（`Ollama request timed out after 300 seconds`）が先に出た。**両方ともほぼ 300 秒で発火するので、どちらの文言が出るかはタイミング次第**。どちらが出ても、①と②の両方を直す必要がある。

### コンテナ内 E2E（`container-e2e.sh`）

`scripts/launcher.py` の `launch()` と同じ `podman run`（`--network=none`、`ollama-models` volume）に、対策の `-e BUN_OPTIONS=...`、`-e OLLAMA_KEEP_ALIVE=-1`、preload のマウントだけを足した。コンテナ内で `set-timeout.sh` を実行してから cline を実行した。イメージ `cline-sandbox:v2` と既存ファイルは未変更。

| 条件 | 経過 | exit | /api/chat | 結果 |
|---|---:|---:|---|---|
| 対策あり（コンテナ内） | **595s** | **0** | 3 回: 8m54s / 17.9s / 34.0s | `hello.txt` = `hello from gemma4 on cpu.` |

- preload はコンテナ内の cline プロセスに読み込まれた（`[bun-fetch-no-timeout] pid=111`）。`providers.json` にも `timeout: 1800000` が入った。
- 1 ターン目は 4,443 トークンの prefill に 514.7s（8.6 tok/s）。2、3 ターン目は差分の 72 / 60 トークンだけを prefill した。`truncated = 0`。
- 出力の末尾に `.` が付いた。プロンプトの `...exactly the text: hello from gemma4 on cpu.` の文末ピリオドを、本文として解釈したもの。**タイムアウトとは無関係な、プロンプト文言の曖昧さ**（ホスト実行では付かなかった）。

### 推奨設定（最終）

| 項目 | 値 | 理由 |
|---|---|---|
| `BUN_OPTIONS` | `--preload <path>/bun-fetch-no-timeout.js` | ① Bun fetch の 300 秒を Ollama 宛てだけ外す。**コンテナは `podman run -e` で渡す**（hub daemon にも効かせるため） |
| `providers.json` の `providers.ollama.settings.timeout` | `1800000`（30 分） | ② Cline の 300 秒。1 ターン目の見積り約 940 秒に対して約 2 倍の余裕 |
| `OLLAMA_KEEP_ALIVE` | `-1` | 2 ターン目以降の prompt cache を活かす（無いと毎ターン 9 分） |
| `OLLAMA_LOAD_TIMEOUT` | `30m`（既存 entrypoint のまま） | ロード停滞の判定。実測ロードは 40 秒なので余裕 |
| `cline` の起動 | `-P ollama -m gemma4:12b-it-qat --thinking none`、プロンプトは **パイプ**で渡す | `< file` のリダイレクトだと `interactive mode requires a TTY` で落ちる |

### 既存環境へ取り込む場合（参考。今回は既存ファイルは未変更）

- `scripts/launcher.py` の `launch()` にある `podman run` に、次を追加する:
  - `-e BUN_OPTIONS=--preload /opt/cpu-timeout/bun-fetch-no-timeout.js`
  - `-e OLLAMA_KEEP_ALIVE=-1`
  - preload ファイルのマウント。または Containerfile で `COPY` する
- `sandbox/scripts/entrypoint.sh` は `~/.cline/settings.json` を書いているが、3.x はこのファイルを読まない。代わりに `set-timeout.sh` 相当の処理（`cline auth -p ollama` を実行し、`providers.json` の `settings.timeout` を設定）を入れる。
- 未追跡の `sandbox/workspace/33_patch_cline_timeout.sh` は 3.0.64 では効かないので不要。

### ファイル一覧（すべて `cpu-timeout/` に新規作成）

| ファイル | 役割 |
|---|---|
| `bun-fetch-no-timeout.js` | **対策①** Bun fetch の preload |
| `set-timeout.sh` | **対策②** providers.json の timeout 設定（ホストとコンテナの両方で動く。JSON の編集は node で行う） |
| `setup-host.sh` / `env.sh` | ホストに Node 22.23.3、cline 3.0.64、Ollama 0.34.2（イメージから CPU 用だけ取り出し）、uv の Python 3.12 venv を用意する |
| `slow_ollama_stub.py` / `probe-timeout.sh` / `bun_fetch_probe.js` | 段階1の切り分け（実モデル不要） |
| `ollama-host.sh` / `bench_prefill.py` / `run-e2e.sh` | 段階2のホスト E2E |
| `container-e2e.sh` | 段階2のコンテナ E2E（launcher と同じ `podman run` に対策を足しただけ） |
| `.state/` | ログと生成物（gitignore 済み） |
