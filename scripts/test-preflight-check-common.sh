#!/usr/bin/env bash
# Tests for preflight_check_common() in lib.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# ── Shared setup ─────────────────────────────────────────────────────

# Create a temp workdir with the minimal structure preflight_check_common needs.
# Uses the system temp dir — no exec-capable filesystem required since no
# mock binaries are written here.
setup_workdir() {
  local workdir
  workdir="$(mktemp -d)"
  mkdir -p "${workdir}/skills"
  printf 'prompt\n' > "${workdir}/prompt.md"
  echo "$workdir"
}

# Source lib.sh under test, then stub out helpers that live in other modules
# or that exercise logic outside preflight_check_common's own scope.
# CLI tools (gh, claude, hivemoot) are stubbed as shell functions so no
# exec-capable filesystem is required.
load_lib() {
  # Force a fresh load even if HIVEMOOT_LIB_LOADED is set in the caller's
  # environment; without this the guard in lib.sh returns early and
  # preflight_check_common is never defined.
  unset HIVEMOOT_LIB_LOADED
  # shellcheck source=scripts/lib.sh
  . "${SCRIPT_DIR}/lib.sh"

  # log is defined per-script in the real runtime; provide a stub here.
  log() { :; }

  # Override lib.sh-defined helpers that we want to stub for these tests.
  # Defined after sourcing so they shadow the real implementations.
  resolve_companion_base_prompt() { return 0; }
  prompt_requires_companion_base() { return 1; }
  # preflight_check_provider_auth: accept all providers (auth is tested separately)
  preflight_check_provider_auth() { return 0; }
  # preflight_check_agent_skill_lists: lives in lib-slots.sh; stub here
  preflight_check_agent_skill_lists() { return 0; }

  # Stub CLI tools as shell functions so tests run on any filesystem mount,
  # including noexec worktrees.  preflight_check_common uses `command -v` to
  # probe for these names; bash resolves shell functions via `command -v`, so
  # defining them here makes the existence checks pass without any real binary.
  gh() {
    # Default: accepts user tokens, installation tokens, and repo access.
    if [ "${1:-}" != "api" ]; then return 1; fi
    case "${2:-}" in
      user)         echo '{"login":"mock-user"}' ;;
      installation) echo '{"id":1}' ;;
      repos/*)      printf '{"full_name":"%s"}\n' "${2#repos/}" ;;
      *)            return 1 ;;
    esac
  }
  claude()   { return 0; }
  hivemoot() { return 0; }
}

# Minimal global arrays consumed by preflight_check_common.
make_agent_globals() {
  declare -ga agent_ids=("agent1")
  declare -ga agent_tokens=("tok1")
}

# ── Test cases ───────────────────────────────────────────────────────

test_passes_with_valid_inputs() {
  local workdir
  workdir="$(setup_workdir)"
  trap 'rm -rf "$workdir"' EXIT

  load_lib
  make_agent_globals

  if ! preflight_check_common \
      "claude" "auto" "${workdir}/prompt.md" \
      "owner/repo" "0" "0" \
      "${workdir}/skills" 2>/dev/null
  then
    fail "preflight_check_common should pass with valid inputs"
  fi

  pass "passes with valid inputs"
  trap - EXIT; rm -rf "$workdir"
}

test_fails_missing_provider_cli() {
  local workdir
  workdir="$(setup_workdir)"
  trap 'rm -rf "$workdir"' EXIT

  load_lib
  make_agent_globals

  # Use a provider name that is certainly not installed anywhere.
  local stderr_out
  stderr_out="$(preflight_check_common \
      "no-such-provider-xyz" "auto" "${workdir}/prompt.md" \
      "" "0" "0" \
      "${workdir}/skills" 2>&1 >/dev/null || true)"

  if ! echo "$stderr_out" | grep -q "CLI is not installed"; then
    fail "expected 'CLI is not installed' in stderr; got: ${stderr_out}"
  fi
  if ! echo "$stderr_out" | grep -q "Fix the above errors and retry"; then
    fail "expected retry guidance in stderr; got: ${stderr_out}"
  fi
  if preflight_check_common \
      "no-such-provider-xyz" "auto" "${workdir}/prompt.md" \
      "" "0" "0" \
      "${workdir}/skills" 2>/dev/null
  then
    fail "preflight_check_common should fail when provider CLI is absent"
  fi

  pass "fails when provider CLI is missing"
  trap - EXIT; rm -rf "$workdir"
}

test_fails_missing_prompt_file() {
  local workdir
  workdir="$(setup_workdir)"
  trap 'rm -rf "$workdir"' EXIT

  load_lib
  make_agent_globals

  if preflight_check_common \
      "claude" "auto" "${workdir}/nonexistent.md" \
      "" "0" "0" \
      "${workdir}/skills" 2>/dev/null
  then
    fail "preflight_check_common should fail when prompt file is missing"
  fi

  pass "fails when prompt file is missing"
  trap - EXIT; rm -rf "$workdir"
}

test_requires_hivemoot_cli_when_flag_set() {
  local workdir
  workdir="$(setup_workdir)"
  trap 'rm -rf "$workdir"' EXIT

  load_lib
  make_agent_globals

  # Stub hivemoot to not exist in the search path used by preflight_check_common.
  # We override command -v to report hivemoot as missing.
  command() {
    # shellcheck disable=SC2317  # invoked indirectly via override of the command builtin
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "hivemoot" ]; then return 1; fi
    # shellcheck disable=SC2317
    builtin command "$@"
  }

  if preflight_check_common \
      "claude" "auto" "${workdir}/prompt.md" \
      "" "0" "1" \
      "${workdir}/skills" 2>/dev/null
  then
    unset -f command
    fail "preflight_check_common should fail when hivemoot CLI is missing and require_hivemoot=1"
  fi
  unset -f command

  pass "fails when hivemoot CLI is missing and require_hivemoot=1"
  trap - EXIT; rm -rf "$workdir"
}

test_does_not_require_hivemoot_cli_when_flag_unset() {
  local workdir
  workdir="$(setup_workdir)"
  trap 'rm -rf "$workdir"' EXIT

  load_lib
  make_agent_globals

  # Stub hivemoot to not exist; should not matter when require_hivemoot=0.
  command() {
    # shellcheck disable=SC2317  # invoked indirectly via override of the command builtin
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "hivemoot" ]; then return 1; fi
    # shellcheck disable=SC2317
    builtin command "$@"
  }

  if ! preflight_check_common \
      "claude" "auto" "${workdir}/prompt.md" \
      "" "0" "0" \
      "${workdir}/skills" 2>/dev/null
  then
    unset -f command
    fail "preflight_check_common should pass when hivemoot CLI is missing but require_hivemoot=0"
  fi
  unset -f command

  pass "does not require hivemoot CLI when require_hivemoot=0"
  trap - EXIT; rm -rf "$workdir"
}

test_watch_mentions_rejects_non_user_token() {
  local workdir
  workdir="$(setup_workdir)"
  trap 'rm -rf "$workdir"' EXIT

  load_lib
  make_agent_globals

  # Override gh stub: user endpoint fails, installation endpoint succeeds.
  # Redefined as a function — no file write or exec-capable mount needed.
  gh() {
    if [ "${1:-}" != "api" ]; then return 1; fi
    case "${2:-}" in
      user)         return 1 ;;
      installation) echo '{"id":1}' ;;
      repos/*)      printf '{"full_name":"%s"}\n' "${2#repos/}" ;;
      *)            return 1 ;;
    esac
  }

  if preflight_check_common \
      "claude" "auto" "${workdir}/prompt.md" \
      "" "1" "0" \
      "${workdir}/skills" 2>/dev/null
  then
    fail "preflight_check_common should fail when watch_mentions=1 and token is not a user token"
  fi

  pass "watch_mentions=1 rejects installation-only token"
  trap - EXIT; rm -rf "$workdir"
}

test_return_code_correct_with_many_failures() {
  # Guards against the return-code modulo-256 bug:
  # returning "$failures" when failures == 256 wraps to 0 (success).
  # preflight_check_common must return 1 for any nonzero failure count.
  local workdir
  workdir="$(setup_workdir)"
  trap 'rm -rf "$workdir"' EXIT

  load_lib

  # Redefine after sourcing to inject 255 failures.
  preflight_check_provider_auth() {
    local i; for i in $(seq 1 255); do
      echo "Pre-flight: synthetic failure ${i}" >&2
    done
    return 255
  }

  # Also use a missing provider CLI to get one more failure (256 total).
  make_agent_globals

  # Use a missing provider CLI to contribute one more failure (256 total).
  if preflight_check_common \
      "no-such-provider-xyz" "auto" "${workdir}/prompt.md" \
      "" "0" "0" \
      "${workdir}/skills" 2>/dev/null
  then
    fail "preflight_check_common must return 1 with 256 failures (not 0 via modulo wrap)"
  fi

  pass "return code is 1 regardless of failure count (no modulo-256 wrap)"
  trap - EXIT; rm -rf "$workdir"
}

# ── Run all tests ────────────────────────────────────────────────────

test_passes_with_valid_inputs
test_fails_missing_provider_cli
test_fails_missing_prompt_file
test_requires_hivemoot_cli_when_flag_set
test_does_not_require_hivemoot_cli_when_flag_unset
test_watch_mentions_rejects_non_user_token
test_return_code_correct_with_many_failures

echo "All preflight_check_common tests passed."
