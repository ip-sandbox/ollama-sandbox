# Devstral Small 2 24B IQ4_XS × Cline / Codex（CPU）

> **注（2026-09-25 のファイル整理）:** 本文中のスクリプト名・パスは検証当時のものです。`cpu-timeout/` は `research/` に役割別に再編し、`scripts/test-*.sh` は `tests/sandbox/` に移しました。旧名と新名の対応は [research/README.md](../../research/README.md) を参照してください。

対象: cline-sandbox:v3（Cline 3.0.64 / Codex 0.156.1 / Ollama 0.34.2）、Ryzen 5 PRO 4650G 4 コア、RAM 30GB、GPU なし

## 結論

- **Cline・Codex とも 1 回で完走した。** hello.txt は内容一致、タイムアウトなし、truncated=0。
- **ツール呼び出しは両経路とも構造化されて返る。** mistral-nemo のような平文の `[TOOL_CALLS]` にはならない。
- Codex では apply_patch を呼ばず、最初からシェル（`echo ... > hello.txt`）で書いた。そのため失敗の往復が無く、リクエストは 2 回だけ。
- 遅い点
  - prefill は 4.55 tok/s で、gemma4 の約 55%。
  - 1 ターン目は Cline で 18 分 46 秒、Codex で 27 分 36 秒。
  - Cline の 1 ターン目は、既定のリクエストタイムアウト（30 分）に対して余裕が約 11 分しかない。より長い指示や大きい AGENTS.md を渡すと超えうる。

## 取り込み（`devstral-import.sh`）

参照手順（ip-sandbox/colab-ollama `devstral-vibe/11_server_ollama.sh`）どおり、Unsloth の IQ4_XS の重みに、Ollama 公式タグ `devstral-small-2:24b-instruct-2512-q4_K_M` の template レイヤ（手書き Go テンプレート、3,418 B）を移植した。params（`temperature 0.15`）と `min_p 0.01` も付けた。重みの置き方だけ参照手順と違う。

| 方法 | 結果 |
|---|---|
| `ollama pull hf.co/unsloth/...:IQ4_XS` | **失敗**。HF が xet CDN（別ホスト）へリダイレクトし、Ollama 0.34.2 が `blocked redirect to a different host` で拒否する |
| curl + `ollama create FROM <file>`（参照手順） | GGUF が blob store に複製され、約 25GB 要る |
| **curl で `blobs/sha256-<digest>` に直接置く → `ollama create FROM <blob>`（採用）** | `using existing layer` で複製なし。ディスク増分 12,187 MiB |

- GGUF: `Devstral-Small-2-24B-Instruct-2512-IQ4_XS.gguf`（12,780,424,352 B）。sha256 `6b8270a8…a118a`（HF の LFS oid と一致を確認）
- 登録名: `devstral-small-2:24b-iq4_xs`
- num_ctx は Modelfile に入れていない。entrypoint の `OLLAMA_CONTEXT_LENGTH=32768` を使う。

## 事前確認（`devstral-probe.sh`）

| 項目 | 結果 |
|---|---|
| ロード | 21〜25 秒、メモリ 18GB（ctx 32768、100% CPU） |
| テンプレート描画 | OK（`currentDate` が 0.34.2 で展開され、「Today's date is 2026-09-25.」と答えた） |
| `/api/chat` + tools（Cline の経路） | `tool_calls: write_file(path="hello.txt", content="hi")`、content は空 |
| `/v1/responses` + tools（Codex の経路） | `function_call write_file {"path":"hello.txt","content":"hi"}` |
| 速度 | prefill 4.55 tok/s、decode 2.06 tok/s |

## 実タスク E2E（`model-e2e.sh` / `model-e2e-codex.sh`、既定設定のまま）

| エージェント | 1 ターン目 prompt | 1 ターン目 | 総所要 | リクエスト | rc | hello.txt | ツール |
|---|---:|---:|---:|---:|---|---|---|
| Cline | 4,316 tok | 18分46秒 | 19分57秒 | 2 | 0 | `hello from cline`（一致） | `editor` で作成 |
| Codex | 7,549 tok | 27分36秒 | 28分12秒 | 2 | 0 | `hello from codex`（一致、末尾改行あり） | `exec_command` で `echo ... > hello.txt` |

## 他モデルとの比較（同じ hello.txt タスク、総所要）

| モデル | Cline | Codex | 備考 |
|---|---|---|---|
| gemma4:12b-it-qat | 約 10 分・成功 | 約 19 分・成功 | prefill 約 8 tok/s |
| gpt-oss:20b | 約 5 分・成功 | 約 21 分・成功 | MoE で prefill 約 20 tok/s。思考が平文で出る。Codex で apply_patch 失敗 ×4 |
| mistral-nemo:12b | 失敗 | 失敗 | ツールを構造化して呼べない |
| **devstral-small-2:24b-iq4_xs** | **約 20 分・成功** | **約 28 分・成功** | prefill 4.55 tok/s。ツール呼び出しは素直で、無駄なターンが無い |

## 残る注意点

- Cline の 1 ターン目は 30 分タイムアウトまで余裕 11 分しかない。プロンプトが約 7,000 tok を超えると届く。必要なら `podman run -e CLINE_TIMEOUT_MS=3600000` で延ばせる。
- メモリ 18GB を常駐させる（`OLLAMA_KEEP_ALIVE=-1`）。RAM 30GB のマシンでは、他の大きいモデルとの同時ロードはできない。
- 評価は各 1 回だけ。複数ファイルの編集など、実務的なタスクは試していない。
