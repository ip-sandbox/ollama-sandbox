#!/usr/bin/env python3
"""bench_prefill.py - Cline の実リクエストを本物の Ollama に投げ、ロード・prefill・decode を測る

段階1でスタブが保存した Cline の /api/chat リクエスト（system + tools 25 個）をそのまま使うので、
「Cline の 1 ターン目が CPU で何秒かかるか」を Cline 抜きで測れる。

  bench_prefill.py <chat-1.json> [--runs 2] [--num-predict 128] [--out result.json]

1 回目 = cold（ロード + 全 prefill）、2 回目以降 = 同一プロンプト（Ollama の prompt cache が効くか）。
最後に、必要タイムアウトの目安 = load + prefill + num_predict/decode を出す。
"""
import argparse
import json
import os
import time
import urllib.request

HOST = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")


def chat(body):
    req = urllib.request.Request(f"http://{HOST}/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=None) as r:
        res = json.load(r)
    res["_wall_sec"] = time.monotonic() - t0
    return res


def sec(ns):
    return (ns or 0) / 1e9


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("request")
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--num-predict", type=int, default=128)
    ap.add_argument("--out")
    a = ap.parse_args()

    body = json.load(open(a.request, encoding="utf-8"))
    body["stream"] = False
    body.setdefault("options", {})["num_predict"] = a.num_predict

    rows = []
    for i in range(a.runs):
        r = chat(body)
        row = {
            "run": i + 1,
            "wall_sec": round(r["_wall_sec"], 1),
            "load_sec": round(sec(r.get("load_duration")), 1),
            "prompt_tokens": r.get("prompt_eval_count"),
            "prefill_sec": round(sec(r.get("prompt_eval_duration")), 1),
            "prefill_tok_s": round(r.get("prompt_eval_count", 0) / max(sec(r.get("prompt_eval_duration")), 1e-9), 2),
            "gen_tokens": r.get("eval_count"),
            "decode_sec": round(sec(r.get("eval_duration")), 1),
            "decode_tok_s": round(r.get("eval_count", 0) / max(sec(r.get("eval_duration")), 1e-9), 2),
            "tool_calls": [c["function"]["name"] for c in (r.get("message", {}).get("tool_calls") or [])],
            "content_head": (r.get("message", {}).get("content") or "")[:120],
        }
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)

    cold = rows[0]
    # prefill の速度は cold 回の値（prompt cache が効くと 2 回目の prompt_tokens が小さくなるため）
    need = cold["load_sec"] + cold["prefill_sec"] + 1024 / max(cold["decode_tok_s"], 1e-9)
    summary = {
        "prompt_tokens": cold["prompt_tokens"],
        "prefill_tok_s": cold["prefill_tok_s"],
        "decode_tok_s": cold["decode_tok_s"],
        "load_sec": cold["load_sec"],
        "first_turn_wall_sec": cold["wall_sec"],
        "est_first_turn_with_1024_out_sec": round(need),
    }
    print("SUMMARY " + json.dumps(summary, ensure_ascii=False))
    if a.out:
        json.dump({"runs": rows, "summary": summary}, open(a.out, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
