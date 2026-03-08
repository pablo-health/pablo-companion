# Session Context

## User Prompts

### Prompt 1

/work next epic

### Prompt 2

Base directory for this skill: /Users/kurtn/.claude/skills/work

# Work Skill

Start working on a beads task - automatically creates a git worktree and updates task status.

## Usage

```
/work TASK-ID
/work search terms for task title
```

## Examples

```
/work THERAPY-lo7.1
/work modern frontend setup
/work backend models
```

## What This Does

Claude will:
- Search for the task (ask if multiple matches)
- Create a git worktree with descriptive name
- Update beads status to in_progress
- ...

### Prompt 3

Both - close 107 and do all of 108 spin up agent teams to do in parallel

### Prompt 4

Base directory for this skill: /Users/kurtn/Developer/pablo-companion/.claude/skills/epic

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

The orchestrator (Claude Code) acts as epic manager and coordi...

### Prompt 5

Yes

### Prompt 6

Would it make sense to keep apiclient but have it be a thin wrapper around the rust

### Prompt 7

Yes let’s do it

