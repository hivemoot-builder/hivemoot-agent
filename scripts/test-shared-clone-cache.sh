#!/usr/bin/env bash
# shellcheck disable=SC2034  # github_login/token/etc. are globals read by integration functions.
# Tests for the shared bare-repository reference cache in
# integrations/github/setup.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INTEGRATION_FILE="${REPO_ROOT}/integrations/github/setup.sh"

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TEST_TMP=""
setup_tmp() {
  TEST_TMP="$(mktemp -d)"
}
cleanup_tmp() {
  [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}
trap cleanup_tmp EXIT

# Stub required lib.sh helpers so the integration can be sourced in isolation.
log() { :; }
validate_target_repo() { :; }
_cleanup_files=()

# Reset the source guard so the file can be re-sourced between test cases.
reset_integration() {
  unset HIVEMOOT_INTEGRATION_GITHUB_SETUP_LOADED
  # shellcheck source=integrations/github/setup.sh
  source "$INTEGRATION_FILE"
}

# ── git mock ──────────────────────────────────────────────────────────────────
# Shadow the git command with a function so it is inherited by all subshells
# (including the flock subshell inside _github_clone_with_reference_cache).
#
# Control variables (scalars inherited on subshell fork):
#   MOCK_GIT_EXIT_CODE  — returned by every call (default 0)
#   MOCK_GIT_FAIL_AFTER — if set, calls > this number fail (1-based)
#   MOCK_GIT_CALLS_FILE — path to file that receives one line per call

MOCK_GIT_EXIT_CODE=0
MOCK_GIT_FAIL_AFTER=""
MOCK_GIT_CALLS_FILE=""

git() {
  local call_num=0
  if [ -n "${MOCK_GIT_CALLS_FILE:-}" ]; then
    printf '%s\n' "$*" >> "$MOCK_GIT_CALLS_FILE"
    call_num="$(wc -l < "$MOCK_GIT_CALLS_FILE")"
  fi
  if [ -n "${MOCK_GIT_FAIL_AFTER:-}" ] && [ "$call_num" -gt "$MOCK_GIT_FAIL_AFTER" ]; then
    return 1
  fi
  return "${MOCK_GIT_EXIT_CODE:-0}"
}

setup_mock() {
  MOCK_GIT_CALLS_FILE="${TEST_TMP}/git-calls.log"
  : > "$MOCK_GIT_CALLS_FILE"
  MOCK_GIT_EXIT_CODE=0
  MOCK_GIT_FAIL_AFTER=""
}

assert_called_with() {
  local pattern="$1"
  grep -qF -- "$pattern" "$MOCK_GIT_CALLS_FILE" \
    || fail "expected git call matching '${pattern}'; actual calls: $(cat "$MOCK_GIT_CALLS_FILE")"
}

assert_not_called_with() {
  local pattern="$1"
  grep -qF -- "$pattern" "$MOCK_GIT_CALLS_FILE" \
    && fail "unexpected git call matching '${pattern}'; actual calls: $(cat "$MOCK_GIT_CALLS_FILE")"
  return 0
}

# ── tests ────────────────────────────────────────────────────────────────────

test_identity_scope_uses_login() {
  setup_tmp; reset_integration

  github_login="testuser"
  github_token="ghp_doesnotmatter"

  local scope
  scope="$(_github_cache_identity_scope)"
  [ "$scope" = "testuser" ] || fail "expected 'testuser', got '${scope}'"
  pass "identity scope uses github_login when available"
}

test_identity_scope_hashes_token_when_no_login() {
  setup_tmp; reset_integration

  github_login=""
  github_token="mytoken123"

  local scope
  scope="$(_github_cache_identity_scope)"
  # Should be exactly 16 hex chars from sha256sum.
  [ "${#scope}" -eq 16 ] \
    || fail "expected 16-char hash, got '${scope}' (len=${#scope})"
  printf '%s' "$scope" | grep -qE '^[0-9a-f]{16}$' \
    || fail "scope is not a 16-char hex string: '${scope}'"
  pass "identity scope hashes token (16 hex chars) when no login"
}

test_identity_scope_returns_1_when_no_credentials() {
  setup_tmp; reset_integration

  github_login=""
  github_token=""

  if _github_cache_identity_scope; then
    fail "expected return 1 with no credentials"
  else
    pass "identity scope returns 1 when no login and no token"
  fi
}

test_identity_scope_hash_is_deterministic() {
  setup_tmp; reset_integration

  github_login=""
  github_token="stable_token_value"

  local scope1 scope2
  scope1="$(_github_cache_identity_scope)"
  scope2="$(_github_cache_identity_scope)"
  [ "$scope1" = "$scope2" ] \
    || fail "scope not deterministic: '${scope1}' != '${scope2}'"
  pass "identity scope hash is deterministic for the same token"
}

test_clone_creates_mirror() {
  setup_tmp; reset_integration; setup_mock

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50

  local cache_base="${TEST_TMP}/cache"
  local askpass="${TEST_TMP}/askpass"
  touch "$askpass"

  _github_clone_with_reference_cache "$cache_base" "$askpass" \
    || fail "clone_with_reference_cache returned non-zero"

  assert_called_with "clone --bare --mirror"
  assert_called_with "config gc.auto 0"
  assert_called_with "--reference"
  pass "clone_with_reference_cache issues git clone --bare --mirror, sets gc.auto=0, then --reference"
}

test_clone_refreshes_existing_mirror() {
  setup_tmp; reset_integration; setup_mock

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50

  local cache_base="${TEST_TMP}/cache"
  local mirror_dir="${cache_base}/owner/myrepo/alice"
  mkdir -p "$mirror_dir"  # pre-existing mirror
  local askpass="${TEST_TMP}/askpass"
  touch "$askpass"

  _github_clone_with_reference_cache "$cache_base" "$askpass" \
    || fail "clone_with_reference_cache returned non-zero for existing mirror"

  assert_called_with "fetch --prune origin"
  assert_called_with "--reference"
  assert_not_called_with "clone --bare --mirror"
  pass "clone_with_reference_cache refreshes (not recreates) existing mirror"
}

test_clone_fails_open_on_mirror_failure() {
  setup_tmp; reset_integration; setup_mock

  MOCK_GIT_EXIT_CODE=1  # all git calls fail

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50

  local cache_base="${TEST_TMP}/cache"
  local askpass="${TEST_TMP}/askpass"
  touch "$askpass"

  if _github_clone_with_reference_cache "$cache_base" "$askpass"; then
    fail "expected non-zero return when git fails"
  else
    pass "clone_with_reference_cache returns 1 when mirror creation fails"
  fi
}

test_clone_fails_open_on_reference_clone_failure() {
  setup_tmp; reset_integration; setup_mock

  # First git call (bare mirror) succeeds; reference clone fails.
  MOCK_GIT_FAIL_AFTER=1

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50

  local cache_base="${TEST_TMP}/cache"
  local askpass="${TEST_TMP}/askpass"
  touch "$askpass"

  if _github_clone_with_reference_cache "$cache_base" "$askpass"; then
    fail "expected non-zero return when reference clone fails"
  fi

  [ ! -d "$repo_dir" ] \
    || fail "repo_dir should be cleaned up after failed reference clone"
  pass "clone_with_reference_cache returns 1 and cleans up on reference clone failure"
}

test_github_clone_or_sync_uses_cache_when_set() {
  setup_tmp; reset_integration; setup_mock

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50
  GIT_CACHE_DIR="${TEST_TMP}/cache"

  github_clone_or_sync \
    || fail "github_clone_or_sync returned non-zero"

  assert_called_with "--reference"
  unset GIT_CACHE_DIR
  pass "github_clone_or_sync uses reference cache when GIT_CACHE_DIR is set"
}

test_github_clone_or_sync_skips_cache_when_unset() {
  setup_tmp; reset_integration; setup_mock

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50
  unset GIT_CACHE_DIR

  github_clone_or_sync \
    || fail "github_clone_or_sync returned non-zero"

  assert_not_called_with "--reference"
  assert_called_with "clone --single-branch"
  pass "github_clone_or_sync uses direct clone when GIT_CACHE_DIR is unset"
}

test_github_clone_or_sync_fallback_on_cache_failure() {
  setup_tmp; reset_integration; setup_mock

  # All git calls fail — cache fails, fallback direct clone fails too.
  MOCK_GIT_EXIT_CODE=1

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50
  GIT_CACHE_DIR="${TEST_TMP}/cache"

  local stderr_out
  stderr_out="$(github_clone_or_sync 2>&1)" \
    && fail "expected non-zero return when all git fails"

  # Must reach the direct clone fallback path and produce the expected error.
  printf '%s' "$stderr_out" | grep -q "failed to clone" \
    || fail "expected 'failed to clone' in stderr on fallback failure; got: ${stderr_out}"
  unset GIT_CACHE_DIR
  pass "github_clone_or_sync falls back to direct clone when cache fails"
}

test_mirror_dir_is_identity_scoped() {
  setup_tmp; reset_integration; setup_mock

  github_login="bob"
  github_token="ghp_bob"
  target_repo="acme/widget"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50

  local cache_base="${TEST_TMP}/cache"
  local askpass="${TEST_TMP}/askpass"
  touch "$askpass"

  _github_clone_with_reference_cache "$cache_base" "$askpass" \
    || fail "clone_with_reference_cache returned non-zero"

  # Mirror path must contain the identity scope (login = "bob").
  grep -q "acme/widget/bob" "$MOCK_GIT_CALLS_FILE" \
    || fail "expected identity-scoped mirror path acme/widget/bob; got: $(cat "$MOCK_GIT_CALLS_FILE")"
  pass "mirror directory is scoped to identity (acme/widget/bob)"
}

test_mirror_dir_uses_hash_for_app_token() {
  setup_tmp; reset_integration; setup_mock

  # No login → identity scope is a token hash.
  github_login=""
  github_token="app_token_xyz"
  target_repo="acme/widget"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=50

  local cache_base="${TEST_TMP}/cache"
  local askpass="${TEST_TMP}/askpass"
  touch "$askpass"

  _github_clone_with_reference_cache "$cache_base" "$askpass" \
    || fail "clone_with_reference_cache returned non-zero"

  # Mirror path must contain a 16-char hex hash, not the raw token.
  local calls
  calls="$(cat "$MOCK_GIT_CALLS_FILE")"
  printf '%s' "$calls" | grep -qE 'acme/widget/[0-9a-f]{16}' \
    || fail "expected 16-char hex scope in mirror path; got: ${calls}"
  pass "mirror directory uses token hash as identity scope for app tokens"
}

test_clone_depth_passed_to_reference_clone() {
  setup_tmp; reset_integration; setup_mock

  github_login="alice"
  github_token="ghp_test"
  target_repo="owner/myrepo"
  repo_dir="${TEST_TMP}/repo"
  clone_depth=25  # non-default depth

  local cache_base="${TEST_TMP}/cache"
  local askpass="${TEST_TMP}/askpass"
  touch "$askpass"

  _github_clone_with_reference_cache "$cache_base" "$askpass" \
    || fail "clone_with_reference_cache returned non-zero"

  grep -q "\-\-depth 25" "$MOCK_GIT_CALLS_FILE" \
    || fail "expected --depth 25 in reference clone; got: $(cat "$MOCK_GIT_CALLS_FILE")"
  pass "clone depth is passed to the reference clone"
}

# ── run all ──────────────────────────────────────────────────────────────────

echo "Running shared clone cache tests"

test_identity_scope_uses_login
test_identity_scope_hashes_token_when_no_login
test_identity_scope_returns_1_when_no_credentials
test_identity_scope_hash_is_deterministic
test_clone_creates_mirror
test_clone_refreshes_existing_mirror
test_clone_fails_open_on_mirror_failure
test_clone_fails_open_on_reference_clone_failure
test_github_clone_or_sync_uses_cache_when_set
test_github_clone_or_sync_skips_cache_when_unset
test_github_clone_or_sync_fallback_on_cache_failure
test_mirror_dir_is_identity_scoped
test_mirror_dir_uses_hash_for_app_token
test_clone_depth_passed_to_reference_clone

echo "PASS: all shared clone cache tests passed (14 tests)"
