#!/usr/bin/env bash
# Shared utility functions for hivemoot-agent run scripts.
# Sourced by run-multi.sh and run-loop.sh.
#
# Callers must define: log() before sourcing this file.
# shellcheck disable=SC2034  # variables are used by sourcing scripts

# ── String Utilities ──────────────────────────────────────────────

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# ── File & Directory Utilities ────────────────────────────────────

# Copy a provider home path (file or directory) into an agent's home.
seed_provider_home() {
  local shared_path="$1"
  local agent_path="$2"

  if [ ! -e "$shared_path" ]; then
    return 0
  fi

  if [ -d "$shared_path" ]; then
    mkdir -p "$agent_path"
    cp -R "$shared_path"/. "$agent_path"/
  else
    mkdir -p "$(dirname "$agent_path")"
    cp "$shared_path" "$agent_path"
  fi
}

# ── Token Handling ────────────────────────────────────────────────

# Load a GitHub token for a numbered agent slot (e.g. suffix="01").
# Reads from AGENT_GITHUB_TOKEN_XX or AGENT_GITHUB_TOKEN_XX_FILE.
# Prints the token to stdout, or exits on error.
load_slot_token() {
  local suffix="$1"
  local token_var="AGENT_GITHUB_TOKEN_${suffix}"
  local token_file_var="${token_var}_FILE"
  local token="${!token_var:-}"
  local token_file="${!token_file_var:-}"

  if [ -n "$token" ] && [ -n "$token_file" ]; then
    echo "Set either ${token_var} or ${token_file_var}, not both." >&2
    exit 1
  fi

  if [ -z "$token" ] && [ -n "$token_file" ]; then
    if [ ! -f "$token_file" ]; then
      echo "${token_file_var} does not exist: ${token_file}" >&2
      exit 1
    fi
    token="$(tr -d '\r\n' < "$token_file")"
  fi

  printf '%s' "$token"
}

# ── Validation ────────────────────────────────────────────────────

# Validate that TARGET_REPO is set and matches owner/repo format.
# Args: target_repo_value
validate_target_repo() {
  local target_repo="$1"
  if [ -z "$target_repo" ]; then
    echo "TARGET_REPO is required. Set it as owner/repo." >&2
    exit 1
  fi
  if ! printf '%s' "$target_repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    echo "Invalid TARGET_REPO: ${target_repo}. Expected owner/repo." >&2
    exit 1
  fi
}

# ── Agent Slot Parsing ────────────────────────────────────────────

# Parse AGENT_ID_XX and AGENT_GITHUB_TOKEN_XX slots (01..max_agents).
# Populates global arrays: agent_ids, agent_tokens
# Populates global associative array: seen_agents
# Args: max_agents
parse_agent_slots() {
  local max="$1"

  declare -gA seen_agents=()
  declare -ga agent_ids=()
  declare -ga agent_tokens=()

  local slot suffix id_var token_var token_file_var
  local agent_id token_inline token_file agent_token

  for slot in $(seq 1 "$max"); do
    suffix="$(printf '%02d' "$slot")"
    id_var="AGENT_ID_${suffix}"
    token_var="AGENT_GITHUB_TOKEN_${suffix}"
    token_file_var="${token_var}_FILE"

    agent_id="$(trim "${!id_var:-}")"
    token_inline="${!token_var:-}"
    token_file="${!token_file_var:-}"

    if [ -z "$agent_id" ] && [ -z "$token_inline" ] && [ -z "$token_file" ]; then
      continue
    fi

    if [ -z "$agent_id" ]; then
      echo "${id_var} is required when ${token_var} or ${token_file_var} is set." >&2
      exit 1
    fi

    agent_token="$(load_slot_token "$suffix")"
    if [ -z "$agent_token" ]; then
      echo "Missing token for slot ${suffix}. Set ${token_var} or ${token_file_var}." >&2
      exit 1
    fi

    case "$agent_id" in
      ''|*[!a-zA-Z0-9_-]*)
        echo "Invalid agent id: ${agent_id}" >&2
        exit 1
        ;;
    esac

    if [ -n "${seen_agents[$agent_id]:-}" ]; then
      echo "Duplicate agent id detected: ${agent_id}" >&2
      exit 1
    fi
    seen_agents["$agent_id"]=1

    agent_ids+=("$agent_id")
    agent_tokens+=("$agent_token")
  done

  if [ "${#agent_ids[@]}" -eq 0 ]; then
    echo "No agents configured. Set AGENT_ID_01 + AGENT_GITHUB_TOKEN_01 (up to _10)." >&2
    exit 1
  fi
}

