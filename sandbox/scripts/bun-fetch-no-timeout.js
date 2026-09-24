// bun-fetch-no-timeout.js - Cline CLI (Bun) の fetch 既定 300 秒タイムアウトを Ollama 宛てだけ外す preload
//
// cline 3.0.64 は Bun 1.3.13 でコンパイルされた単一バイナリで、Bun の fetch には
// 既定で 300 秒のタイムアウトがある（TimeoutError: "The operation timed out."）。
// Cline の Ollama プロバイダは fetch に Bun 独自の `timeout: false` を渡さないので、
// providers.json の settings.timeout をいくら延ばしても 300 秒で切れる。
// CPU 推論で prefill が 300 秒を超えると、ここで必ず落ちる。
//
// 使い方（バイナリは書き換えない。Bun は環境変数 BUN_OPTIONS を読む）:
//   export BUN_OPTIONS="--preload /path/to/bun-fetch-no-timeout.js"
//   （cline-sandbox:v3 イメージでは /usr/local/lib/cline/bun-fetch-no-timeout.js に置き、ENV で設定済み）
//   cline -P ollama -m gemma4:12b-it-qat ...
//
// 対象: 既定では OLLAMA_HOST（無ければ 127.0.0.1:11434）と localhost:11434 宛てだけ。
//   CLINE_NO_FETCH_TIMEOUT_HOSTS="host:port,host:port" で変更、"*" で全リクエスト。
// Ollama 宛ての打ち切りは Cline 自身の AbortController（providers.json の timeout）に任せる。
// 呼び出し側が timeout を明示している場合は尊重する。
(() => {
  const orig = globalThis.fetch;
  if (typeof orig !== "function" || orig.__clineNoTimeout) return;

  const ollamaHost = (process.env.OLLAMA_HOST || "127.0.0.1:11434").replace(/^https?:\/\//, "");
  const hosts = (process.env.CLINE_NO_FETCH_TIMEOUT_HOSTS ||
    [ollamaHost, "127.0.0.1:11434", "localhost:11434"].join(","))
    .split(",").map((s) => s.trim()).filter(Boolean);
  const all = hosts.includes("*");

  const targetOf = (input) => {
    try {
      const u = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input?.url);
      return u.host;
    } catch {
      return "";
    }
  };

  const wrapped = function fetch(input, init) {
    if ((all || hosts.includes(targetOf(input))) && !(init && "timeout" in init)) {
      init = { ...(init || {}), timeout: false };
    }
    return orig.call(this, input, init);
  };
  Object.assign(wrapped, orig); // fetch.preconnect など Bun の付属プロパティを保つ
  wrapped.__clineNoTimeout = true;
  globalThis.fetch = wrapped;

  if (process.env.CLINE_NO_FETCH_TIMEOUT_DEBUG === "1") {
    console.error(`[bun-fetch-no-timeout] pid=${process.pid} hosts=${all ? "*" : hosts.join(",")}`);
  }
})();
