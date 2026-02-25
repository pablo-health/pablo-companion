---
name: work
description: Start working on a beads task (creates worktree, updates status)
aliases: [start, begin]
---

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
- Give you the commands to switch to the worktree

## Instructions

When the user invokes this skill:

1. Parse the input to determine if it's a task ID or search term
2. If search term, use `bd search` to find matching tasks
3. If multiple matches, ask user to select one
4. Get task details with `bd show`
5. Create a descriptive worktree name from the task title
6. Create git worktree: git worktree add ../PROJECT-NAME-description -b TASK-ID-description
7. Symlink gitignored Claude settings into the new worktree so permissions carry over:
   ```bash
   # From the MAIN repo root (not the new worktree)
   MAIN_REPO="$(git rev-parse --show-toplevel)"
   WORKTREE_DIR="../PROJECT-NAME-description"
   # Ensure .claude dir exists in worktree
   mkdir -p "$WORKTREE_DIR/.claude"
   # Symlink settings.local.json (has auto-approve permissions, MCP config, plugins)
   ln -sf "$MAIN_REPO/.claude/settings.local.json" "$WORKTREE_DIR/.claude/settings.local.json"
   ```
8. Update beads: bd update TASK-ID --status=in_progress
9. Show user the cd command to switch to the worktree

## Directory Naming

- Use descriptive name from task title (kebab-case)
- Format: ../therapy-assistant-platform-descriptive-name
- Branch: TASK-ID-descriptive-name

Be friendly and interactive. Ask if anything is unclear.
