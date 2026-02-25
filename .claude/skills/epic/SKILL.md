---
name: epic
description: Run an epic end-to-end with agent team (analyze, design review, implement, deliver PR)
aliases: [run-epic, start-epic]
---

# Epic Skill

Orchestrate an entire beads epic through a 4-phase workflow: analyze dependencies, design review, implement with HIPAA gates, and deliver a PR.

## Usage

```
/epic EPIC-ID
/epic search terms for epic title
```

## Examples

```
/epic THERAPY-z2q
/epic SOAP note improvements
/epic authentication overhaul
```

## What This Does

The orchestrator (Claude Code) acts as epic manager and coordinates a team of specialized agents through 4 phases:

1. **Analyze** — Planner maps dependency DAG into execution batches, flags HIPAA touchpoints
2. **Design Review** — Reads or creates design doc, presents for user approval
3. **Implement** — Coder + HIPAA reviewer work through batches with quality gates
4. **Deliver** — Creates PR with full traceability (design doc, tasks, HIPAA checklist)

Every phase has a **user approval gate**. No work proceeds without your sign-off.

## Instructions

When the user invokes this skill:

### Step 1: Resolve the Epic

1. Parse the input to determine if it's an epic ID or search term
2. If it looks like an ID (e.g., `THERAPY-z2q`), run `bd show <id>`
3. If it's a search term, run `bd search <term>` to find matching epics
4. If multiple matches, ask the user to select one
5. If no matches, suggest creating a new epic with `bd create`

### Step 2: Check for Resume

1. Read all child tasks of the epic via `bd show`
2. If some tasks are already closed, report: "Resuming epic — N of M tasks already completed"
3. Show which tasks remain open

### Step 3: Launch Epic Team Workflow

**CRITICAL**: Read `.claude/agents/epic-team.md` FIRST before doing anything else. That file defines the full 4-phase workflow, team structure, and agent roles. Execute it as written.

From this point forward, you are the **coordinator, not the doer**. Delegate all research and analysis to agents — do NOT perform deep codebase analysis, file reading, or scoping yourself. Your job is to:
- Create the team (`TeamCreate`)
- Spawn agents with clear prompts
- Present agent findings to the user at each gate
- Manage task status in beads

The 4 phases (all defined in `epic-team.md`):

- **Phase 1: Analyze** — Spawn **planner** (Explore type) to map execution batches, flag HIPAA touchpoints → present findings to user → **Gate 1**
- **Phase 2: Design Review** — Read/create design doc → present to user → **Gate 2**
- **Phase 3: Implement** — Create branch, spawn **coder** + **hipaa-reviewer** → work through batches → **Gate 3**
- **Phase 4: Deliver** — Push, create PR, close tasks, shut down team

### Key Behaviors

- **Orchestrator ≠ researcher**: Spawn agents for analysis. Your inline work should be limited to beads commands, team management, and gate presentations.
- **Session resilience**: If re-invoked on a partially-completed epic, skip closed tasks and resume
- **Scope discipline**: New work discovered during implementation becomes new beads tasks, not scope creep
- **HIPAA non-negotiable**: Any security concern blocks the PR
- **User is always in control**: Every gate requires explicit approval before proceeding
