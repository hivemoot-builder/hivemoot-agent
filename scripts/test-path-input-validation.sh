#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_fails_with() {
  local expected="$1"
  shift

  local stderr_file
  stderr_file="$(mktemp)"

  if "$@" > /dev/null 2> "$stderr_file"; then
    rm -f "$stderr_file"
    fail "command succeeded unexpectedly: $*"
  fi

  if ! grep -Fqx "$expected" "$stderr_file"; then
    echo "Expected stderr line:" >&2
    echo "  $expected" >&2
    echo "Actual stderr:" >&2
    sed 's/^/  /' "$stderr_file" >&2
    rm -f "$stderr_file"
    fail "stderr mismatch for: $*"
  fi

  rm -f "$stderr_file"
}

echo "Running workspace root and agent ID validation checks"

assert_fails_with \
  "WORKSPACE_ROOT must be an absolute path" \
  env TARGET_REPO=owner/repo WORKSPACE_ROOT=relative bash scripts/run-once.sh

assert_fails_with \
  "WORKSPACE_ROOT must be an absolute path" \
  env TARGET_REPO=owner/repo WORKSPACE_ROOT=relative AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-multi.sh

assert_fails_with \
  "WORKSPACE_ROOT must be an absolute path" \
  env TARGET_REPO=owner/repo WORKSPACE_ROOT=relative AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-loop.sh

assert_fails_with \
  "Invalid AGENT_ID: ." \
  env TARGET_REPO=owner/repo AGENT_ID_01=. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-multi.sh

assert_fails_with \
  "Invalid AGENT_ID: ." \
  env TARGET_REPO=owner/repo AGENT_ID_01=. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-loop.sh

assert_fails_with \
  "Invalid AGENT_ID: .." \
  env TARGET_REPO=owner/repo AGENT_ID_01=.. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-multi.sh

assert_fails_with \
  "Invalid AGENT_ID: .." \
  env TARGET_REPO=owner/repo AGENT_ID_01=.. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-loop.sh

echo "PASS: workspace root and agent ID validation checks"

echo "Running GIT_CLONE_DEPTH validation checks"

assert_fails_with \
  "Unsupported GIT_CLONE_DEPTH: abc. Use 0 (full clone) or a positive integer." \
  env TARGET_REPO=owner/repo GIT_CLONE_DEPTH=abc bash scripts/run-once.sh

assert_fails_with \
  "Unsupported GIT_CLONE_DEPTH: -1. Use 0 (full clone) or a positive integer." \
  env TARGET_REPO=owner/repo GIT_CLONE_DEPTH=-1 bash scripts/run-once.sh

assert_fails_with \
  "Unsupported GIT_CLONE_DEPTH: 1.5. Use 0 (full clone) or a positive integer." \
  env TARGET_REPO=owner/repo GIT_CLONE_DEPTH=1.5 bash scripts/run-once.sh

echo "PASS: GIT_CLONE_DEPTH validation checks"

echo "Running agent slot validation checks"

# Use env -i to prevent inherited AGENT_* vars from the host environment
# from interfering with the "no slots configured" detection.
assert_fails_with \
  "No agents configured. Set AGENT_ID_01 + AGENT_GITHUB_TOKEN_01 (up to _10)." \
  env -i PATH="$PATH" HOME="$HOME" TARGET_REPO=owner/repo bash scripts/run-multi.sh

assert_fails_with \
  "No agents configured. Set AGENT_ID_01 + AGENT_GITHUB_TOKEN_01 (up to _10)." \
  env -i PATH="$PATH" HOME="$HOME" TARGET_REPO=owner/repo bash scripts/run-loop.sh

assert_fails_with \
  "Duplicate agent id detected: worker" \
  env TARGET_REPO=owner/repo \
    AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy \
    AGENT_ID_02=worker AGENT_GITHUB_TOKEN_02=dummy bash scripts/run-multi.sh

assert_fails_with \
  "Duplicate agent id detected: worker" \
  env TARGET_REPO=owner/repo \
    AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy \
    AGENT_ID_02=worker AGENT_GITHUB_TOKEN_02=dummy bash scripts/run-loop.sh

assert_fails_with \
  "AGENT_ID_02 is required when AGENT_GITHUB_TOKEN_02 or AGENT_GITHUB_TOKEN_02_FILE is set." \
  env TARGET_REPO=owner/repo \
    AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy \
    AGENT_GITHUB_TOKEN_02=dummy bash scripts/run-multi.sh

assert_fails_with \
  "AGENT_ID_02 is required when AGENT_GITHUB_TOKEN_02 or AGENT_GITHUB_TOKEN_02_FILE is set." \
  env TARGET_REPO=owner/repo \
    AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy \
    AGENT_GITHUB_TOKEN_02=dummy bash scripts/run-loop.sh

assert_fails_with \
  "Missing token for slot 02. Set AGENT_GITHUB_TOKEN_02 or AGENT_GITHUB_TOKEN_02_FILE." \
  env TARGET_REPO=owner/repo \
    AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy \
    AGENT_ID_02=builder bash scripts/run-multi.sh

assert_fails_with \
  "Missing token for slot 02. Set AGENT_GITHUB_TOKEN_02 or AGENT_GITHUB_TOKEN_02_FILE." \
  env TARGET_REPO=owner/repo \
    AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy \
    AGENT_ID_02=builder bash scripts/run-loop.sh

echo "PASS: agent slot validation checks"
