#!/usr/bin/env python3
"""fetch_ollama_template.py - Ollama registry から公式タグの template / params レイヤだけを取り出す

重み（十数 GB）には触らず、マニフェストと数 KB のレイヤだけを取る。
取り出した template を別の GGUF（例: Unsloth の IQ4_XS）に移植するために使う。
参照: ip-sandbox/colab-ollama devstral-vibe/11_server_ollama.sh

  fetch_ollama_template.py <official-tag> <out-dir>
    -> <out-dir>/template.gotmpl, <out-dir>/params.json（params レイヤがあれば）
"""
import json
import os
import sys
import urllib.request

ref, out_dir = sys.argv[1], sys.argv[2]
name, _, tag = ref.partition(":")
if "/" not in name:
    name = "library/" + name
base = "https://registry.ollama.ai/v2"


def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    return urllib.request.urlopen(req, timeout=60).read()


manifest = json.loads(get(f"{base}/{name}/manifests/{tag or 'latest'}",
                          {"Accept": "application/vnd.docker.distribution.manifest.v2+json"}))
layers = {l["mediaType"].rsplit(".", 1)[-1]: l["digest"] for l in manifest["layers"]}
if "template" not in layers:
    sys.exit(f"{ref} に template レイヤがありません")

os.makedirs(out_dir, exist_ok=True)
template = get(f"{base}/{name}/blobs/{layers['template']}")
with open(os.path.join(out_dir, "template.gotmpl"), "wb") as f:
    f.write(template)
print(f"template: {len(template)} B ({layers['template'][:19]})")
text = template.decode("utf-8", "replace")
for token in ("[AVAILABLE_TOOLS]", "[TOOL_CALLS]", "[ARGS]", "[TOOL_RESULTS]"):
    print(f"  {token:18s} {'あり' if token in text else '★ 無い'}")

if "params" in layers:
    params = get(f"{base}/{name}/blobs/{layers['params']}")
    with open(os.path.join(out_dir, "params.json"), "wb") as f:
        f.write(params)
    print(f"params: {params.decode()}")
