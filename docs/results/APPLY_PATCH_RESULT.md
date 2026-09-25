# Codex + Ollama で apply_patch が失敗する原因

> **注（2026-09-25 のファイル整理）:** 本文中のスクリプト名・パスは検証当時のものです。`cpu-timeout/` は `research/` に役割別に再編し、`scripts/test-*.sh` は `tests/sandbox/` に移しました。旧名と新名の対応は [research/README.md](../../research/README.md) を参照してください。

対象: Codex CLI 0.156.1 / Ollama 0.34.2 / gpt-oss:20b（cline-sandbox:v3、CPU）

## 結論

原因は2段あり、どちらも Codex と Ollama の組み合わせの問題。モデルの能力の問題ではない。

1. **Codex がモデルを知らないため、apply_patch ツールをリクエストに載せない。**
   - `gpt-oss:20b` は Codex 内蔵のモデルカタログに無い（`Model metadata for gpt-oss:20b not found. Defaulting to fallback metadata`）。
   - fallback では `apply_patch_tool_type` が未設定になり、apply_patch ツールが登録されない。
   - ところが指示文（instructions）は「ファイル編集には `apply_patch` ツールを使え」と5回書いている。
   - モデルは存在しないツールを呼び、Codex は `unsupported call: apply_patch` で弾く。前回の E2E で4回失敗したのはこれ。
2. **ツールを載せても、Ollama が Codex の要求する形で返せない。**
   - Codex 0.156.1 の `apply_patch_tool_type` は `freeform` しか受け付けない（`function` は `unknown variant`）。freeform では apply_patch を Responses API の `type: "custom"`（lark 文法付き）で送る。
   - Ollama 0.34.2 の `/v1/responses` は custom ツールに対応していない（[ollama#17673](https://github.com/ollama/ollama/issues/17673) は未解決）。
     - 名前と説明だけの function ツールとしてモデルに見せ、文法は捨てる。apply_patch 1個で入力が 84 tok にしかならない。
     - モデルの呼び出しを `custom_tool_call` ではなく `function_call`（JSON 引数）で返す。
   - Codex の freeform ハンドラは custom の payload しか受けず、`tool apply_patch invoked with incompatible payload` で弾く。
   - パッチの中身も Codex 形式（`*** Begin Patch`）ではなく、unified diff だった（gemma4 で確認）。

どちらの経路でも apply_patch は成功しない。モデルは数回失敗したあと `exec_command`（`printf ... > hello.txt`）に切り替えて完了する。これが Codex だけ遅い理由。

## 実測（すべて同じプロンプト・同じ instructions）

| 条件 | リクエストの apply_patch | 失敗 | 結果 | 所要 |
|---|---|---|---|---|
| 既定（fallback） | 無し | `unsupported call: apply_patch` ×4 | printf で作成・一致 | 1265 秒 |
| カタログで `freeform` 指定 | `custom:apply_patch` | `incompatible payload` ×5 | printf で作成・一致 | 726 秒 |
| カタログで `function` 指定 | - | 設定読み込みでエラー（`unknown variant function`） | - | - |

- どちらもリクエストは8回。所要時間の差は、ターンごとの生成量のばらつきによる（1ターン目はどちらも約6分）。
- スタブでのツール一覧比較: `probe-apply-patch.sh`。Ollama の custom ツール扱いは、gemma4 に `/v1/responses` を直接投げて確認した。

## Web の報告との対応

- [ollama#14752](https://github.com/ollama/ollama/issues/14752): `ollama launch codex --model gpt-oss:20b` で同じ `Model metadata ... not found` と `unsupported call: apply_patch`。原因1。
- [HarnessRouter#202](https://github.com/HarnessRouter/harnessrouter/issues/202): 未知モデルでは `apply_patch_tool_type` が設定されず、apply_patch が登録されない（`spec_plan.rs` で `is_some()` のときだけ登録）。原因1。
- [codex-lab#924](https://github.com/cbusillo/codex-lab/issues/924) と [9router#1371](https://github.com/decolua/9router/issues/1371): ローカルの Responses 実装やプロキシが custom（freeform）ツールを扱えない。原因2。
- [ollama#17673](https://github.com/ollama/ollama/issues/17673): Ollama への custom ツール対応要望（未解決）。原因2。
- 「改行のエスケープ（quoting）が原因」という説明も出回っているが、今回の環境では当てはまらない。ツールがそもそも無いか、payload の型が合わないため、引数の中身より前の段階で弾かれている。

## 対処の選択肢（未実施）

- Ollama が custom ツールに対応するまでは、apply_patch を使える状態にはできない。
- 無駄なターンを減らすなら、指示文から apply_patch の指示を外し、シェルでの編集を指示する。
  - 方法は `model_instructions_file` か、カタログの `base_instructions`。
  - 効果は未検証。

## 追加したファイル

- `probe-apply-patch.sh`: スタブを相手に、カタログの有無と `apply_patch_tool_type` ごとの送信ツール一覧を比べる。
- `make_codex_catalog.py`: `model_catalog_json` 用のカタログを生成する。
- `apply-patch-e2e.sh`: カタログ付きで実タスクを走らせる。
- 検証後に gpt-oss:20b は削除し、モデル volume は gemma4 のみに戻した。
