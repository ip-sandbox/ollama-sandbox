# Codex CLI 対応計画（cline-sandbox に Codex CLI を追加する）

## 目的

今の sandbox コンテナ（`--network=none`、Ollama 同居、モデルは `ollama-models` volume）で、
**Cline CLI に加えて Codex CLI も**ローカル Ollama（gemma4:12b-it-qat 等）で使えるようにする。
CPU 推論で最後まで完走することを完了条件とする（Cline で今回やったのと同じ水準）。

## 前提として分かっていること

### 今回の調査と参考 repo（colab-ollama）の実測から

| 項目 | 内容 | 出典 |
|---|---|---|
| 最新版 | `@openai/codex` 0.156.1（npm）。実体は Rust のネイティブバイナリで、Bun ではない | npm view |
| プロバイダ ID | `ollama` は組み込みで予約済み。`[model_providers.ollama]` を書くと起動しない。`ollama-local` などの別名にする | 参考 repo 手順書 §7.1 |
| wire_api | 0.154 以降、`wire_api = "chat"` は起動時に拒否される。**`responses` 必須**（Ollama の `/v1/responses`） | 参考 RESULT.md |
| サンドボックス | Codex の seccomp/landlock はコンテナ内では動かないことが多い（codex#1039）。**コンテナが境界なので `sandbox_mode = "danger-full-access"`**（公式の案内どおり） | 参考 手順書 |
| タイムアウト | `stream_idle_timeout_ms` が縛るのは **SSE イベント間の間隔**だけ。最初のバイトまでの時間（=prefill）は縛らない（0.155.1 で実測）。ただし、300 秒のような別の上限が無いかは CPU 級の長さでは未確認 | 参考 手順書 §7 |
| gemma4 との相性 | T4 実機で Codex × gemma4:12b-it-qat のタスクが 5/5 完走。修復プロキシ不要 | 参考 RESULT.md |
| num_ctx | Cline は `num_ctx=32768` をリクエストに付けるが、Codex（`/v1/responses` 経由）は付けないはず。**Ollama の CPU 既定 4k で黙って切り詰められる**ので、`OLLAMA_CONTEXT_LENGTH` の指定が必須（Ollama 公式は Codex に 64k 以上を推奨） | 今回確認した Ollama の help と参考 repo |
| CPU 速度 | この機械の gemma4 は prefill 8 tok/s、生成 3 tok/s。Codex のプロンプトは Cline より大きい可能性があり、**1 ターン目が 20 分を超えうる** | 今回の段階2 |

### 設計上の注意

- ホストにある `~/.local/bin/codex`（0.153.3、Gemini gateway 経由の個人設定）と `~/.codex` には一切触れない。検証は `CODEX_HOME` を隔離して行う。
- `--network=none` 下では、Codex の更新確認・ログイン誘導・テレメトリが失敗する。これらが「待ち」や「起動拒否」にならないよう、設定で止める必要がある（段階1で確認する）。

## 変更内容（案）

| ファイル | 変更 |
|---|---|
| `sandbox/Containerfile` | `npm install -g @openai/codex@0.156.1`（版を固定）を追加し、`codex --version` をビルド時に確認する。**Cline のタイムアウト対策も同梱**（`bun-fetch-no-timeout.js` を `COPY` し、`ENV BUN_OPTIONS=--preload ...`） |
| `sandbox/scripts/entrypoint.sh` | ① `~/.codex/config.toml` を生成する（内容は下記）。② Cline 用に、`cline auth -p ollama` を実行してから `providers.json` の `settings.timeout=1800000` を設定する。今は 3.x が読まない `~/.cline/settings.json` を書いているので、これを置き換える。③ `OLLAMA_CONTEXT_LENGTH`・`OLLAMA_KEEP_ALIVE=-1` を既定で設定する。④ 起動時に `cline` と `codex` の使い方を表示する |
| `scripts/launcher.py` | 起動時の `-e` はそのまま。起動後に案内を表示する（エージェントはコンテナ内で `cline` / `codex` を選んで打つ）。TUI にエージェント選択を足すかは要相談 |
| `scripts/test-sandbox.sh` | `codex --version` と、`--network=none` 下で `codex exec` が設定エラー無しで起動することを追加 |
| `README.md` | Codex の使い方・設定・既知の制約（`danger-full-access` の理由、CPU の所要時間）を追記 |
| `tests/` | launcher を変更する場合は unit test を追加 |

