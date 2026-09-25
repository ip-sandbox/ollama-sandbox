#!/usr/bin/env python3
"""make_codex_catalog.py - Codex の model_catalog_json 用に、Ollama モデルの項目を1つ持つカタログを出力する

Codex は内蔵カタログに無いモデルを fallback metadata で扱い、apply_patch_tool_type が未設定になる。
その結果 apply_patch ツールはリクエストに載らないのに、指示文は apply_patch を使えと言う。
このカタログで apply_patch_tool_type を明示し、ツールを載せる。

雛形は Codex 内蔵カタログの gpt-5.4 項目の形（キー一覧は codex 0.156.1 のもの）。
指示文は、fallback 時に Codex が実際に送った instructions（スタブで保存したリクエスト本体）を
base_instructions にそのまま入れ、指示文の条件を fallback と揃える。

  make_codex_catalog.py <model> <freeform|function|none> <responses-dump.json> [context_window]
"""
import json
import sys

model = sys.argv[1]
ap_type = sys.argv[2]
with open(sys.argv[3], encoding="utf-8") as f:
    base_instructions = json.load(f)["instructions"]
ctx = int(sys.argv[4]) if len(sys.argv) > 4 else 32768

entry = {
    "slug": model,
    "display_name": model,
    "description": f"{model} via local Ollama",
    "supported_in_api": True,
    "visibility": "list",
    "priority": 1,
    "minimal_client_version": "0.1.0",
    "apply_patch_tool_type": None if ap_type == "none" else ap_type,
    "web_search_tool_type": "text",
    "shell_type": "unified_exec",
    "tool_mode": None,
    "multi_agent_version": None,
    "use_responses_lite": False,
    "prefer_websockets": False,
    "supports_parallel_tool_calls": False,
    "supports_search_tool": False,
    "support_verbosity": False,
    "default_verbosity": None,
    "supports_reasoning_summaries": False,
    "supports_reasoning_summary_parameter": False,
    "default_reasoning_summary": "none",
    "default_reasoning_level": None,
    "supported_reasoning_levels": [],
    "input_modalities": ["text"],
    "supports_image_detail_original": False,
    "truncation_policy": {"mode": "tokens", "limit": 10000},
    "context_window": ctx,
    "max_context_window": ctx,
    "auto_compact_token_limit": None,
    "base_instructions": base_instructions,
    "model_messages": None,
    "experimental_supported_tools": [],
    "include_skills_usage_instructions": False,
    "include_apps_usage_instructions": False,
    "include_plugin_usage_instructions": False,
    "node_repl_auto_review_required": False,
    "node_repl_disabled": True,
    "requires_sandboxed_review": False,
    "auto_review_model_override": None,
    "model_specialty": None,
    "availability_nux": None,
    "upgrade": None,
    "available_in_plans": [],
    "default_service_tier": None,
    "service_tiers": [],
    "additional_speed_tiers": [],
}
json.dump({"models": [entry]}, sys.stdout, indent=1)
print()
