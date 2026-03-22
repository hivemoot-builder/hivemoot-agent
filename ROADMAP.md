# Roadmap

Current architecture direction for hivemoot-agent, organized by phase.
Phases align 1:1 with sub-issues #16–#20 from the multi-repo
discussion (#6).

## Phase 0: Foundation (shipped)

The core runtime is functional: Docker container runs up to 10 agents
in parallel against a single target repo, with per-agent isolation,
multi-provider support, and CI with security scanning.

- Multi-provider CLI support (Claude, Codex, Gemini, Kilo, OpenCode)
- Per-agent workspace, home directory, and log isolation
- One-shot and loop run modes with mention watching
- ShellCheck, Hadolint, Trivy security scanning in CI
- Role-based prompting via hivemoot CLI

## Phase 1: Worker boundary hardening — #16

Make `run-once.sh` a proper ephemeral worker: one repo, one job,
clean exit. This is the foundation for the controller architecture
and the highest-value security improvement.

- Add `JOB_ID` parameter to namespace all runtime state
- Workspace and `HOME` scoped by `repo + job_id`
- Selective auth seeding: copy only provider credentials,
  not conversation caches or session state
- Per-job cleanup on exit (workspace, tmp files, provider caches)
- Threat model / isolation docs: document multi-repo-in-one-container
  as a non-boundary and the recommended ephemeral worker model

## Phase 2: Controller MVP — #17

External orchestrator that spawns fresh worker containers per job,
replacing in-container multi-agent orchestration for production and
multi-tenant deployments.

- Scheduler reads config and spawns `docker run` per job
- PAT-based auth initially
- Runs on host (no docker.sock exposure)
- Concurrency control via container lifecycle (replaces flock)

Depends on: Phase 1

## Phase 3: Repo-scoped credentials — #18

GitHub App installation tokens minted per repo per job, replacing
long-lived PATs for multi-tenant deployments.

- Controller mints installation tokens with repo scope
- 1-hour TTL limits blast radius
- Max recommended `AGENT_TIMEOUT_SECONDS` of 3000s with App tokens
- PAT path preserved for local/dev fallback

Depends on: Phase 2

## Phase 4: Worker security hardening — #19

Runtime security constraints for worker containers.

- Seccomp profiles and `--cap-drop=ALL` policy
- Optional gVisor support (with documented I/O performance tradeoffs)
- Per-worker resource limits (CPU, memory, pids)

Depends on: Phase 2

## Phase 5: Containerized controller — #20

Production deployment of the controller itself.

- Containerized controller with restricted launcher API
- Depends on: Phase 1, Phase 2

## Design principles

- **The worker container is the security boundary.** Path-level
  separation within a container is not a tenant isolation mechanism.
- **Ephemeral over long-lived.** Workers should run one job and exit.
  State lives in external storage, not in running containers.
- **Simple before flexible.** Ship shell scripts first, rewrite in
  a richer language only when shell becomes the bottleneck.
- **Both paths coexist.** In-container orchestration (`run-multi.sh`,
  `run-loop.sh`) stays supported for single-operator setups. The
  controller is for production multi-tenant deployments.

## Open questions

- Should `run-multi.sh` / `run-loop.sh` be deprecated once the
  controller ships, or maintained as a simpler alternative?
- Controller language: shell script for consistency, or something
  with better process management (Python, Go, Node)?
- Should App tokens be required in controller mode, or should
  workers accept both token types?

Discussion: #6 | Sub-issues: #16, #17, #18, #19, #20
