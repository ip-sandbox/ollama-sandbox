# GitHub Copilot CLI × Ollama（BYOK・オフライン）の組み込みと検証

検証日: 2026-09-26
ホスト: Ryzen 5 PRO 4650G / 4 コア / 30GB RAM / GPU なし
Copilot CLI: 1.0.88（`@github/copilot`。本体は初回起動時に `~/.cache/copilot` へ展開される Node の単一実行ファイル＋Rust の実行部）
Ollama: 0.34.2 / `OLLAMA_CONTEXT_LENGTH=32768` / `OLLAMA_KEEP_ALIVE=-1`

## 設定（entrypoint.sh）

Copilot CLI は環境変数だけで BYOK（自前のモデル提供元）に切り替わり、設定ファイルは要らない。

| 環境変数 | 値 | 理由 |
|---|---|---|
| `COPILOT_PROVIDER_BASE_URL` | `http://127.0.0.1:11434/v1` | Ollama の OpenAI 互換 API |
| `COPILOT_PROVIDER_WIRE_API` | `responses` | Codex と同じ `/v1/responses` を使う（Ollama 公式の例と同じ）。既定は `completions` |
| `COPILOT_MODEL` | `$CLINE_MODEL` | 選んだモデル |
| `COPILOT_OFFLINE` | `true` | GitHub 認証・テレメトリ・Web ツール・GitHub MCP・自動更新をすべて止める。ログに `Running in offline mode` と出る |
| `COPILOT_AUTO_UPDATE` | `false` | 念のため（npm 版は新しい版を知らせるだけで、自分では入れ替えない） |
| `COPILOT_PROVIDER_MAX_PROMPT_TOKENS` | コンテキスト長 − 4096 | カタログに無いモデルは既定値になるので、Ollama のコンテキスト長に合わせる |
| `COPILOT_PROVIDER_MAX_OUTPUT_TOKENS` | `4096` | 同上 |

- API キーは設定しない（Ollama には不要）。
- 作業ディレクトリを `~/.copilot/config.json` の `trustedFolders` に追記し、起動時の「Confirm folder trust」を省く（tmux 上の対話画面で確認）。`settings.json` に書いても効かない。
- GitHub アカウント・サブスクリプションは不要。

## 段階 1: 偽 Ollama（`research/stubs/probe-copilot-timeout.sh`）

| 遅延の場所 | 無音 | 結果 |
|---|---|---|
| 最初のバイトまで | 0 秒 | 完了（9 秒） |
| 最初のバイトまで / ヘッダ後 / 生成途中 | 330 秒 | すべて完了（Cline の 300 秒の壁は無い） |
| 最初のバイトまで（初回のみ遅延） | 1900 秒 | **600 秒で切断 → 送り直し**で完了 |
| ヘッダ後（初回のみ遅延） | 700 秒 | 600 秒で切断 → 送り直しで完了 |
| 最初のバイトまで（毎回遅延） | 700 秒 | 600 秒で切断 × 6 回、約 1 時間で失敗: `Failed to get response from the AI model; retried 5 times ... Native model HTTP stream timed out` |

- 600 秒は無音の上限で、ヘッダが届いても本文が 600 秒来なければ切れる。変更する環境変数・設定は見つからなかった（ヘルプと実行部の文字列を確認）。
- 1 ターン目のリクエスト: instructions 約 21,000 文字 + ツール 17 個（約 25,000 文字）。実トークンは Devstral で 10,547（Codex の約 1.3 倍、Cline の約 2.3 倍）。

### 実モデルで、切断後の送り直しが続きから進むか（`research/models/probe-cancel-cache.sh`）

Devstral に Copilot の実リクエストを送り、1 回目を 300 秒で切ってすぐ送り直した。

```
task 0 | new prompt, task.n_tokens = 10547 | cached n_tokens = 0
task 0 | stop processing: n_tokens = 2048            ← 切断時点で処理済みのバッチ
task 4 | cached n_tokens = 2048, memory_seq_rm [2048, end)   ← 送り直しは続きから
```

**Ollama（llama.cpp）は、切断までに処理したプロンプトを prompt cache に残す。** したがって prefill が 600 秒を超えても、Copilot の送り直しのたびに進み、最大 6 回（約 60 分）の枠の中で完了する。中継プロキシなどの対策は入れていない。

## 段階 2: 結合テスト

| テスト | 結果 |
|---|---|
| `tests/unit`（launcher） | 19/19 |
| `tests/sandbox/test-sandbox.sh`（v5、TEST 6 = `test-copilot.sh`） | 6/6 |
| `tests/sandbox/test-native.sh`（模擬コンテナ、TEST 4 = `test-copilot.sh`） | 4/4 |

