#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329
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

# Create a minimal plugin directory with a plugin.yaml and optional mcp fragments.
# Usage: setup_plugin plugins_dir name [providers...]
# Providers: claude gemini opencode kilo codex
setup_plugin() {
  local plugins_dir="$1" name="$2"
  shift 2

  local plugin_dir="${plugins_dir}/${name}"
  mkdir -p "${plugin_dir}/mcp"

  cat > "${plugin_dir}/plugin.yaml" <<EOF
name: ${name}
version: 1.0.0
description: Test plugin ${name}
EOF

  local provider
  for provider in "$@"; do
    case "$provider" in
      claude)
        printf '{"test-server":{"command":"/usr/bin/echo","args":["claude"]}}' \
          > "${plugin_dir}/mcp/claude.json"
        ;;
      gemini)
        printf '{"test-server":{"command":"/usr/bin/echo","args":["gemini"]}}' \
          > "${plugin_dir}/mcp/gemini.json"
        ;;
      opencode)
        printf '{"test-server":{"type":"local","command":["/usr/bin/echo","opencode"]}}' \
          > "${plugin_dir}/mcp/opencode.json"
        ;;
      kilo)
        printf '{"test-server":{"type":"local","command":["/usr/bin/echo","kilo"]}}' \
          > "${plugin_dir}/mcp/kilo.json"
        ;;
      codex)
        printf '[mcp_servers.test-server]\ncommand = "/usr/bin/echo"\nargs = ["codex"]\n' \
          > "${plugin_dir}/mcp/codex.toml"
        ;;
    esac
  done
}