# ── Hivemoot CLI ──────────────────────────────────────────────────

# Update or verify the hivemoot CLI is available.
prepare_hivemoot_cli() {
  local update_mode="${HIVEMOOT_CLI_UPDATE:-auto}"
  local spec="@hivemoot-dev/cli@${HIVEMOOT_CLI_VERSION:-latest}"

  if [ "$update_mode" = "skip" ]; then
    log "Pre-run: skipping hivemoot CLI update (HIVEMOOT_CLI_UPDATE=skip)"
  else
    log "Pre-run: updating hivemoot CLI (${spec})"
    npm install -g "$spec"
    hash -r
  fi

  if ! command -v hivemoot >/dev/null 2>&1; then
    echo "hivemoot CLI is not available. Rebuild the image or set HIVEMOOT_CLI_UPDATE=auto." >&2
    exit 1
  fi

  local version_line=""
  version_line="$(hivemoot --version 2>/dev/null | head -n 1 || true)"
  if [ -n "$version_line" ]; then
    log "Pre-run: hivemoot CLI ready (${version_line})"
  else
    log "Pre-run: hivemoot CLI ready"
  fi
}

# ── Agent Home Setup ─────────────────────────────────────────────

# Create the standard home directory structure for an agent and seed
# provider auth state from the shared /home/node paths.
# Args: agent_home source_home
setup_agent_home() {
  local agent_home="$1"
  local source_home="${2:-/home/node}"

  mkdir -p \
    "$agent_home/.config" \
    "$agent_home/.cache" \
    "$agent_home/.local" \
    "$agent_home/.local/share"
  chmod 700 \
    "$agent_home/.config" \
    "$agent_home/.cache" \
    "$agent_home/.local" \
    "$agent_home/.local/share" 2>/dev/null || true

  # Copy shared provider auth state into the agent home
  seed_provider_home "${source_home}/.codex" "$agent_home/.codex"
  seed_provider_home "${source_home}/.gemini" "$agent_home/.gemini"
  seed_provider_home "${source_home}/.claude" "$agent_home/.claude"
  seed_provider_home "${source_home}/.config/claude" "$agent_home/.config/claude"

  # Login shells reset PATH from /etc/profile, losing the Docker ENV
  # that includes the npm global bin directory. Write a .profile so
  # agent subprocesses can find hivemoot and other npm-installed binaries.
  # shellcheck disable=SC2016  # literal ${PATH} intended for .profile
  printf 'export PATH="/usr/local/share/npm-global/bin:${PATH}"\n' \
    > "$agent_home/.profile"
}

# ── Agent Environment ─────────────────────────────────────────────

# Export the standard environment variables for an agent run.
# Args: agent_home agent_workspace agent_repo agent_log_dir
#       token_file agent_id email_domain extra_prompt
export_agent_env() {
  local agent_home="$1"
  local agent_workspace="$2"
  local agent_repo="$3"
  local agent_log_dir="$4"
  local token_file="$5"
  local agent_id="$6"
  local email_domain="$7"
  local extra_prompt="$8"

  unset AGENT_GITHUB_TOKEN GITHUB_TOKEN GH_TOKEN
  export HOME="$agent_home"
  export WORKSPACE_ROOT="$agent_workspace"
  export REPO_DIR="$agent_repo"
  export LOG_DIR="$agent_log_dir"
  export AGENT_GITHUB_TOKEN_FILE="$token_file"
  export AGENT_GIT_NAME="$agent_id"
  export AGENT_GIT_EMAIL="${agent_id}@${email_domain}"
  export HIVEMOOT_BUZZ_ROLE="$agent_id"
  export AGENT_EXTRA_PROMPT="$extra_prompt"
}