`test-copilot.sh` は smollm:135m で、版・環境変数・信頼済みフォルダ・Ollama へのリクエスト到達・オフライン動作を確かめる。smollm:135m はツールに対応していないため、Copilot の応答自体は `400 ... does not support tools` になる（Copilot は必ず tools を送る）。

## 段階 3: 実モデル E2E（`research/e2e/e2e.sh --agent copilot --backend podman|native`）

プロンプト: `Create a file named hello.txt in the current directory containing exactly the text: hello from copilot. Then finish the task.`
実行: `copilot -p "<prompt>" --allow-all-tools --no-ask-user`
- podman: `cline-sandbox:v5` を `--network=none` で毎回新規に起動。
- native: 模擬コンテナ（`research/e2e/native-sim.sh`、ubuntu:22.04 + install.sh）の中で、launcher.py の native モードが組み立てるコマンドを実行。毎回 Ollama の serve を止めて cold から始める。

| モデル | backend | 結果 | hello.txt | 所要時間 | `/v1/responses`（500 = 600 秒切断） | 1 ターン目 prompt tokens |
|---|---|---|---|---:|---|---:|
| devstral-small-2:24b-iq4_xs | podman | ✅ | `hello from copilot.` | 2735 秒（45.6 分） | 500×4 → 200×2 | 約 10,550 |
| devstral-small-2:24b-iq4_xs | native | ✅ | `hello from copilot` | 2837 秒（47.3 分） | 500×4 → 200×2 | 約 10,630 |
| qwen3:8b | podman | ✅ | `hello from copilot` | 1444 秒（24.1 分） | 500×1 → 200×2 | 約 10,220 |
| qwen3:8b | native | ✅ | `hello from copilot` | 1258 秒（21.0 分） | 500×1 → 200×2 | 約 10,380 |
| gemma4:12b-it-qat | podman | ✅ | `hello from copilot.` | 1326 秒（22.1 分） | 500×2 → 200×2 | 約 10,730 |
| gemma4:12b-it-qat | native | ✅ | `hello from copilot.` | 1632 秒（27.2 分） | 500×2 → 200×3 | 約 10,910 |
| gpt-oss:20b | podman | ❌ | （作成されず） | 583 秒 | 200 → **400** | 約 10,220 |
| gpt-oss:20b | native | ❌ | （作成されず） | 542 秒 | 200 → **400** | 約 10,250 |
| smollm:135m | 両方 | 非対応 | – | – | 400（tools 非対応） | – |

- Devstral は 4 回切断されたが、毎回 prompt cache の続きから進み（ctx 3072 → 5120/6144 → 8192 → 10240）、5 回目で prefill を終えた。送り直しの上限（6 回）まで余裕は 1 回。これより prefill が遅いモデル・長いプロンプトでは失敗しうる。
- podman はピリオド付き（プロンプトの "hello from copilot." を文字どおりに解釈）、native はピリオドなし。どちらも内容は正しい。

### gpt-oss:20b が失敗する理由（podman・native で同じ）

```
✗ Edit
  └ Failed to parse patch: The first line of the patch must be '*** Begin Patch' The input begins
    with '{' and appears to be JSON-wrapped. apply_patch is a freeform tool; pass raw patch text directly.
400 input[2]: unknown input item type: "custom_tool_call"
```

- Copilot CLI は gpt-oss を組み込みのカタログで認識し、ファイル編集に `apply_patch` を「freeform（custom）ツール」として渡す。
- Ollama の `/v1/responses` は custom ツールを扱えない。gpt-oss は JSON で呼び出してしまい、Copilot はそれを拒否する。
- Copilot が次のリクエストで履歴に `custom_tool_call` を入れて送り返すと、Ollama が 400 で拒否して終了する。
- Codex + gpt-oss の apply_patch 失敗（`APPLY_PATCH_RESULT.md`）と同じ種類の問題で、インフラ（タイムアウトや切断）の問題ではない。prefill は 1 回の 200（約 9 分）で終わっており、切断は起きていない。
- 回避策の候補（未検証）: `COPILOT_PROVIDER_MODEL_ID` をカタログに無い名前にして、既定のツール（create / edit）を使わせる。または `COPILOT_PROVIDER_WIRE_API=completions` にする。

## まとめ

- Devstral・qwen3:8b・gemma4:12b-it-qat は、podman（コンテナ）と native（コンテナ無し）の両方で成功。backend による差は無い（所要時間の差は ±20% 程度で、cold start とモデルの出力のゆらぎによる）。
- gpt-oss:20b は両方で失敗（apply_patch の freeform ツールを Ollama が扱えない）。
- smollm:135m はツール非対応なので、Copilot では使えない。
- 検証後、model volume から Devstral・qwen3・gemma4・gpt-oss を削除した（ディスク容量のため。Devstral は launcher の「モデルをダウンロード」で取り込み直せる）。