test_inject_mcp_config_claude() {
  echo "Testing inject_plugin_mcp_config for Claude..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib
  setup_plugin "$tmp_dir/plugins" "myplugin" claude

  inject_plugin_mcp_config "${tmp_dir}/plugins/myplugin" "claude" "$tmp_dir"

  local config_file="${tmp_dir}/.claude.json"
  [ -f "$config_file" ] || fail "claude config not created"

  local value
  value="$(jq -r '.mcpServers["test-server"].command' "$config_file")"
  [ "$value" = "/usr/bin/echo" ] || fail "claude: expected /usr/bin/echo, got: ${value}"

  echo "  ✓ Claude MCP injection works"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_inject_mcp_config_gemini() {
  echo "Testing inject_plugin_mcp_config for Gemini..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib
  setup_plugin "$tmp_dir/plugins" "myplugin" gemini

  inject_plugin_mcp_config "${tmp_dir}/plugins/myplugin" "gemini" "$tmp_dir"

  local config_file="${tmp_dir}/.gemini/settings.json"
  [ -f "$config_file" ] || fail "gemini config not created"

  local value
  value="$(jq -r '.mcpServers["test-server"].command' "$config_file")"
  [ "$value" = "/usr/bin/echo" ] || fail "gemini: expected /usr/bin/echo, got: ${value}"

  echo "  ✓ Gemini MCP injection works"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_inject_mcp_config_opencode() {
  echo "Testing inject_plugin_mcp_config for OpenCode..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib
  setup_plugin "$tmp_dir/plugins" "myplugin" opencode

  inject_plugin_mcp_config "${tmp_dir}/plugins/myplugin" "opencode" "$tmp_dir"

  local config_file="${tmp_dir}/.config/opencode/config.json"
  [ -f "$config_file" ] || fail "opencode config not created"

  local value
  value="$(jq -r '.mcp["test-server"].type' "$config_file")"
  [ "$value" = "local" ] || fail "opencode: expected type=local, got: ${value}"

  echo "  ✓ OpenCode MCP injection works"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_inject_mcp_config_kilo() {
  echo "Testing inject_plugin_mcp_config for Kilo..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib
  setup_plugin "$tmp_dir/plugins" "myplugin" kilo

  inject_plugin_mcp_config "${tmp_dir}/plugins/myplugin" "kilo" "$tmp_dir"

  local config_file="${tmp_dir}/.config/kilo/kilo.json"
  [ -f "$config_file" ] || fail "kilo config not created"

  local value
  value="$(jq -r '.mcp["test-server"].type' "$config_file")"
  [ "$value" = "local" ] || fail "kilo: expected type=local, got: ${value}"

  echo "  ✓ Kilo MCP injection works"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_inject_mcp_config_codex() {
  echo "Testing inject_plugin_mcp_config for Codex..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib
  setup_plugin "$tmp_dir/plugins" "myplugin" codex

  inject_plugin_mcp_config "${tmp_dir}/plugins/myplugin" "codex" "$tmp_dir"

  local config_file="${tmp_dir}/.codex/config.toml"
  [ -f "$config_file" ] || fail "codex config not created"

  grep -qF "[mcp_servers.test-server]" "$config_file" \
    || fail "codex: [mcp_servers.test-server] not found in config"

  echo "  ✓ Codex MCP injection works"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_inject_mcp_config_merge() {
  echo "Testing multi-plugin merge (Claude)..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib

  # Plugin A
  mkdir -p "${tmp_dir}/plugins/plugin-a/mcp"
  cat > "${tmp_dir}/plugins/plugin-a/plugin.yaml" <<'EOF'
name: plugin-a
version: 1.0.0
description: Plugin A
EOF
  printf '{"server-a":{"command":"/bin/a","args":[]}}' \
    > "${tmp_dir}/plugins/plugin-a/mcp/claude.json"

  # Plugin B
  mkdir -p "${tmp_dir}/plugins/plugin-b/mcp"
  cat > "${tmp_dir}/plugins/plugin-b/plugin.yaml" <<'EOF'
name: plugin-b
version: 1.0.0
description: Plugin B
EOF
  printf '{"server-b":{"command":"/bin/b","args":[]}}' \
    > "${tmp_dir}/plugins/plugin-b/mcp/claude.json"

  load_agent_plugins "plugin-a,plugin-b" "${tmp_dir}/plugins" "claude" "$tmp_dir"

  local config_file="${tmp_dir}/.claude.json"
  [ -f "$config_file" ] || fail "claude config not created after multi-plugin load"

  local cmd_a cmd_b
  cmd_a="$(jq -r '.mcpServers["server-a"].command' "$config_file")"
  cmd_b="$(jq -r '.mcpServers["server-b"].command' "$config_file")"

  [ "$cmd_a" = "/bin/a" ] || fail "merge: server-a missing, got: ${cmd_a}"
  [ "$cmd_b" = "/bin/b" ] || fail "merge: server-b missing, got: ${cmd_b}"

  echo "  ✓ Multi-plugin merge preserves all servers"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_inject_mcp_config_invalid_json() {
  echo "Testing rejection of invalid JSON fragment..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib

  mkdir -p "${tmp_dir}/plugins/badplugin/mcp"
  cat > "${tmp_dir}/plugins/badplugin/plugin.yaml" <<'EOF'
name: badplugin
version: 1.0.0
description: Bad plugin
EOF
  printf 'this is not json' > "${tmp_dir}/plugins/badplugin/mcp/claude.json"

  if inject_plugin_mcp_config "${tmp_dir}/plugins/badplugin" "claude" "$tmp_dir" 2>/dev/null; then
    fail "should have rejected invalid JSON fragment"
  fi

  [ ! -f "${tmp_dir}/.claude.json" ] \
    || fail "config file should not exist after invalid fragment rejection"

  echo "  ✓ Invalid JSON fragment is rejected without writing"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_inject_mcp_config_missing_fragment() {
  echo "Testing skip when no fragment for provider..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib

  # Plugin has no claude.json
  mkdir -p "${tmp_dir}/plugins/nofrag/mcp"
  cat > "${tmp_dir}/plugins/nofrag/plugin.yaml" <<'EOF'
name: nofrag
version: 1.0.0
description: Plugin with no Claude fragment
EOF

  inject_plugin_mcp_config "${tmp_dir}/plugins/nofrag" "claude" "$tmp_dir"

  [ ! -f "${tmp_dir}/.claude.json" ] \
    || fail "config should not be created when no fragment exists"

  echo "  ✓ Missing fragment is skipped silently"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_load_agent_plugins_invalid_name() {
  echo "Testing invalid plugin name rejection..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib

  if load_agent_plugins "../escape" "${tmp_dir}/plugins" "claude" "$tmp_dir" 2>/dev/null; then
    fail "should reject plugin name with path traversal"
  fi

  if load_agent_plugins "bad name" "${tmp_dir}/plugins" "claude" "$tmp_dir" 2>/dev/null; then
    fail "should reject plugin name with space"
  fi

  echo "  ✓ Invalid plugin names are rejected"
  trap - EXIT; rm -rf "$tmp_dir"
}

test_codex_idempotency() {
  echo "Testing Codex TOML injection idempotency..."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  source_lib
  setup_plugin "$tmp_dir/plugins" "myplugin" codex

  inject_plugin_mcp_config "${tmp_dir}/plugins/myplugin" "codex" "$tmp_dir"
  inject_plugin_mcp_config "${tmp_dir}/plugins/myplugin" "codex" "$tmp_dir"

  local config_file="${tmp_dir}/.codex/config.toml"
  local count
  count="$(grep -c '\[mcp_servers\.test-server\]' "$config_file")"
  [ "$count" -eq 1 ] || fail "codex idempotency: expected 1 section, found ${count}"

  echo "  ✓ Codex injection is idempotent (second call is a no-op)"
  trap - EXIT; rm -rf "$tmp_dir"
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
test_inject_mcp_config_missing_fragment
test_load_agent_plugins_invalid_name
test_codex_idempotency

echo
echo "All MCP plugin loading tests passed!"
