# Vision

## What We're Building

`hivemoot-agent` is infrastructure for autonomous AI teammates. Not code generators.
Not chatbots. Teammates — agents that claim work, reason about tradeoffs, write
code, open PRs, review peers, and iterate under governance rules.

The target state: you configure a GitHub repo, spin up a container, and AI
teammates contribute to it continuously — with the same quality bar, accountability,
and traceability you expect from a human engineer.

## Why This Matters

AI agents today are mostly assistants: they respond to prompts, generate code
on demand, and stop. The missing piece is *agency* — the ability to orient,
prioritize, execute, and own outcomes without constant supervision.

hivemoot-agent exists to close that gap: give agents a runtime that handles
the scaffolding (credentials, isolation, scheduling, logging, governance) so
agents spend their cycles doing real work, not managing infrastructure.

## Core Principles

These are the tradeoffs we commit to when priorities conflict.

**1. Autonomy Over Assistance**
Agents orient themselves, pick their own work, and own outcomes end to end.
We don't build task queues that require human prompts to activate. Agents read
context, decide what's valuable, and act.

**2. Traceability Over Speed**
Every agent action produces a public artifact: a commit, PR, comment, issue, or
review. Nothing happens invisibly. This enables audit, reversal, and team
accountability. A fast agent that leaves no trace is worse than a slow one that does.

**3. Verification Before Shipping**
CI gates (ShellCheck, Hadolint, Trivy, script validation) run on every change.
Agents are expected to run local checks before opening PRs. Skipping verification
to ship faster accumulates debt — the opposite of what this project is for.

**4. Isolation Over Efficiency**
Each agent gets its own workspace, credential scope, home directory, and log stream.
Shared state is a source of races, credential leaks, and hard-to-reproduce bugs.
We accept the overhead of isolation because the failure modes of shared state are worse.

**5. Simplicity Over Features**
Complexity compounds. A new feature that adds permanent maintenance surface must
justify itself against that cost. We reject features that add complexity without
proportional value, even good ideas. The right abstraction is the one nobody
has to think about.

## How We Decide

Apply these in order when evaluating a proposal:

1. **Does it compound or create debt?** Work that simplifies future work is
   preferred over work that defers a problem.

2. **Does it support autonomy?** Changes that require human supervision to work
   are anti-patterns. Agents should run correctly without babysitting.

3. **Is it traceable and reversible?** Prefer actions that can be audited and
   undone. Irreversible or invisible changes need a higher bar.

4. **Is it isolated?** Shared mutable state, cross-agent dependencies, and
   long-lived processes are red flags unless explicitly justified.

5. **Is the complexity earned?** If the simpler version covers 90% of cases,
   ship the simpler version. Add complexity when the remaining 10% is demonstrated,
   not anticipated.

## Architectural Direction

### Current (v1.x): Three-Layer Container Runtime

```
entrypoint.sh
  → run-multi.sh (one-shot) | run-loop.sh (deprecated) | run-task.sh (delegated)
      → run-once.sh (per-agent)
          → Claude | Codex | Gemini | Kilo | OpenCode
```

All agents share one container. Each gets isolated workspace and home directories.
Suitable for personal repos and small teams. Not production-hardened.

### Phase 2 (Active): Host Controller

```
controller.sh (host)
  → docker run (one isolated worker container per job)
      → run-once.sh | run-task.sh
```

The host controller spawns per-job worker containers with hardened flags
(`--cap-drop=ALL`, `--read-only`, resource limits, tmpfs credential homes).
Supports mention-triggered jobs, delegated task claiming, and per-repo mutual
exclusion. This is the active deployment model.

### v2.x: Production Hardening

Priorities before calling hivemoot-agent production-ready:

- **Credential management**: short-lived tokens, rotation, zero-persistence homes
- **Observability**: structured health reports, token usage, run summaries, log tails
- **Security surface**: deny rules covering known exfiltration paths, policy engines
  for each provider, CI assertions that regressions are caught
- **Error semantics**: auth failures and timeouts reported correctly regardless
  of provider exit code behavior
- **Test coverage**: integration tests for task mode, session resume, mention handling

### v3.x: Multi-Agent Coordination

Longer-term directions (not yet designed):

- Multi-repo orchestration from a single controller
- Agent specialization (role-based skill loading)
- Advanced governance (proposal synthesis, voting quorum, cross-repo policy)
- Backend integration for scheduling, dashboards, and fleet management

## What Success Looks Like

**6 months:** A team using hivemoot-agent on a real project ships 80% of routine
PRs through agents. Human engineers review and merge; they spend zero time on
boilerplate, issue triage, or first-pass bug fixes.

**12 months:** hivemoot-agent is production-ready for small-to-medium teams.
Security posture is defensible. Observability is sufficient to diagnose agent
failures without reading raw logs. New providers can be added in under a day.

**The anti-goal:** We are not building a general-purpose AI platform, a coding
assistant, or a CI tool. We are building one thing: infrastructure for AI
teammates that compound project value over time.
