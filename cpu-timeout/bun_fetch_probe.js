// bun_fetch_probe.js - cline に埋め込まれた Bun の fetch 単体が、無音の上流を何秒で切るかを測る
//
//   BUN_BE_BUN=1 ~/.npm-global/lib/node_modules/cline/bin/.cline bun_fetch_probe.js <url> [variant]
//
// variant:
//   default       fetch(url, {method:"POST", body})
//   timeout-false fetch(url, {..., timeout: false})   ← Bun 独自オプション
const [url, variant = "default"] = process.argv.slice(2);
const opts = { method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ model: "stub", messages: [{ role: "user", content: "hi" }], stream: true }) };
if (variant === "timeout-false") opts.timeout = false;

const t0 = performance.now();
const sec = () => ((performance.now() - t0) / 1000).toFixed(1);
try {
  const res = await fetch(url, opts);
  console.log(`[${sec()}s] headers status=${res.status}`);
  const text = await res.text();
  console.log(`[${sec()}s] body done bytes=${text.length}`);
  console.log(`RESULT variant=${variant} ok elapsed=${sec()}`);
} catch (e) {
  console.log(`RESULT variant=${variant} error elapsed=${sec()} name=${e?.name} code=${e?.code} msg=${e?.message}`);
}
