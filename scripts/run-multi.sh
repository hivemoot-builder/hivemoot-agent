#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[run-multi %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

workspace_root="${WORKSPACE_ROOT:-/workspace}"
email_domain="${AGENT_GIT_EMAIL_DOMAIN:-agents.local}"
global_extra_prompt="${AGENT_EXTRA_PROMPT:-}"
target_repo="${TARGET_REPO:-}"
launch_jitter_min="${LAUNCH_JITTER_MIN_SECS:-120}"
launch_jitter_max="${LAUNCH_JITTER_MAX_SECS:-180}"
max_agents=10
token_tmp_root="/tmp/hivemoot-agent-token-files"

case "$launch_jitter_min" in
  ''|*[!0-9]*) echo "LAUNCH_JITTER_MIN_SECS must be a non-negative integer" >&2; exit 1 ;;
esac
case "$launch_jitter_max" in
  ''|*[!0-9]*) echo "LAUNCH_JITTER_MAX_SECS must be a non-negative integer" >&2; exit 1 ;;
esac
if [ "$launch_jitter_max" -lt "$launch_jitter_min" ]; then
  echo "LAUNCH_JITTER_MAX_SECS (${launch_jitter_max}) must be >= LAUNCH_JITTER_MIN_SECS (${launch_jitter_min})" >&2
  exit 1
fi

validate_target_repo "$target_repo"

declare -a temp_token_files=()
shutdown_requested=0

cleanup_temp_tokens() {
  local path=""
  for path in "${temp_token_files[@]-}"; do
    rm -f "$path" 2>/dev/null || true
  done
}

handle_shutdown() {
  if [ "$shutdown_requested" -eq 0 ]; then
    shutdown_requested=1
    log "Shutdown signal received; stopping new launches, waiting for running agents"
    for pid in "${pids[@]-}"; do
      kill -TERM "$pid" 2>/dev/null || true
    done
  fi
}

trap cleanup_temp_tokens EXIT
trap handle_shutdown TERM INT

shuffle_agents() {
  local i=0
  local j=0
  local tmp_id=""
  local tmp_token=""

  # Fisher-Yates shuffle in place.
  for ((i=${#agent_ids[@]} - 1; i>0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp_id="${agent_ids[i]}"
    tmp_token="${agent_tokens[i]}"
    agent_ids[i]="${agent_ids[j]}"
    agent_tokens[i]="${agent_tokens[j]}"
    agent_ids[j]="$tmp_id"
    agent_tokens[j]="$tmp_token"
  done
}

parse_agent_slots "$max_agents"

mkdir -p "$token_tmp_root"
chmod 700 "$token_tmp_root" 2>/dev/null || true

for slot in $(seq 1 "$max_agents"); do
  suffix="$(printf '%02d' "$slot")"
  unset "AGENT_GITHUB_TOKEN_${suffix}" "AGENT_GITHUB_TOKEN_${suffix}_FILE" || true
done

shuffle_agents

agent_count="${#agent_ids[@]}"
log "Starting ${agent_count} agents in parallel (launch jitter: ${launch_jitter_min}-${launch_jitter_max}s)"
log "Target repo: ${target_repo}"
log "Randomized launch order: ${agent_ids[*]}"

preflight_check 0
prepare_hivemoot_cli

declare -a pids=()
declare -A pid_to_agent=()
declare -A pid_to_wrapper_log=()
launch_index=0

for index in "${!agent_ids[@]}"; do
  agent_id="${agent_ids[$index]}"
  agent_token="${agent_tokens[$index]}"

  if [ "$launch_index" -gt 0 ]; then
    if [ "$shutdown_requested" -ne 0 ]; then
      log "Shutdown requested; skipping launch of ${agent_id}"
      break
    fi
    if [ "$launch_jitter_max" -gt 0 ]; then
      span=$((launch_jitter_max - launch_jitter_min + 1))
      delay=$((launch_jitter_min + RANDOM % span))
      log "Launch jitter before ${agent_id}: ${delay}s"
      sleep "$delay" &
      wait $! || true
      if [ "$shutdown_requested" -ne 0 ]; then
        log "Shutdown requested during jitter; skipping remaining agents"
        break
      fi
    fi
  fi

  token_file="$(mktemp "${token_tmp_root}/${agent_id}.XXXXXX")"
  printf '%s' "$agent_token" > "$token_file"
  chmod 600 "$token_file" 2>/dev/null || true
  temp_token_files+=("$token_file")

  agent_workspace="${workspace_root}/agents/${agent_id}"
  agent_repo="${agent_workspace}/repo"
  agent_log_dir="${workspace_root}/runs/${agent_id}"
  agent_home="${workspace_root}/homes/${agent_id}"
  wrapper_log="${agent_log_dir}/$(date '+%Y%m%d-%H%M%S')-${agent_id}-wrapper.log"

  mkdir -p "$agent_workspace" "$agent_log_dir" "$agent_home"
  chmod 700 "$agent_workspace" "$agent_log_dir" "$agent_home" 2>/dev/null || true

  agent_extra_prompt="$global_extra_prompt"

  : > "$wrapper_log"
  chmod 600 "$wrapper_log" 2>/dev/null || true

  log "Launching agent=${agent_id} repo_dir=${agent_repo} log_dir=${agent_log_dir}"

  # Use a FIFO instead of process substitution to avoid a race condition
  # where early output can be lost before the async subshell opens FDs.
  agent_fifo="${agent_workspace}/output.fifo"
  rm -f "$agent_fifo"
  mkfifo "$agent_fifo"
  sed -u "s/^/[agent:${agent_id}] /" < "$agent_fifo" | tee -a "$wrapper_log" &

  (
    set -euo pipefail
    umask 077

    setup_agent_home "$agent_home"
    export_agent_env "$agent_home" "$agent_workspace" "$agent_repo" \
      "$agent_log_dir" "$token_file" "$agent_id" "$email_domain" "$agent_extra_prompt"

    exec /opt/hivemoot-agent/scripts/run-once.sh
  ) > "$agent_fifo" 2>&1 &

  pid="$!"
  pids+=("$pid")
  pid_to_agent["$pid"]="$agent_id"
  pid_to_wrapper_log["$pid"]="$wrapper_log"
  launch_index=$((launch_index + 1))
done

failures=0
for pid in "${pids[@]}"; do
  agent_id="${pid_to_agent[$pid]}"
  wrapper_log="${pid_to_wrapper_log[$pid]}"

  if wait "$pid" 2>/dev/null; then
    log "Agent ${agent_id} completed successfully"
  else
    exit_code=$?
    if [ "$shutdown_requested" -eq 1 ]; then
      log "Agent ${agent_id} terminated by shutdown"
    else
      failures=$((failures + 1))
      log "Agent ${agent_id} failed (exit=${exit_code}). Wrapper log: ${wrapper_log}"
    fi
  fi
done

if [ "$shutdown_requested" -ne 0 ]; then
  log "Shutdown drain complete"
  exit 0
fi

if [ "$failures" -gt 0 ]; then
  log "Completed with failures: ${failures}/${agent_count}"
  exit 1
fi

log "Completed successfully: ${agent_count}/${agent_count}"
