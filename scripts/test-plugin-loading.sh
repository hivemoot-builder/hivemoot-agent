#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="${SCRIPT_DIR}/lib.sh"

source_lib() {
  # shellcheck source=scripts/lib.sh
  HIVEMOOT_LIB_LOADED='' source "$LIB_PATH"
}

# Create a minimal plugin directory with a plugin.yaml and optional MCP fragments.
# Usage: setup_test_plugin plugins_dir plugin_name [provider content ...]
setup_test_plugin() {
  local plugins_dir="$1"
  local plugin_name="$2"
  shift 2

  local plugin_dir="${plugins_dir}/${plugin_name}"
  mkdir -p "${plugin_dir}/mcp"

  cat > "${plugin_dir}/plugin.yaml" <<EOF
name: ${plugin_name}
version: 1.0.0
description: Test plugin ${plugin_name}
EOF

  while [ $# -ge 2 ]; do
    local provider="$1"
    local content="$2"
    shift 2
    case "$provider" in
      codex)
        printf '%s\n' "$content" > "${plugin_dir}/mcp/codex.toml"
        ;;
      *)
        printf '%s\n' "$content" > "${plugin_dir}/mcp/${provider}.json"
        ;;
    esac
  done
}

test_inject_mcp_config_claude() {
  echo "Testing Claude MCP config injection..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "claude" '{"mcpServers":{"test-srv":{"command":"node","args":["server.js"],"env":{}}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "claude" "$agent_home"

  local config_file="${agent_home}/.claude.json"
  if [ ! -f "$config_file" ]; then
    rm -rf "$tmp_dir"
    fail "Claude config file not created"
  fi

  if ! jq -e '.mcpServers["test-srv"].command == "node"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Claude config missing expected mcpServers entry"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Claude JSON MCP config injected correctly"
}

test_inject_mcp_config_gemini() {
  echo "Testing Gemini MCP config injection..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "gemini" '{"mcpServers":{"g-srv":{"command":"npx","args":["-y","pkg"]}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "gemini" "$agent_home"

  local config_file="${agent_home}/.gemini/settings.json"
  if ! jq -e '.mcpServers["g-srv"].command == "npx"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Gemini config missing expected mcpServers entry"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Gemini JSON MCP config injected correctly"
}

test_inject_mcp_config_opencode() {
  echo "Testing OpenCode MCP config injection..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "opencode" '{"mcp":{"oc-srv":{"command":"node","args":["s.js"]}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "opencode" "$agent_home"

  local config_file="${agent_home}/.config/opencode/config.json"
  if ! jq -e '.mcp["oc-srv"].command == "node"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "OpenCode config missing expected mcp entry"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ OpenCode JSON MCP config injected correctly"
}

test_inject_mcp_config_kilo() {
  echo "Testing Kilo MCP config injection..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "kilo" '{"mcp":{"k-srv":{"command":"node","args":["s.js"]}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "kilo" "$agent_home"

  local config_file="${agent_home}/.config/kilo/kilo.json"
  if ! jq -e '.mcp["k-srv"].command == "node"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Kilo config missing expected mcp entry"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Kilo JSON MCP config injected correctly"
}

test_inject_mcp_config_codex() {
  echo "Testing Codex TOML MCP config injection..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  local toml_fragment='[mcp_servers.codex-srv]
command = "npx"
args = ["-y", "@scope/pkg"]'

  setup_test_plugin "$plugins_dir" "my-plugin" "codex" "$toml_fragment"

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "codex" "$agent_home"

  local config_file="${agent_home}/.codex/config.toml"
  if [ ! -f "$config_file" ]; then
    rm -rf "$tmp_dir"
    fail "Codex config file not created"
  fi

  if ! grep -q '\[mcp_servers.codex-srv\]' "$config_file"; then
    rm -rf "$tmp_dir"
    fail "Codex config missing expected [mcp_servers.codex-srv] section"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex TOML MCP config injected correctly"
}

