#!/usr/bin/env bash
# Unified loop mode: periodic agent runs with optional mention-triggered runs
# via WATCH_MENTIONS=1. Per-agent locks prevent concurrent execution.
set -euo pipefail

log() {
  printf '[run-loop %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

# ── Configuration ──────────────────────────────────────────────────

workspace_root="${WORKSPACE_ROOT:-/workspace}"
email_domain="${AGENT_GIT_EMAIL_DOMAIN:-agents.local}"
global_extra_prompt="${AGENT_EXTRA_PROMPT:-}"
target_repo="${TARGET_REPO:-}"
max_agents=10
token_tmp_root="/tmp/hivemoot-agent-token-files"
lock_dir="/tmp/agent-locks"

# Periodic scheduling (backward compat: fall back to BASE_SECS / JITTER_SECS)
periodic_interval="${PERIODIC_INTERVAL_SECS:-${BASE_SECS:-3600}}"
periodic_jitter="${PERIODIC_JITTER_SECS:-${JITTER_SECS:-300}}"
max_failures="${MAX_CONSECUTIVE_FAILURES:-5}"

# Mention watching (opt-in)
watch_mentions="${WATCH_MENTIONS:-}"
watch_poll_interval="${WATCH_POLL_INTERVAL:-300}"

# Validate numeric settings
for var_name in periodic_interval periodic_jitter max_failures; do
  val="${!var_name}"
  case "$val" in
    ''|*[!0-9]*) echo "${var_name} must be a non-negative integer" >&2; exit 1 ;;
  esac
done

if [ "$periodic_interval" -le 0 ]; then
  echo "PERIODIC_INTERVAL_SECS must be > 0" >&2; exit 1
fi
if [ "$max_failures" -le 0 ]; then
  echo "MAX_CONSECUTIVE_FAILURES must be > 0" >&2; exit 1
fi

if [ "$watch_mentions" = "1" ]; then
  case "$watch_poll_interval" in
    ''|*[!0-9]*) echo "WATCH_POLL_INTERVAL must be a non-negative integer" >&2; exit 1 ;;
  esac
  if [ "$watch_poll_interval" -eq 0 ]; then
    echo "WATCH_POLL_INTERVAL must be > 0" >&2; exit 1
  fi
fi

validate_target_repo "$target_repo"

# ── Agent Slot Parsing ─────────────────────────────────────────────

parse_agent_slots "$max_agents"

agent_count="${#agent_ids[@]}"

# Write tokens to temp files and clear env vars
declare -a temp_token_files=()
mkdir -p "$token_tmp_root"
chmod 700 "$token_tmp_root" 2>/dev/null || true

declare -A agent_token_files=()
for index in "${!agent_ids[@]}"; do
  aid="${agent_ids[$index]}"
  tok="${agent_tokens[$index]}"
  token_file="$(mktemp "${token_tmp_root}/${aid}.XXXXXX")"
  printf '%s' "$tok" > "$token_file"
  chmod 600 "$token_file" 2>/dev/null || true
  temp_token_files+=("$token_file")
  agent_token_files["$aid"]="$token_file"
done

for slot in $(seq 1 "$max_agents"); do
  suffix="$(printf '%02d' "$slot")"
  unset "AGENT_GITHUB_TOKEN_${suffix}" "AGENT_GITHUB_TOKEN_${suffix}_FILE" || true
done

# ── Preflight ──────────────────────────────────────────────────────

if [ "$watch_mentions" = "1" ]; then
  preflight_check 1
else
  preflight_check 0
fi
prepare_hivemoot_cli

# ── Agent Home Setup ──────────────────────────────────────────────

for index in "${!agent_ids[@]}"; do
  aid="${agent_ids[$index]}"
  agent_home="${workspace_root}/homes/${aid}"
  setup_agent_home "$agent_home"
done

# ── Lock & Run Infrastructure ──────────────────────────────────────

mkdir -p "$lock_dir"

# Track all background PIDs for cleanup
declare -a all_bg_pids=()
shutdown_requested=0

# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup() {
  local path=""
  for path in "${temp_token_files[@]-}"; do
    rm -f "$path" 2>/dev/null || true
  done
}

# shellcheck disable=SC2317,SC2329  # invoked via trap
handle_shutdown() {
  if [ "$shutdown_requested" -eq 0 ]; then
    shutdown_requested=1
    log "Shutdown signal received; stopping background processes"
    for pid in "${all_bg_pids[@]-}"; do
      kill -TERM "$pid" 2>/dev/null || true
    done
  fi
}

