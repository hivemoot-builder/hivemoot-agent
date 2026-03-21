#!/usr/bin/env bash
# Tests for scripts/lib-classify.sh — classify_run_failure_from_file()
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib-classify.sh
. "${SCRIPT_DIR}/lib-classify.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: ${label}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Running lib-classify.sh tests"

# --- empty / missing file ---

assert_eq "" "$(classify_run_failure_from_file "${tmp}/nonexistent")" \
  "nonexistent file → empty"

touch "${tmp}/empty"
assert_eq "" "$(classify_run_failure_from_file "${tmp}/empty")" \
  "empty file → empty"

# --- Kilo provider patterns (checked before standalone provider patterns) ---

printf 'ANTHROPIC_API_KEY is required when KILO_PROVIDER=anthropic.\n' \
  > "${tmp}/kilo-anthropic"
assert_eq \
  "Kilo provider API key (ANTHROPIC_API_KEY) is missing for KILO_PROVIDER=anthropic" \
  "$(classify_run_failure_from_file "${tmp}/kilo-anthropic")" \
  "Kilo anthropic"

printf 'OPENAI_API_KEY is required when KILO_PROVIDER=openai.\n' \
  > "${tmp}/kilo-openai"
assert_eq \
  "Kilo provider API key (OPENAI_API_KEY) is missing for KILO_PROVIDER=openai" \
  "$(classify_run_failure_from_file "${tmp}/kilo-openai")" \
  "Kilo openai"

printf 'GOOGLE_API_KEY is required when KILO_PROVIDER=google.\n' \
  > "${tmp}/kilo-google"
assert_eq \
  "Kilo provider API key (GOOGLE_API_KEY / GEMINI_API_KEY) is missing for KILO_PROVIDER=google" \
  "$(classify_run_failure_from_file "${tmp}/kilo-google")" \
  "Kilo google"

printf 'OPENROUTER_API_KEY is required when KILO_PROVIDER=openrouter.\n' \
  > "${tmp}/kilo-openrouter"
assert_eq \
  "Kilo provider API key (OPENROUTER_API_KEY) is missing for KILO_PROVIDER=openrouter" \
  "$(classify_run_failure_from_file "${tmp}/kilo-openrouter")" \
  "Kilo openrouter"

printf 'KILO_PROVIDER is required — set KILO_PROVIDER or KILOCODE_TOKEN.\n' \
  > "${tmp}/kilo-missing"
assert_eq \
  "KILO_PROVIDER is required — set KILO_PROVIDER or KILOCODE_TOKEN" \
  "$(classify_run_failure_from_file "${tmp}/kilo-missing")" \
  "KILO_PROVIDER missing"

# --- GitHub token patterns ---

printf 'Missing GitHub token for agent.\n' > "${tmp}/gh-missing"
assert_eq \
  "GitHub token is missing" \
  "$(classify_run_failure_from_file "${tmp}/gh-missing")" \
  "Missing GitHub token"

printf 'Failed to validate GitHub token: 401\n' > "${tmp}/gh-validate"
assert_eq \
  "GitHub token validation failed — check token scope or installation access" \
  "$(classify_run_failure_from_file "${tmp}/gh-validate")" \
  "GitHub token validation failed"

printf 'GitHub token cannot access target repository foo/bar\n' > "${tmp}/gh-access"
assert_eq \
  "GitHub token cannot access target repository — check token scope or installation access" \
  "$(classify_run_failure_from_file "${tmp}/gh-access")" \
  "GitHub token access denied"

# --- Clone failure ---

printf 'Failed to clone https://github.com/foo/bar\n' > "${tmp}/clone-fail"
assert_eq \
  "Failed to clone repository — check token and repo access" \
  "$(classify_run_failure_from_file "${tmp}/clone-fail")" \
  "Failed to clone"

# --- Standalone provider key patterns ---

printf 'ANTHROPIC_API_KEY is required\n' > "${tmp}/claude-key"
assert_eq \
  "Claude provider API key (ANTHROPIC_API_KEY) is missing" \
  "$(classify_run_failure_from_file "${tmp}/claude-key")" \
  "ANTHROPIC_API_KEY missing"

printf 'OPENAI_API_KEY is required\n' > "${tmp}/codex-key"
assert_eq \
  "Codex provider API key (OPENAI_API_KEY) is missing" \
  "$(classify_run_failure_from_file "${tmp}/codex-key")" \
  "OPENAI_API_KEY missing"

printf 'GOOGLE_API_KEY (or GEMINI_API_KEY) is required\n' > "${tmp}/gemini-key"
assert_eq \
  "Gemini provider API key (GOOGLE_API_KEY / GEMINI_API_KEY) is missing" \
  "$(classify_run_failure_from_file "${tmp}/gemini-key")" \
  "GOOGLE_API_KEY missing"

# --- Subscription ---

printf 'subscription credentials not found\n' > "${tmp}/sub-creds"
assert_eq \
  "Provider subscription credentials not found — run the matching auth command" \
  "$(classify_run_failure_from_file "${tmp}/sub-creds")" \
  "subscription credentials not found"

printf 'subscription login not found\n' > "${tmp}/sub-login"
assert_eq \
  "Provider subscription credentials not found — run the matching auth command" \
  "$(classify_run_failure_from_file "${tmp}/sub-login")" \
  "subscription login not found"

