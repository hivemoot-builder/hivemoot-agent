# CLAUDE.md

## What this repo is

hivemoot-agent is a Docker-based runner for autonomous AI agents that contribute to GitHub repos. It supports Claude, Codex, and Gemini providers, runs up to 10 agents in parallel, and provides per-agent isolation (workspace, home dir, credentials, logs).

## Architecture

```text
entrypoint.sh → run-multi.sh → run-once.sh (per agent)
                run-loop.sh  → run-once.sh (periodic + mention-watch)
```

- `scripts/entrypoint.sh` — routes `RUN_MODE` to multi or loop
- `scripts/run-multi.sh` — parallel one-shot execution with shuffled order and jitter
- `scripts/run-loop.sh` — periodic scheduling, mention polling, per-agent locking
- `scripts/run-once.sh` — single agent run: clone, validate, build prompt, invoke provider CLI
- `prompts/default.md` — system prompt injected into every agent run
- `.github/hivemoot.yml` — team roles, governance rules, trusted reviewers

## Development conventions

**Shell scripts** are the primary codebase. All scripts in `scripts/` must:
- Start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Pass ShellCheck with no warnings (CI enforced)
- Use the `log()` function for output: `log "message"` (prefix includes script name and timestamp)
- Use `load_secret_from_file()` in entrypoint/run-once for API key loading (`VAR_FILE` pattern)
- Use `load_slot_token()` in run-multi/run-loop for per-agent GitHub token loading
- Quote all variable expansions

**CI checks** (all must pass):
- ShellCheck on `scripts/*.sh`
- Hadolint on `Dockerfile`
- `docker compose config --quiet` validation
- Env var documentation: every `${VAR}` in `docker-compose.yml` must appear in `.env.example`
- Markdown lint (markdownlint-cli2)
- Docker build + Trivy security scan (CRITICAL/HIGH, ignore-unfixed)

**Dockerfile**: Based on `node:24-slim`. CLI tools installed globally via npm as user `node`. System tools via apt. Tool shims symlinked to `/usr/local/bin` for login shell discovery.

**Env config**: All tunables go in `.env.example` with comments. Use `*_FILE` variants for secrets. Agent slots use `AGENT_ID_XX` / `AGENT_GITHUB_TOKEN_XX` pattern (01-10).

## Key patterns

- **Provider abstraction**: `run-once.sh` has a `case "$provider"` block that maps to each CLI's flags. Claude and Gemini use `run_in_repo=1` (cd into repo before launch). Codex uses `--cd`.
- **Secret handling**: `load_secret_from_file()` (entrypoint, run-once) loads `VAR` from `VAR_FILE` if `VAR` is unset. `load_slot_token()` (run-multi, run-loop) loads per-agent GitHub tokens from `AGENT_GITHUB_TOKEN_XX` or `_FILE`. Secrets go in `./secrets/` mounted read-only at `/run/secrets`.
- **Agent isolation**: Each agent gets `$workspace_root/agents/<id>/repo`, `$workspace_root/runs/<id>/`, `$workspace_root/homes/<id>/` with copied provider auth state.
- **Git auth**: Uses `GIT_ASKPASS` script that returns token from env. No credentials stored in git config.

## When editing scripts

- Run `shellcheck scripts/*.sh` locally before committing
- If adding a new env var to `docker-compose.yml`, also add it to `.env.example`
- If suppressing a Trivy CVE in `.trivyignore`, add a comment with the package, version, and fix version
- Keep the Hadolint ignore list in `.hadolint.yaml` minimal with documented rationale

## Governance

PRs need 2 approvals from trusted reviewers to be merge-ready. Issues go through discussion → voting → implementation phases managed by the hivemoot-bot. Link PRs to issues with `Fixes #N`.

## Commit messages

- Subject under 72 characters
- Brief body explaining why
- No `Co-Authored-By` trailers