trap cleanup EXIT
trap handle_shutdown TERM INT

# Try to run an agent with per-agent flock.
# Returns 0 if the agent was busy (lock not acquired) or ran successfully.
# Returns non-zero only on actual run-once.sh failure, allowing callers
# to distinguish between "nothing wrong" and "agent run crashed."
#
# Args: agent_id extra_prompt [ack_key state_file]
# When ack_key + state_file are provided and the run succeeds (exit 0),
# calls `hivemoot ack` to mark the mention as read. On failure the mention
# stays unread so the next poll cycle retries it.
try_run_agent() {
  local agent_id="$1"
  local extra_prompt="$2"
  local ack_key="${3:-}"
  local state_file="${4:-}"
  local lock_file="${lock_dir}/${agent_id}.lock"
  local token_file="${agent_token_files[$agent_id]}"
  local agent_workspace="${workspace_root}/agents/${agent_id}"
  local agent_repo="${agent_workspace}/repo"
  local agent_log_dir="${workspace_root}/runs/${agent_id}"
  local agent_home="${workspace_root}/homes/${agent_id}"

  mkdir -p "$agent_workspace" "$agent_log_dir" "$agent_home"

  (
    flock -n 200 || { log "${agent_id}: busy, skipping"; exit 0; }

    log "${agent_id}: lock acquired, starting run"

    export_agent_env "$agent_home" "$agent_workspace" "$agent_repo" \
      "$agent_log_dir" "$token_file" "$agent_id" "$email_domain" "$extra_prompt"

    agent_exit=0
    /opt/hivemoot-agent/scripts/run-once.sh || agent_exit=$?

    if [ "$agent_exit" -ne 0 ]; then
      log "${agent_id}: run exited with code ${agent_exit}"
    fi

    # Deferred ack: only mark notification as read after a successful run.
    # On failure the mention stays unread so the next poll cycle retries it.
    if [ "$agent_exit" -eq 0 ] && [ -n "$ack_key" ] && [ -n "$state_file" ]; then
      GH_TOKEN="$(cat "$token_file")" hivemoot ack "$ack_key" \
        --state-file "$state_file" || log "${agent_id}: ack failed for ${ack_key}"
    fi

    log "${agent_id}: lock released"
    exit "$agent_exit"
  ) 200>"$lock_file"
}

# ── Mention Watchers (one per agent, only when WATCH_MENTIONS=1) ──

start_mention_watcher() {
  local agent_id="$1"
  local agent_token="${agent_tokens[$2]}"
  local agent_workspace="${workspace_root}/agents/${agent_id}"
  local state_file="${agent_workspace}/watch-state.json"

  mkdir -p "$agent_workspace"

  log "Starting mention watcher for ${agent_id}"

  # Run hivemoot watch in a supervised subshell with restart-on-failure.
  # Backoff resets when the watcher survives longer than 60s (not an immediate crash).
  (
    restart_delay=5
    max_delay=300

    while true; do
      start_time=$SECONDS

      GH_TOKEN="$agent_token" hivemoot watch \
        --repo "$target_repo" \
        --state-file "$state_file" \
        --interval "$watch_poll_interval" 2>&1 | while IFS= read -r line; do

        # Skip non-JSON lines (stderr log messages mixed in)
        if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
          printf '[watcher:%s] %s\n' "$agent_id" "$line" >&2
          continue
        fi

        local thread_id=""
        local number=""
        local title=""
        local author=""
        local body=""
        local url=""

        thread_id="$(printf '%s' "$line" | jq -r '.threadId // empty')"
        number="$(printf '%s' "$line" | jq -r '.number // empty')"
        title="$(printf '%s' "$line" | jq -r '.title // empty')"
        author="$(printf '%s' "$line" | jq -r '.author // empty')"
        body="$(printf '%s' "$line" | jq -r '.body // empty')"
        url="$(printf '%s' "$line" | jq -r '.url // empty')"
        timestamp="$(printf '%s' "$line" | jq -r '.timestamp // empty')"

        log "${agent_id}: mention detected on #${number} by @${author}"

        # Build the extra prompt with mention context
        local mention_prompt="PRIORITY: You were @mentioned on #${number}: \"${title}\".
Mentioned by: @${author}
Comment: \"${body}\"
URL: ${url}

First, react to the comment with a 👀 (eyes) reaction to let the author know you are looking into this.
Then read the full thread, research the topic, and take appropriate action with a meaningful response."

        local combined_prompt="${global_extra_prompt:+${global_extra_prompt}

}${mention_prompt}"

        # Build ack key (threadId:updatedAt) for deferred acknowledgment
        local ack_key=""
        if [ -n "$thread_id" ] && [ -n "$timestamp" ]; then
          ack_key="${thread_id}:${timestamp}"
        fi

        # Try to acquire agent lock and run; pass ack info for deferred mark-read.
        # Redirect stdin from /dev/null so the backgrounded child doesn't inherit
        # the pipe fd — inherited pipe fds can flip to O_NONBLOCK and cause the
        # parent while-read loop to fail with EAGAIN, killing the watcher.
        try_run_agent "$agent_id" "$combined_prompt" "$ack_key" "$state_file" </dev/null &

      done || true  # Don't let pipefail+errexit kill the restart loop

      # Reset backoff if watcher ran for more than 60s (not an immediate crash)
      elapsed=$((SECONDS - start_time))
      if [ "$elapsed" -gt 60 ]; then
        restart_delay=5
      fi

      log "${agent_id}: watcher exited after ${elapsed}s, restarting in ${restart_delay}s"
      sleep "$restart_delay" &
      wait $! || break

      restart_delay=$((restart_delay * 2))
      if [ "$restart_delay" -gt "$max_delay" ]; then
        restart_delay="$max_delay"
      fi
    done
  ) &

  local watcher_pid=$!
  all_bg_pids+=("$watcher_pid")
  log "Mention watcher for ${agent_id} started (pid=${watcher_pid})"
}