# --- Git credential helper ---

printf 'Failed to configure git credential helper\n' > "${tmp}/git-cred"
assert_eq \
  "Failed to configure git credentials" \
  "$(classify_run_failure_from_file "${tmp}/git-cred")" \
  "git credential helper"

# --- OpenCode startup errors ---

printf 'opencode CLI is not installed in the container.\n' > "${tmp}/opencode-not-installed"
assert_eq \
  "opencode not installed" \
  "$(classify_run_failure_from_file "${tmp}/opencode-not-installed")" \
  "opencode CLI not installed"

printf 'ZAI_API_KEY is required when OPENCODE_PROVIDER=zai.\n' > "${tmp}/opencode-zai-key"
assert_eq \
  "missing api key for opencode (ZAI)" \
  "$(classify_run_failure_from_file "${tmp}/opencode-zai-key")" \
  "ZAI_API_KEY missing"

printf 'OpenCode auth not configured. Set OPENCODE_PROVIDER + API key, or run: opencode auth login.\n' \
  > "${tmp}/opencode-auth"
assert_eq \
  "opencode auth not configured" \
  "$(classify_run_failure_from_file "${tmp}/opencode-auth")" \
  "OpenCode auth not configured"

# --- CLI-not-installed for remaining providers ---

printf 'kilo CLI is not installed in the container.\n' > "${tmp}/kilo-not-installed"
assert_eq \
  "kilo not installed" \
  "$(classify_run_failure_from_file "${tmp}/kilo-not-installed")" \
  "kilo CLI not installed"

printf 'codex CLI is not installed in the container.\n' > "${tmp}/codex-not-installed"
assert_eq \
  "codex not installed" \
  "$(classify_run_failure_from_file "${tmp}/codex-not-installed")" \
  "codex CLI not installed"

printf 'gemini CLI is not installed in the container.\n' > "${tmp}/gemini-not-installed"
assert_eq \
  "gemini not installed" \
  "$(classify_run_failure_from_file "${tmp}/gemini-not-installed")" \
  "gemini CLI not installed"

printf 'claude CLI is not installed in the container.\n' > "${tmp}/claude-not-installed"
assert_eq \
  "claude not installed" \
  "$(classify_run_failure_from_file "${tmp}/claude-not-installed")" \
  "claude CLI not installed"

# --- Infrastructure dependency errors ---

printf 'HIVEMOOT_BUZZ_ROLE is set but hivemoot CLI is not installed.\n' > "${tmp}/buzz-no-hivemoot"
assert_eq \
  "hivemoot CLI not installed (required for HIVEMOOT_BUZZ_ROLE)" \
  "$(classify_run_failure_from_file "${tmp}/buzz-no-hivemoot")" \
  "hivemoot CLI missing for HIVEMOOT_BUZZ_ROLE"

printf 'HIVEMOOT_BUZZ_ROLE is set but node is not installed for JSON parsing.\n' > "${tmp}/buzz-no-node"
assert_eq \
  "node not installed (required for HIVEMOOT_BUZZ_ROLE)" \
  "$(classify_run_failure_from_file "${tmp}/buzz-no-node")" \
  "node missing for HIVEMOOT_BUZZ_ROLE"

printf 'AGENT_TOOL_OPTIONS_JSON is set but jq is not installed.\n' > "${tmp}/tool-opts-no-jq"
assert_eq \
  "jq not installed (required for AGENT_TOOL_OPTIONS_JSON)" \
  "$(classify_run_failure_from_file "${tmp}/tool-opts-no-jq")" \
  "jq missing for AGENT_TOOL_OPTIONS_JSON"

printf 'AGENT_AVAILABLE_SKILLS is set but the installed Claude CLI does not support --plugin-dir.\n' \
  > "${tmp}/skills-no-plugin-dir"
assert_eq \
  "Claude CLI does not support --plugin-dir (update CLAUDE_CODE_VERSION or unset AGENT_AVAILABLE_SKILLS)" \
  "$(classify_run_failure_from_file "${tmp}/skills-no-plugin-dir")" \
  "Claude CLI plugin-dir not supported"

# --- Unknown error returns empty ---

printf 'Some completely unknown failure\n' > "${tmp}/unknown"
assert_eq "" \
  "$(classify_run_failure_from_file "${tmp}/unknown")" \
  "unknown error → empty"

# --- Kilo pattern takes priority over standalone provider pattern ---
# A file that contains both "when KILO_PROVIDER=anthropic" and "ANTHROPIC_API_KEY
# is required" must produce the Kilo-specific message, not the standalone one.

printf 'ANTHROPIC_API_KEY is required when KILO_PROVIDER=anthropic. Also: ANTHROPIC_API_KEY is required\n' \
  > "${tmp}/kilo-priority"
result="$(classify_run_failure_from_file "${tmp}/kilo-priority")"
if [ "$result" != "Kilo provider API key (ANTHROPIC_API_KEY) is missing for KILO_PROVIDER=anthropic" ]; then
  fail "Kilo pattern must take priority over standalone provider pattern (got: ${result})"
fi

echo "All lib-classify.sh tests passed."
