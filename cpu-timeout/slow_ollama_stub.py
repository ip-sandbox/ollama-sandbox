#!/usr/bin/env python3
"""slow_ollama_stub.py - 応答を任意秒数遅らせる偽 Ollama（標準ライブラリのみ）

Cline がどの層で何秒後にリクエストを切るかを、実モデル無しで測るためのもの。

モード (STUB_MODE):
  silent   先頭バイト（ステータス行・ヘッダ）まで STUB_DELAY_SEC 秒無音。
           本物の Ollama が CPU で prefill している間と同じ（何も返らない）。
  headers  ヘッダは即返し、本文（最初の NDJSON 行）を STUB_DELAY_SEC 秒後に返す。

遅延は最初の /api/chat だけに掛ける（STUB_DELAY_ALL=1 で毎回）。
応答は、リクエストの tools に完了系ツール（名前に "complet" を含む）があれば
それを呼び、無ければテキスト "ok" を返す。

待機中もソケットを監視し、クライアントが切断した時刻を記録する
（= 実際に何秒で切られたかを、クライアント側のメッセージに頼らず測れる）。

記録:
  STUB_LOG (jsonl)         : 全リクエストの概要とイベント
  STUB_DUMP_DIR/chat-N.json: /api/chat のリクエストボディ全体（段階2で実プロンプトとして再利用）
"""
import json
import os
import select
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("STUB_PORT", "11434"))
DELAY = float(os.environ.get("STUB_DELAY_SEC", "45"))
MODE = os.environ.get("STUB_MODE", "silent")
DELAY_ALL = os.environ.get("STUB_DELAY_ALL", "0") == "1"
MODEL = os.environ.get("STUB_MODEL", "gemma4:12b-it-qat")
LOG = os.environ.get("STUB_LOG", "stub.jsonl")
DUMP_DIR = os.environ.get("STUB_DUMP_DIR", "")

T0 = time.monotonic()
_lock = threading.Lock()
_chat_count = 0


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def log(**kw):
    kw.setdefault("t", round(time.monotonic() - T0, 2))
    with _lock, open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(kw, ensure_ascii=False) + "\n")


def client_gone(sock):
    """ソケットが読み取り可能で、覗いて 0 バイトなら切断されている。"""
    try:
        r, _, _ = select.select([sock], [], [], 0)
        if not r:
            return False
        return sock.recv(1, socket.MSG_PEEK) == b""
    except OSError:
        return True


def summarize_chat(body):
    msgs = body.get("messages") or []
    chars = sum(len(m.get("content") or "") for m in msgs if isinstance(m.get("content"), str))
    tools = body.get("tools") or []
    tool_chars = len(json.dumps(tools, ensure_ascii=False))
    return {
        "n_messages": len(msgs),
        "roles": [m.get("role") for m in msgs],
        "content_chars": chars,
        "tools": [t.get("function", {}).get("name") for t in tools],
        "tool_schema_chars": tool_chars,
        # 概算（英語中心で ~4 文字/トークン）。正確な値は段階2で実モデルの prompt_eval_count を見る
        "approx_tokens": (chars + tool_chars) // 4,
        "options": body.get("options"),
        "stream": body.get("stream"),
        "think": body.get("think"),
        "keep_alive": body.get("keep_alive"),
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 標準エラーへの既定ログは抑止
        pass

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def do_HEAD(self):
        log(event="request", method="HEAD", path=self.path)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        log(event="request", method="GET", path=self.path)
        if self.path.startswith("/api/tags"):
            self._json(200, {"models": [{"name": MODEL, "model": MODEL, "modified_at": now_iso(),
                                         "size": 1, "digest": "stub",
                                         "details": {"family": "stub", "parameter_size": "12B",
                                                     "quantization_level": "Q4_0"}}]})
        elif self.path.startswith("/api/version"):
            self._json(200, {"version": "0.34.2"})
        elif self.path.startswith("/api/ps"):
            self._json(200, {"models": []})
        elif self.path == "/":
            self.send_response(200)
            data = b"Ollama is running"
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        body = self._body()
        if self.path.startswith("/api/chat"):
            return self._chat(body)
        log(event="request", method="POST", path=self.path, body_keys=list(body))
        if self.path.startswith("/api/show"):
            self._json(200, {"details": {"family": "gemma4"}, "model_info": {"gemma4.context_length": 131072},
                             "capabilities": ["completion", "tools"], "parameters": "", "template": ""})
        else:
            self._json(404, {"error": "not found"})

    def _wait(self, seconds, n):
        """seconds 秒待つ。途中でクライアントが切れたら False。"""
        end = time.monotonic() + seconds
        start = time.monotonic()
        while time.monotonic() < end:
            if client_gone(self.connection):
                log(event="client_disconnected", chat=n, after_sec=round(time.monotonic() - start, 1))
                return False
            time.sleep(0.5)
        return True

    def _chat(self, body):
        global _chat_count
        with _lock:
            _chat_count += 1
            n = _chat_count
        summary = summarize_chat(body)
        log(event="request", method="POST", path=self.path, chat=n, **summary)
        if DUMP_DIR:
            os.makedirs(DUMP_DIR, exist_ok=True)
            with open(os.path.join(DUMP_DIR, f"chat-{n}.json"), "w", encoding="utf-8") as f:
                json.dump(body, f, ensure_ascii=False, indent=1)

        delay = DELAY if (n == 1 or DELAY_ALL) else 0
        try:
            if MODE == "silent" and delay and not self._wait(delay, n):
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.flush()
            if MODE == "headers" and delay and not self._wait(delay, n):
                return
            for line in self._chat_lines(summary["tools"]):
                self._chunk(line)
            self._chunk(b"")
            log(event="chat_done", chat=n, delayed_sec=delay)
        except (BrokenPipeError, ConnectionResetError) as e:
            log(event="client_disconnected", chat=n, error=type(e).__name__)

    def _chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def _chat_lines(self, tools):
        base = {"model": MODEL, "created_at": now_iso()}
        done_tool = next((t for t in tools if t and "complet" in t), None)
        if done_tool:
            msg = {"role": "assistant", "content": "",
                   "tool_calls": [{"function": {"name": done_tool, "arguments": {"result": "ok"}}}]}
        else:
            msg = {"role": "assistant", "content": "ok"}
        yield json.dumps({**base, "message": msg, "done": False}).encode() + b"\n"
        yield json.dumps({**base, "message": {"role": "assistant", "content": ""}, "done": True,
                          "done_reason": "stop", "total_duration": 1, "load_duration": 1,
                          "prompt_eval_count": 1, "prompt_eval_duration": 1,
                          "eval_count": 1, "eval_duration": 1}).encode() + b"\n"


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    log(event="start", port=PORT, mode=MODE, delay=DELAY, delay_all=DELAY_ALL)
    print(f"stub listening on 127.0.0.1:{PORT} mode={MODE} delay={DELAY}s", file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