test_inject_mcp_config_merge() {
  echo "Testing sequential plugin merge (two plugins, both entries preserved)..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "plugin-a" \
    "claude" '{"mcpServers":{"srv-a":{"command":"node","args":["a.js"]}}}'
  setup_test_plugin "$plugins_dir" "plugin-b" \
    "claude" '{"mcpServers":{"srv-b":{"command":"node","args":["b.js"]}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/plugin-a" "claude" "$agent_home"
  inject_plugin_mcp_config "${plugins_dir}/plugin-b" "claude" "$agent_home"

  local config_file="${agent_home}/.claude.json"
  if ! jq -e '.mcpServers["srv-a"].command == "node"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Merged config missing srv-a entry"
  fi

  if ! jq -e '.mcpServers["srv-b"].command == "node"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Merged config missing srv-b entry"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Sequential plugin injection merges correctly (both entries present)"
}

test_inject_mcp_config_invalid_json() {
  echo "Testing invalid JSON fragment is rejected without writing..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "bad-plugin" \
    "claude" 'this is not json {'

  source_lib
  if inject_plugin_mcp_config "${plugins_dir}/bad-plugin" "claude" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "inject_plugin_mcp_config should fail on invalid JSON fragment"
  fi

  # Config file should not be written with mcpServers when fragment is invalid
  local config_file="${agent_home}/.claude.json"
  if [ -f "$config_file" ]; then
    if jq -e '.mcpServers' "$config_file" > /dev/null 2>&1; then
      rm -rf "$tmp_dir"
      fail "Config file should not have mcpServers when fragment is invalid JSON"
    fi
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Invalid JSON fragment rejected; config not corrupted"
}

test_no_fragment_for_provider() {
  echo "Testing skip when no fragment exists for provider..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  # Plugin has a Gemini fragment but no Claude fragment
  setup_test_plugin "$plugins_dir" "gemini-only" \
    "gemini" '{"mcpServers":{"g-srv":{"command":"npx","args":[]}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/gemini-only" "claude" "$agent_home"

  if [ -f "${agent_home}/.claude.json" ]; then
    rm -rf "$tmp_dir"
    fail "Claude config should not be created when no claude fragment exists"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Missing fragment for provider skipped silently"
}

test_merge_preserves_existing_keys() {
  echo "Testing merge preserves existing top-level keys in config..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  # Pre-existing config with other keys
  printf '%s\n' '{"someOtherKey":"value","mcpServers":{"existing-srv":{"command":"old"}}}' \
    > "${agent_home}/.claude.json"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "claude" '{"mcpServers":{"new-srv":{"command":"node","args":[]}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "claude" "$agent_home"

  local config_file="${agent_home}/.claude.json"
  if ! jq -e '.someOtherKey == "value"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Merge should preserve existing top-level keys"
  fi

  if ! jq -e '.mcpServers["existing-srv"].command == "old"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Merge should preserve existing mcpServers entries"
  fi

  if ! jq -e '.mcpServers["new-srv"].command == "node"' "$config_file" > /dev/null; then
    rm -rf "$tmp_dir"
    fail "Merge should add new mcpServers entries"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Merge preserves existing top-level keys and mcpServers entries"
}

test_load_agent_plugins_invalid_name() {
  echo "Testing load_agent_plugins rejects invalid plugin names..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  source_lib
  if load_agent_plugins "../escape" "$plugins_dir" "claude" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "load_agent_plugins should reject path traversal in plugin name"
  fi

  if load_agent_plugins "plugin with spaces" "$plugins_dir" "claude" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "load_agent_plugins should reject spaces in plugin name"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Invalid plugin names rejected"
}

test_load_agent_plugins_missing_manifest() {
  echo "Testing load_agent_plugins fails on missing plugin.yaml..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home" "${plugins_dir}/no-manifest/mcp"

  source_lib
  if load_agent_plugins "no-manifest" "$plugins_dir" "claude" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "load_agent_plugins should fail when plugin.yaml is missing"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Missing plugin.yaml causes failure"
}

test_load_agent_plugins_empty_list() {
  echo "Testing load_agent_plugins with empty list is a no-op..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  source_lib
  load_agent_plugins "" "$plugins_dir" "claude" "$agent_home"

  rm -rf "$tmp_dir"
  echo "  ✓ Empty plugin list is a no-op"
}

