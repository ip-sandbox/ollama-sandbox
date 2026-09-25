# Cline CLI × Ollama モデル比較（CPU 推論、cline-sandbox:v3）

検証日: 2026-09-24
ホスト: Ryzen 5 PRO 4650G / 4 コア / 30GB RAM / GPU なし
イメージ: `localhost/cline-sandbox:v3`（Ubuntu 24.04, Cline CLI 3.0.64, Ollama 0.34.2）
検証スクリプト: `cpu-timeout/model-e2e.sh <model-tag>`（`v3-e2e.sh` を元に cline 専用・モデル非依存プロンプトで新規作成。既存ファイルは無編集）
プロンプト: `Create a file named hello.txt in the current directory containing exactly the text: hello from cline. Then finish the task.`
起動方法: launcher.py と同じ `podman run --rm --network=none -v ollama-models:/models -e OLLAMA_MODELS=/models -e CLINE_MODEL=<tag>`（コンテナは毎回新規、モデルは cold start）
モデル pull/削除: `--network=host` で `ollama pull`、`--network=none` で `ollama rm`（launcher.py と同じ手順）

## 結果一覧

| モデル | pull サイズ | ロード時間 | 1ターン目 prompt tokens | prefill 速度 | 1ターン目所要時間 | 総所要時間(elapsed) | ollama リクエスト数 | rc | hello.txt 完全一致 |
|---|---|---|---|---|---|---|---|---|---|
| gemma4:12b-it-qat（参考・既存結果） | 6.7GB | - | ~4,500 | ~8 tok/s | ~9分 | ~10分 | - | 0 | Yes |
| mistral-nemo:12b-instruct-2407-q4_K_M | 7.5GB | 17.9秒 | 4,314 | 8.64 tok/s | 8分58秒 | 9分7秒 (547秒) | 1 | 0 | **No（ファイル未作成）** |
| gpt-oss:20b | 13GB | 20.0秒 | 3,255 | 19.99 tok/s | 4分30秒 | 4分55秒 (295秒) | 2 | 0 | Yes（"hello from cline"、末尾ピリオド・改行なし） |

truncated はいずれも 0（コンテキスト長 32768 に対し余裕あり）。

## 所見

### mistral-nemo:12b-instruct-2407-q4_K_M — 失敗（ツールコール形式の不一致）

rc=0 で正常終了扱いになったが、`hello.txt` は作成されなかった。原因はタイムアウトやコンテキスト切り詰めではなく、**モデルが Cline の期待するツールコール構文に従わなかった**こと。`run.log` の最終出力は以下の通り、モデル独自の擬似関数呼び出し形式をテキストとしてそのまま出力しており、Cline 側はこれを実行可能なツールコールとしてパースできなかった（そのままテキスト応答として扱われ、ターンが終了した）。

```
[TOOL_CALLS]<function call name="editor">
{
  "path": "/workspace/hello.txt",
  "new_text": "hello from cline."
}
</function_call>
```

Ollama 側ログでは `template selection ... parser="" go_template="[completion tools]"` となっており、Cline がプロンプト内テキストとしてツール定義を渡す方式（native `tools` API ではない）に対し、mistral-nemo は自身の学習済みの特殊トークン形式（Mistral 独自の `[TOOL_CALLS]` 記法）で応答してしまい、噛み合わなかったと考えられる。これは再現性の高い構造的な非互換とみられ、揺らぎによる一過性の失敗ではないと判断し、既定の90分予算内で時間を消費するだけの単純再実行は行わず、この結果を最終結果として記録した（1回のみ許容されるリトライは gpt-oss 側の thinking 検証に充てた）。

推論性能そのものは gemma4 と同等（prefill 8.64 tok/s、gemma4 は約8 tok/s）で、CPU 推論としては動作していた。問題はタスク完遂能力（ツール呼び出し互換性）であり、速度ではない。

### gpt-oss:20b — 成功、ただし `--thinking none` は無視される

`hello.txt` は正しく作成された（内容 `hello from cline`、末尾の句点・改行なし。プロンプト中の "exactly the text: hello from cline." のピリオドは文末の句読点と解釈し、文字列自体には含めない、という妥当な解釈をモデルが行った）。

**`--thinking none` を指定したにもかかわらず、reasoning（thinking）ブロックは省略されなかった。** `run.log` には `[thinking]` のタグが付いた大量の思考過程トークン（"The user asks: ... We need to create a file. We should use apply_patch with Add File. ..." 等）がそのまま出力されており、gpt-oss（reasoning モデル）の thinking はサーバ側もしくは Cline 側の `--thinking none` フラグでは抑制できていない。実行ログにも以下の警告が出ている。

```
Warning: AI SDK Warning (ollama.responses / gpt-oss:20b): reasoning parts in assistant messages are not supported for Ollama responses
```

これは Cline の Ollama responses 統合が reasoning パートを正式サポートしていないことを示しており、thinking 抑制フラグが効かない一因と考えられる。動作自体（ツール呼び出し）には支障はなく、`apply_patch`（Codex 由来のパッチ形式ツール）を使ってファイルを作成し、2回目のリクエスト（14秒、36トークン）で完了報告を行い、正常終了した。

thinking 出力があった分、実際の思考+生成トークン量は多いはずだが、prefill 速度は 19.99 tok/s と gemma4/mistral-nemo（約8〜8.6 tok/s）の倍以上速く、総所要時間も約5分と最も短かった（gpt-oss は MoE アーキテクチャのため、20B のパラメータ数に対して実際の active パラメータが少なく、CPU でも高速に動いたとみられる）。

リトライについて: gpt-oss は1回で成功（rc=0、hello.txt 完全一致）したため、追加リトライ（`--thinking none` を外す等）は実施しなかった。

## 最終ディスク・ボリューム状態

```
$ df -h /
ファイルシス   サイズ  使用  残り 使用% マウント位置
/dev/sda3         71G   53G   19G   75% /

$ podman run ... ollama list
NAME                 ID              SIZE      MODIFIED
gemma4:12b-it-qat    38044be4f923    7.2 GB    29 hours ago

$ podman ps -a
CONTAINER ID  IMAGE       COMMAND     CREATED     STATUS      PORTS       NAMES
(なし・コンテナ残留なし)
```

ボリューム `ollama-models` は検証前と同じく `gemma4:12b-it-qat` のみに戻っている（mistral-nemo, gpt-oss ともに `ollama rm` 済み）。ディスク空き容量も検証開始前とほぼ同じ 19GB に復帰。

`git status --short` は `cpu-timeout/model-e2e.sh` の新規追加のみ（既存ファイルは無編集、コミットは未実施）。
