#!/usr/bin/env python3
"""devstral_probe.py - 取り込んだモデルが Ollama 0.34.2 上でエージェントに使えるかを、実タスクの前に軽く確かめる

コンテナ内（--network=none、entrypoint が ollama を起動済み）で実行する。
  1. ロード時間
  2. テンプレートの描画（currentDate などの関数を 0.34.2 が解釈できるか）
  3. /api/chat のツール呼び出しが構造化（message.tool_calls）で返るか（Cline の経路）
  4. /v1/responses のツール呼び出しが function_call で返るか（Codex の経路）
  5. prefill / decode の速度（PROBE_SPEED_TOKENS 指定時のみ。CPU の 24B では 4k トークンで 20 分以上かかる）

  devstral_probe.py <model>
"""
import json
import os
import sys
import time
import urllib.request

MODEL = sys.argv[1]
HOST = "http://127.0.0.1:11434"
TOOL = {"type": "function", "function": {
    "name": "write_file", "description": "Write text to a file",
    "parameters": {"type": "object", "properties": {
        "path": {"type": "string"}, "content": {"type": "string"}},
        "required": ["path", "content"]}}}


def post(path, body):
    req = urllib.request.Request(HOST + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=None) as r:
            return json.load(r), time.monotonic() - t0
    except urllib.error.HTTPError as e:
        return {"http_error": e.code, "body": e.read().decode()[:300]}, time.monotonic() - t0


def rate(r):
    pe, pd = r.get("prompt_eval_count", 0), r.get("prompt_eval_duration", 0) / 1e9
    ec, ed = r.get("eval_count", 0), r.get("eval_duration", 0) / 1e9
    return (f"prefill {pe} tok / {pd:.1f}s = {pe / pd if pd else 0:.2f} tok/s, "
            f"decode {ec} tok / {ed:.1f}s = {ec / ed if ed else 0:.2f} tok/s")


print(f"== model {MODEL}")
r, t = post("/api/generate", {"model": MODEL, "keep_alive": -1})
print(f"[1] load: {t:.1f}s {r.get('http_error') or r.get('done_reason', '')}")

r, t = post("/api/chat", {"model": MODEL, "stream": False, "options": {"num_predict": 24},
                          "messages": [{"role": "user", "content": "What is today's date? Answer in one line."}]})
print(f"[2] template render (no system, uses currentDate): {t:.1f}s")
print("    ", r.get("http_error") or r.get("body") or r["message"]["content"].strip()[:200])
print("    ", "" if "http_error" in r else rate(r))

r, t = post("/api/chat", {"model": MODEL, "stream": False, "tools": [TOOL], "options": {"num_predict": 128},
                          "messages": [{"role": "user", "content": "Create hello.txt containing: hi"}]})
print(f"[3] /api/chat tools: {t:.1f}s")
if "http_error" in r:
    print("    ", r)
else:
    m = r["message"]
    print("     tool_calls:", json.dumps(m.get("tool_calls"), ensure_ascii=False)[:300])
    print("     content   :", repr(m.get("content", "")[:200]))
    print("     structured:", "OK" if m.get("tool_calls") else "NG（平文）")

r, t = post("/v1/responses", {"model": MODEL, "stream": False, "max_output_tokens": 128,
                              "tools": [{"type": "function", **TOOL["function"]}],
                              "input": [{"role": "user", "content": "Create hello.txt containing: hi"}]})
print(f"[4] /v1/responses tools: {t:.1f}s")
if "http_error" in r:
    print("    ", r)
else:
    for o in r.get("output", []):
        print("    ", o.get("type"), json.dumps({k: o.get(k) for k in ("name", "arguments", "content") if o.get(k)},
                                                 ensure_ascii=False)[:300])
    print("     structured:", "OK" if any(o.get("type") == "function_call" for o in r.get("output", [])) else "NG")

ntok = int(os.environ.get("PROBE_SPEED_TOKENS", "0"))
if not ntok:
    sys.exit(0)
filler = " ".join(f"item{i} is number {i}." for i in range(ntok // 8))
r, t = post("/api/chat", {"model": MODEL, "stream": False, "options": {"num_predict": 32},
                          "messages": [{"role": "user", "content": filler + "\nReply with just: ok"}]})
print(f"[5] speed (~{ntok} tok): {t:.1f}s")
print("    ", r.get("http_error") or rate(r))