test_inject_mcp_config_idempotent_json() {
  echo "Testing JSON provider injection is idempotent (same plugin twice)..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "claude" '{"mcpServers":{"idem-srv":{"command":"node","args":["s.js"]}}}'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "claude" "$agent_home"
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "claude" "$agent_home"

  local config_file="${agent_home}/.claude.json"
  local count
  count="$(jq '.mcpServers | keys | length' "$config_file")"
  if [ "$count" -ne 1 ]; then
    rm -rf "$tmp_dir"
    fail "Idempotent JSON injection should produce exactly 1 mcpServers entry, got ${count}"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ JSON injection is idempotent (second call is a no-op)"
}

test_inject_mcp_config_idempotent_codex() {
  echo "Testing Codex TOML injection is idempotent (same plugin twice)..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "codex" $'[mcp_servers.idem-srv]\ncommand = "node"\nargs = ["s.js"]'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "codex" "$agent_home"
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "codex" "$agent_home"

  local config_file="${agent_home}/.codex/config.toml"
  local count
  count="$(grep -c '^\[mcp_servers\.' "$config_file")"
  if [ "$count" -ne 1 ]; then
    rm -rf "$tmp_dir"
    fail "Idempotent Codex injection should produce exactly 1 [mcp_servers.*] section, got ${count}"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex TOML injection is idempotent (second call is a no-op)"
}

test_inject_mcp_config_codex_no_trailing_newline() {
  echo "Testing Codex TOML injection adds separator for config without trailing newline..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "${agent_home}/.codex"

  # Pre-existing config with no trailing newline.
  printf 'model = "gpt-5"' > "${agent_home}/.codex/config.toml"

  setup_test_plugin "$plugins_dir" "my-plugin" \
    "codex" $'[mcp_servers.demo]\ncommand = "/bin/echo"\nargs = ["hi"]'

  source_lib
  inject_plugin_mcp_config "${plugins_dir}/my-plugin" "codex" "$agent_home"

  local config_file="${agent_home}/.codex/config.toml"
  # The fragment header must appear on its own line, not concatenated with the previous line.
  if ! grep -qE '^\[mcp_servers\.demo\]' "$config_file"; then
    rm -rf "$tmp_dir"
    fail "Codex injection should write [mcp_servers.demo] on its own line"
  fi

  # Verify 'model' key was not corrupted.
  if ! grep -q '^model = "gpt-5"' "$config_file"; then
    rm -rf "$tmp_dir"
    fail "Existing 'model' key should be preserved unchanged"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex injection inserts newline separator before fragment when needed"
}

test_inject_mcp_config_codex_rejects_extra_table() {
  echo "Testing Codex TOML injection rejects fragment with non-mcp_servers sections..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  # Fragment contains a valid mcp_servers section plus a forbidden extra table.
  setup_test_plugin "$plugins_dir" "bad-plugin" \
    "codex" $'[mcp_servers.demo]\ncommand = "/bin/echo"\nargs = ["hi"]\n\n[profiles.default]\nmodel = "unsafe"'

  source_lib
  if inject_plugin_mcp_config "${plugins_dir}/bad-plugin" "codex" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "inject_plugin_mcp_config should reject fragment with non-mcp_servers sections"
  fi

  # Config file must not have been written.
  if [ -f "${agent_home}/.codex/config.toml" ]; then
    rm -rf "$tmp_dir"
    fail "Config file should not be created when fragment is rejected"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex injection rejects fragment containing non-mcp_servers sections"
}

test_inject_mcp_config_codex_rejects_top_level_keys() {
  echo "Testing Codex TOML injection rejects fragment with top-level keys before first section..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  # Fragment has a top-level key before the [mcp_servers.*] section.
  setup_test_plugin "$plugins_dir" "bad-plugin" \
    "codex" $'model = "unsafe"\n[mcp_servers.demo]\ncommand = "/bin/echo"'

  source_lib
  if inject_plugin_mcp_config "${plugins_dir}/bad-plugin" "codex" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "inject_plugin_mcp_config should reject fragment with top-level keys"
  fi

  if [ -f "${agent_home}/.codex/config.toml" ]; then
    rm -rf "$tmp_dir"
    fail "Config file should not be created when fragment has top-level keys"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex injection rejects fragment with top-level keys outside [mcp_servers.*] sections"
}