# ── Preflight ─────────────────────────────────────────────────────

# Validate provider, auth, prompt, and agent tokens before running.
# Args: require_user_tokens (0 or 1)
# Uses globals: agent_ids, agent_tokens, target_repo (if set in caller)
preflight_check() {
  local require_user_tokens="${1:-0}"
  local failures=0

  log "Pre-flight: validating configuration"

  local provider="${AGENT_PROVIDER:-claude}"
  local auth_mode="${AGENT_AUTH_MODE:-auto}"
  local prompt_file="${AGENT_PROMPT_FILE:-/opt/hivemoot-agent/prompts/default.md}"
  local target_repo="${TARGET_REPO:-}"

  # Provider CLI installed
  if ! command -v "$provider" >/dev/null 2>&1; then
    echo "Pre-flight: ${provider} CLI is not installed in the container." >&2
    failures=$((failures + 1))
  fi

  # hivemoot CLI installed
  if ! command -v hivemoot >/dev/null 2>&1; then
    echo "Pre-flight: hivemoot CLI is not installed." >&2
    failures=$((failures + 1))
  fi

  # Prompt file exists
  if [ ! -f "$prompt_file" ]; then
    echo "Pre-flight: prompt file not found: ${prompt_file}" >&2
    failures=$((failures + 1))
  fi

  # Provider auth check
  case "$provider" in
    codex)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( [ -n "${OPENAI_API_KEY:-}" ] && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
        echo "Pre-flight: OPENAI_API_KEY missing for codex + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    gemini)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( { [ -n "${GOOGLE_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ]; } && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${GOOGLE_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "Pre-flight: GOOGLE_API_KEY/GEMINI_API_KEY missing for gemini + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    claude)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "Pre-flight: ANTHROPIC_API_KEY missing for claude + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
  esac

  # Validate ALL agent tokens against GitHub API
  local index
  for index in "${!agent_ids[@]}"; do
    local aid="${agent_ids[$index]}"
    local tok="${agent_tokens[$index]}"

    if [ "$require_user_tokens" = "1" ]; then
      # Mention watching requires user tokens (for notifications API)
      if ! GH_TOKEN="$tok" gh api user --jq .login >/dev/null 2>&1; then
        echo "Pre-flight: token for agent '${aid}' is not a valid user token (required for WATCH_MENTIONS=1)." >&2
        failures=$((failures + 1))
        continue
      fi
    else
      # Periodic-only mode accepts both user and installation tokens
      if ! GH_TOKEN="$tok" gh api user --jq .login >/dev/null 2>&1; then
        if ! GH_TOKEN="$tok" gh api installation --jq .id >/dev/null 2>&1; then
          echo "Pre-flight: token for agent '${aid}' is invalid or expired." >&2
          failures=$((failures + 1))
          continue
        fi
      fi
    fi

    if [ -n "$target_repo" ]; then
      if ! GH_TOKEN="$tok" gh api "repos/${target_repo}" --jq .full_name >/dev/null 2>&1; then
        echo "Pre-flight: token for agent '${aid}' cannot access ${target_repo}." >&2
        failures=$((failures + 1))
      fi
    fi
  done

  if [ "$failures" -gt 0 ]; then
    echo "Pre-flight: ${failures} check(s) failed. Fix the above errors and retry." >&2
    exit 1
  fi

  log "Pre-flight: all checks passed (provider=${provider} auth=${auth_mode} repo=${target_repo:-unset} agents=${#agent_ids[@]})"
}
