#!/bin/bash
# test-native.sh - native モード（すでにコンテナ内の環境で、コンテナを使わずに動かす）の結合テスト
#
# Colab の端末を模したコンテナ（research/e2e/native-sim.sh setup で作る。素の ubuntu:22.04 に install.sh を
# 当てたもの）の中で、launcher.py が native モードで組み立てるコマンドをそのまま実行する。
# リポジトリは /repo に読み取り専用でマウントされている。モデルは model volume（/models）に launcher 経由で
# 取得する（smollm:135m が無ければネットワークから取得する）。
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SIM="$DIR/research/e2e/native-sim.sh"

echo "============================================================"
echo "  NATIVE MODE INTEGRATION TEST SUITE (cline-native-sim)     "
echo "============================================================"

# launcher.py を native モードで読み込み、ワークスペース（/workspace）で Python の文を実行する
native() {
    "$SIM" exec python3 -c "
import os, sys
sys.path.insert(0, '/repo/scripts')
import launcher
os.chdir('/')
launcher.ensure_volume()
os.chdir(launcher.NATIVE_WORKSPACE)
$1"
}

# ワークスペースは毎回空にする（/workspace が以前の E2E へのシンボリックリンクなら外す）
"$SIM" exec bash -c 'rm -rf /workspace && mkdir /workspace'

echo ""
echo ">>> [TEST 1] Backend auto-detection & install.sh --check <<<"
native "
assert launcher.BACKEND == 'native', launcher.BACKEND
print('  backend =', launcher.BACKEND, '/ inside_container =', launcher.inside_container())
launcher.ensure_native_tools()
print('  install.sh --check OK')"

echo ""
echo ">>> [TEST 2] Model download via launcher (smollm:135m) <<<"
native "
model = launcher.Model(label='SmolLM', tag='smollm:135m')
if not launcher.model_is_available(model):
    launcher.run(launcher.prepare_command(model))
print('  downloaded:', sorted(launcher.downloaded_models()))
assert 'smollm:135m' in launcher.downloaded_models()"

echo ""
echo ">>> [TEST 3] Cline / Codex config on launch (agent_setup) <<<"
native "
cmd = launcher.container_command('smollm:135m', ['bash', '-c',
    'cline --version && codex --version && grep -q ^wire_api.*responses ~/.codex/config.toml && echo codex config OK'],
    agent_setup=True)
os.execvp(cmd[0], cmd)"

echo ""
echo ">>> [TEST 4] Copilot CLI Offline BYOK (Ollama) <<<"
native "
cmd = launcher.container_command('smollm:135m', ['bash', '/repo/tests/sandbox/test-copilot.sh'], agent_setup=True)
os.execvp(cmd[0], cmd)"

echo ""
echo "============================================================"
echo "  ALL NATIVE MODE INTEGRATION TESTS SUCCESSFULLY COMPLETED! "
echo "============================================================"