test_inject_mcp_config_codex_rejects_indented_top_level_keys() {
  echo "Testing Codex TOML injection rejects fragment with indented top-level keys before first section..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  # Fragment has an indented top-level key before the [mcp_servers.*] section.
  # Leading whitespace must not bypass the guard.
  setup_test_plugin "$plugins_dir" "bad-plugin" \
    "codex" $'  model = "unsafe"\n[mcp_servers.demo]\ncommand = "/bin/echo"'

  source_lib
  if inject_plugin_mcp_config "${plugins_dir}/bad-plugin" "codex" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "inject_plugin_mcp_config should reject fragment with indented top-level keys"
  fi

  if [ -f "${agent_home}/.codex/config.toml" ]; then
    rm -rf "$tmp_dir"
    fail "Config file should not be created when fragment has indented top-level keys"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex injection rejects fragment with indented top-level keys outside [mcp_servers.*] sections"
}

test_inject_mcp_config_codex_rejects_unquoted_value() {
  echo "Testing Codex TOML injection rejects fragment with unquoted string value..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  # Common mistake: command = node instead of command = "node" — invalid TOML.
  setup_test_plugin "$plugins_dir" "bad-plugin" \
    "codex" $'[mcp_servers.demo]\ncommand = node'

  source_lib
  if inject_plugin_mcp_config "${plugins_dir}/bad-plugin" "codex" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "inject_plugin_mcp_config should reject fragment with unquoted string value"
  fi

  if [ -f "${agent_home}/.codex/config.toml" ]; then
    rm -rf "$tmp_dir"
    fail "Config file should not be created when fragment has unquoted string value"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex injection rejects fragment with unquoted string value"
}

test_inject_mcp_config_codex_rejects_malformed_array() {
  echo "Testing Codex TOML injection rejects fragment with unclosed array value..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local plugins_dir="${tmp_dir}/plugins"
  local agent_home="${tmp_dir}/home"
  mkdir -p "$agent_home"

  # Repro: command = [ without a closing ] is syntactically invalid in TOML
  # and previously slipped through validation because '['* matched the leading '['.
  setup_test_plugin "$plugins_dir" "bad-array-plugin" \
    "codex" $'[mcp_servers.demo]\ncommand = ['

  source_lib
  if inject_plugin_mcp_config "${plugins_dir}/bad-array-plugin" "codex" "$agent_home" 2>/dev/null; then
    rm -rf "$tmp_dir"
    fail "inject_plugin_mcp_config should reject fragment with unclosed array value"
  fi

  if [ -f "${agent_home}/.codex/config.toml" ]; then
    rm -rf "$tmp_dir"
    fail "Config file should not be created when fragment has unclosed array value"
  fi

  rm -rf "$tmp_dir"
  echo "  ✓ Codex injection rejects fragment with unclosed array value"
}

echo "Running MCP plugin loading tests..."
echo

test_inject_mcp_config_claude
test_inject_mcp_config_gemini
test_inject_mcp_config_opencode
test_inject_mcp_config_kilo
test_inject_mcp_config_codex
test_inject_mcp_config_merge
test_inject_mcp_config_invalid_json
test_no_fragment_for_provider
test_merge_preserves_existing_keys
test_inject_mcp_config_idempotent_json
test_inject_mcp_config_idempotent_codex
test_inject_mcp_config_codex_no_trailing_newline
test_inject_mcp_config_codex_rejects_extra_table
test_inject_mcp_config_codex_rejects_top_level_keys
test_inject_mcp_config_codex_rejects_indented_top_level_keys
test_load_agent_plugins_invalid_name
test_load_agent_plugins_missing_manifest
test_load_agent_plugins_empty_list
test_inject_mcp_config_codex_rejects_unquoted_value
test_inject_mcp_config_codex_rejects_malformed_array

echo
echo "All MCP plugin loading tests passed!"