# ── Periodic Scheduler ─────────────────────────────────────────────

start_periodic_scheduler() {
  log "Starting periodic scheduler (interval=${periodic_interval}s +/-${periodic_jitter}s)"

  (
    consecutive_failures=0

    # This subshell terminates via SIGTERM from handle_shutdown, not via
    # a shared variable (subshells get a frozen copy of parent state).
    while true; do
      # Sleep first — agents just started, give watchers time to settle
      effective_jitter="$periodic_jitter"
      if [ "$effective_jitter" -ge "$periodic_interval" ]; then
        effective_jitter=$((periodic_interval - 1))
      fi
      min_delay=$((periodic_interval - effective_jitter))
      max_delay=$((periodic_interval + effective_jitter))
      span=$((max_delay - min_delay + 1))
      delay=$((min_delay + RANDOM % span))

      log "Periodic: sleeping ${delay}s before next cycle"
      sleep "$delay" &
      wait $! || true

      log "Periodic: starting cycle for ${agent_count} agents"

      declare -a cycle_pids=()
      for index in "${!agent_ids[@]}"; do
        aid="${agent_ids[$index]}"

        try_run_agent "$aid" "$global_extra_prompt" &
        cycle_pids+=($!)
      done

      # Wait for all agent runs and track results
      cycle_ok=0
      for pid in "${cycle_pids[@]}"; do
        if wait "$pid" 2>/dev/null; then
          cycle_ok=1
        fi
      done

      if [ "$cycle_ok" -eq 1 ]; then
        consecutive_failures=0
        log "Periodic: cycle completed"
      else
        consecutive_failures=$((consecutive_failures + 1))
        log "Periodic: cycle failed (consecutive_failures=${consecutive_failures})"
        if [ "$consecutive_failures" -ge "$max_failures" ]; then
          log "Periodic: reached max consecutive failures (${max_failures}); exiting"
          kill -TERM $$ 2>/dev/null || true
          exit 1
        fi
      fi
    done
  ) &

  local scheduler_pid=$!
  all_bg_pids+=("$scheduler_pid")
  log "Periodic scheduler started (pid=${scheduler_pid})"
}

# ── Main ───────────────────────────────────────────────────────────

log "Loop mode starting: ${agent_count} agents, repo=${target_repo:-unset}"
log "  Periodic interval: ${periodic_interval}s +/-${periodic_jitter}s"
if [ "$watch_mentions" = "1" ]; then
  log "  Mention watching: enabled (poll interval: ${watch_poll_interval}s)"
else
  log "  Mention watching: disabled (set WATCH_MENTIONS=1 to enable)"
fi
log "  Max consecutive failures: ${max_failures}"

# Start mention watchers if enabled
if [ "$watch_mentions" = "1" ]; then
  for index in "${!agent_ids[@]}"; do
    start_mention_watcher "${agent_ids[$index]}" "$index"
  done
fi

# Start periodic scheduler
start_periodic_scheduler

# Wait for all background processes
log "All background processes running. Waiting..."
wait

log "Graceful shutdown complete"
exit 0
