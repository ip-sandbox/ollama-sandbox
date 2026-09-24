#!/usr/bin/env python3
"""sse_timing.py - 本物の Ollama の /v1/responses が、prefill の前にイベントを送るかを測る

Codex の stream_idle_timeout_ms は SSE イベント間の間隔を縛る。
Ollama が response.created を prefill 前に即送るなら、prefill 全体が「間隔」になり
idle timeout に当たる。先頭バイトが prefill 後なら当たらない。

  sse_timing.py [model] [approx_prompt_tokens]
"""
import json
import os
import sys
import time
import urllib.request

HOST = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
model = sys.argv[1] if len(sys.argv) > 1 else "gemma4:12b-it-qat"
ntok = int(sys.argv[2]) if len(sys.argv) > 2 else 1500

# ロードを先に済ませ、測定に混ぜない
urllib.request.urlopen(urllib.request.Request(
    f"http://{HOST}/api/generate", data=json.dumps({"model": model, "keep_alive": -1}).encode(),
    headers={"Content-Type": "application/json"}), timeout=None).read()
print(f"[load done] model={model}", flush=True)

filler = " ".join(f"item{i} is number {i}." for i in range(ntok // 5))
body = {"model": model, "stream": True, "max_output_tokens": 16,
        "input": [{"role": "user", "content": filler + "\nReply with just: ok"}]}
req = urllib.request.Request(f"http://{HOST}/v1/responses", data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json"})
t0 = time.monotonic()
seen = {}
with urllib.request.urlopen(req, timeout=None) as r:
    print(f"[{time.monotonic() - t0:7.1f}s] HTTP {r.status} headers", flush=True)
    for raw in r:
        line = raw.decode().strip()
        if line.startswith("event:"):
            ev = line.split(":", 1)[1].strip()
            if ev not in seen:
                seen[ev] = time.monotonic() - t0
                print(f"[{seen[ev]:7.1f}s] first {ev}", flush=True)
print(f"[{time.monotonic() - t0:7.1f}s] done", flush=True)
