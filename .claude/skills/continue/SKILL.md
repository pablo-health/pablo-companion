---
name: continue
description: Resume work on current branch's task (infers task from branch name)
aliases: [resume, cont]
---

# Continue Skill

Resume work on the current branch's task - automatically detects task ID from branch name.

## Usage

```
/continue
/resume
```

Automatically detects task ID from current git branch name.
Updates beads status to in_progress if not already started.
Shows task details and checklist.

## Examples

```
# On branch: THERAPY-lo7.1-modern-frontend-setup
/continue
# → Updates THERAPY-lo7.1 to in_progress
# → Shows task details

# On branch: THERAPY-lo7.2-backend-models
/resume
# → Updates THERAPY-lo7.2 to in_progress
```

## Instructions

When the user invokes this skill:

1. Get current git branch name with `git branch --show-current`
2. Parse the branch name to extract task ID (format: TASK-ID-description or just TASK-ID)
   - Look for pattern like THERAPY-xxx or THERAPY-xxx.y
   - Handle formats: THERAPY-lo7.1-modern-frontend, THERAPY-lo7, etc.
3. If no task ID found in branch name, ask user which task they're working on
4. Get task details with `bd show TASK-ID`
5. If task status is not "in_progress", update it: `bd update TASK-ID --status=in_progress`
6. Show task details including:
   - Title
   - Description
   - Current status
   - Any checklist items or subtasks
7. Give encouraging message about what they're working on

Be friendly and helpful. If branch name is unclear, ask what task they're working on.
