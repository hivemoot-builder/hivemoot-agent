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

# ── classify_is_quota_auth_failure tests ────────────────────────────────────

echo "Running classify_is_quota_auth_failure tests"

assert_quota() {
  local label="$1"
  local file="$2"
  if ! classify_is_quota_auth_failure "$file"; then
    fail "classify_is_quota_auth_failure: expected MATCH for: ${label}"
  fi
}

assert_not_quota() {
  local label="$1"
  local file="$2"
  if classify_is_quota_auth_failure "$file"; then
    fail "classify_is_quota_auth_failure: expected NO match for: ${label}"
  fi
}

# empty / missing → not quota
assert_not_quota "nonexistent file" "${tmp}/nonexistent-quota"
touch "${tmp}/empty-quota"
assert_not_quota "empty file" "${tmp}/empty-quota"

# quota exhausted (case-insensitive)
printf 'quota exhausted\n' > "${tmp}/q-exhausted"
assert_quota "quota exhausted" "${tmp}/q-exhausted"

printf 'QUOTA EXHAUSTED\n' > "${tmp}/q-exhausted-upper"
assert_quota "quota exhausted (upper)" "${tmp}/q-exhausted-upper"

# TerminalQuotaError (Gemini)
printf 'TerminalQuotaError: daily quota exceeded\n' > "${tmp}/q-terminal"
assert_quota "TerminalQuotaError" "${tmp}/q-terminal"

# 429 Too Many Requests
printf 'HTTP 429 Too Many Requests\n' > "${tmp}/q-429"
assert_quota "429 Too Many Requests" "${tmp}/q-429"

# Codex rate_limit_exceeded
printf '{"type":"error","code":"rate_limit_exceeded"}\n' > "${tmp}/q-rle"
assert_quota "rate_limit_exceeded" "${tmp}/q-rle"

# Codex billing_hard_limit
printf '{"code":"billing_hard_limit_reached"}\n' > "${tmp}/q-billing"
assert_quota "billing_hard_limit" "${tmp}/q-billing"

# authentication failed (case-insensitive)
printf 'Authentication failed: invalid token\n' > "${tmp}/q-auth-fail"
assert_quota "authentication failed" "${tmp}/q-auth-fail"

# auth error
printf 'auth error: credentials rejected\n' > "${tmp}/q-auth-err"
assert_quota "auth error" "${tmp}/q-auth-err"

# token expired
printf 'token expired, please re-authenticate\n' > "${tmp}/q-token-exp"
assert_quota "token expired" "${tmp}/q-token-exp"

# billing
printf 'billing limit reached for this account\n' > "${tmp}/q-billing-generic"
assert_quota "billing" "${tmp}/q-billing-generic"

# unrelated failure → not quota
printf 'Some completely unknown failure\n' > "${tmp}/q-unknown"
assert_not_quota "unknown error" "${tmp}/q-unknown"

printf 'Failed to clone repository\n' > "${tmp}/q-clone"
assert_not_quota "clone failure" "${tmp}/q-clone"

printf 'ANTHROPIC_API_KEY is required\n' > "${tmp}/q-apikey"
assert_not_quota "missing api key" "${tmp}/q-apikey"

echo "All lib-classify.sh tests passed."
