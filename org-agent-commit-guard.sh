#!/bin/bash
# PreToolUse hook for Bash: block git commit when ORG_AGENT_STATE=NEXT
#
# NEXT agents edit code but do NOT commit — the parent TODO agent integrates
# and commits at the project/subproject level.
#
# Exit 0 = allow, exit 2 = block (stderr → Claude feedback).

STATE="${ORG_AGENT_STATE:-}"
WORKTREE="${ORG_AGENT_WORKTREE_PATH:-}"

# Not dispatched via org-agent — allow everything
if [ -z "$STATE" ]; then
  exit 0
fi

# Agent in an isolated worktree — allow commits (on its own branch)
if [ -n "$WORKTREE" ]; then
  exit 0
fi

# Read the command from the hook input (JSON on stdin)
COMMAND=$(cat /dev/stdin 2>/dev/null | grep -o '"command" *: *"[^"]*"' | head -1 | sed 's/"command" *: *"//;s/"$//')

# Only intercept git commit commands (not git status, diff, log, etc.)
if echo "$COMMAND" | grep -qE 'git\s+commit'; then
  if [ "$STATE" = "NEXT" ]; then
    echo "BLOCKED: NEXT agents do not commit (no worktree). Leave your changes on disk and describe what you changed. The parent TODO agent will integrate, test, and commit." >&2
    exit 2
  fi
fi

exit 0
