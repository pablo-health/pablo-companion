# Session Context

## User Prompts

### Prompt 1

audiocapturekit has a v1.0.1 version with the changes - please update and let's resume this feature

### Prompt 2

Base directory for this skill: /Users/kurtn/.claude/skills/continue

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
# → Shows...