`config.toml`（案。値は段階1の実測で確定する）:

```toml
model = "gemma4:12b-it-qat"            # CLINE_MODEL から生成（汎用の AGENT_MODEL を用意して併用も可）
model_provider = "ollama-local"
model_context_window = 32768           # OLLAMA_CONTEXT_LENGTH と一致させる
sandbox_mode = "danger-full-access"    # コンテナが境界
approval_policy = "never"              # 対話で使うなら on-request（要相談）
check_for_update_on_startup = false    # オフライン
[model_providers.ollama-local]
name = "Ollama (local)"
base_url = "http://127.0.0.1:11434/v1"
wire_api = "responses"
stream_idle_timeout_ms = 1800000
request_max_retries = 0                # CPU で 20 分の prefill を再送されると地獄なので
stream_max_retries = 0
```

---

## 段階1: 切り分け（実モデル不使用）

新しいイメージを別タグ（`cline-sandbox:v3`）でビルドする。v2 は残す。

1. **ビルドと起動**: `codex --version` を確認する。`--network=none` で `codex exec` が設定エラー・更新確認・ログイン要求で止まらないことを確認する。必要な設定キーは実機のエラーで確定する。
2. **Codex のタイムアウトを実測**: 段階1で使ったスタブを `/v1/responses`（SSE）にも応答するよう拡張する。そのうえで以下を測る。
   - 最初のバイトまで 400 / 1200 / 1800 秒無音 → 完走するか（Rust 側の HTTP クライアントに別の上限が無いか）
   - イベント間を 60 秒あける → `stream_idle_timeout_ms` の効き方
   - `request_max_retries` の既定値で、タイムアウト時に再送が起きるか
3. **Codex が送るプロンプトの大きさ**: スタブで記録し、`num_ctx` や `options` が付くかを確認する。付かないなら `OLLAMA_CONTEXT_LENGTH` の必要値を決める（32768 か 65536）。
4. **Cline 側の回帰確認**: v3 イメージ内で preload の読み込みと `providers.json` の timeout が効くことを、スタブ 400 秒で確認する。

**成果物**: 切り分け結果を `codex/RESULT.md`（仮）の前半に書き、報告する。→ **承認を待つ**

## 段階2: 実モデル E2E（承認後に実施）

1. v3 コンテナで `codex exec`（gemma4、CPU）に `hello.txt` 作成タスクを実行する。経過時間、exit、ファイル内容、Ollama の `prompt eval` と `truncated` を記録する。
2. 同じ v3 で Cline の E2E も実行し、回帰が無いことを確認する。
3. `test-sandbox.sh` と launcher の unit test を実行する。
4. README と RESULT を更新する。

## 完了条件

- v3 コンテナ（`--network=none`）で、Codex と Cline の両方が gemma4 の CPU 推論で hello.txt タスクを exit 0 で完走する。
- `truncated = 0`（文脈が切り詰められていない）。
- `test-sandbox.sh` と unit test が通る。

## ディスク

- 空きは 20GB。v3 イメージ（約 3.5GB）が増える。
- 不要イメージの削除候補: `<none>` の 3 つ（計 10GB 前後）と `cline-sandbox:v1`。**消すかどうかは確認してから**にする。

## 要確認事項

1. 今回は**既存ファイル（Containerfile / entrypoint / launcher / README / tests）の変更を許可**してよいか。それとも前回と同様に新規ファイルだけで構成するか。
2. **Cline のタイムアウト対策も同時にイメージへ取り込む**か。
3. イメージのタグは v3 を新設するか、v2 を上書きするか。
4. 不要イメージ（`<none>` × 3、v1）の削除をしてよいか。
5. Codex の承認ポリシーは `never`（全自動）か `on-request`（対話で確認）か。
