#!/bin/bash
# PreToolUse hook: block Edit/Write/NotebookEdit when org state != NEXT,
# and enforce per-node file ownership (OWNS_PATHS property).
#
# Exit 0 = allow, exit 2 = block (stderr → Claude feedback).
# When ORG_AGENT_NODE is unset (not dispatched via org-agent), allow all.

NODE="${ORG_AGENT_NODE:-}"

# Not dispatched via org-agent — allow everything
if [ -z "$NODE" ]; then
  exit 0
fi

# Read tool input from stdin (JSON with file_path, etc.)
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4)

# Query live org tree state (env var can go stale after set-state calls)
LIVE_STATE=$(emacsclient -e "(with-current-buffer (org-agent--org-buffer) (save-excursion (goto-char (org-agent--find-heading-by-id \"$NODE\")) (substring-no-properties (or (org-get-todo-state) \"\"))))" 2>/dev/null | tr -d '"')

# If emacsclient fails, fall back to env var
if [ -z "$LIVE_STATE" ]; then
  LIVE_STATE="${ORG_AGENT_STATE:-}"
fi

# Still no state — allow (not managed by org-agent)
if [ -z "$LIVE_STATE" ]; then
  exit 0
fi

# REVIEW, DONE are blocked from editing
if [ "$LIVE_STATE" != "NEXT" ] && [ "$LIVE_STATE" != "TODO" ]; then
  echo "BLOCKED: Your node state is $LIVE_STATE. Only NEXT/TODO agents can modify code." >&2
  exit 2
fi

# ── Path ownership check (NEXT agents) ──
# If the node declares OWNS_PATHS, only those paths are writable.
# OWNS_PATHS is a space-separated list of path prefixes relative to project root.
# Example: ":OWNS_PATHS: crates/bandit-execution/ profiles/spy-surface-ssm/src/main.rs"
# If OWNS_PATHS is unset, all paths are allowed (backward compatible).

if [ -n "$FILE_PATH" ]; then
  PROJECT_ROOT="${ORG_AGENT_WORKTREE_PATH:-${ORG_AGENT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}}"
  PROJECT_ROOT="${PROJECT_ROOT%/}"
  # Fallback: if PROJECT_ROOT is not a prefix of FILE_PATH, use git rev-parse
  case "$FILE_PATH" in
    "$PROJECT_ROOT"*) ;;
    *) PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ;;
  esac
  REL_PATH="${FILE_PATH#$PROJECT_ROOT/}"
  # Worktree paths: strip worktree directory prefix to get true relative path
  # Handles both .org-agent/worktrees/ and .claude/worktrees/ layouts
  case "$REL_PATH" in
    .org-agent/worktrees/*/*)
      REL_PATH="${REL_PATH#.org-agent/worktrees/*/}"
      ;;
    .claude/worktrees/*/*)
      REL_PATH="${REL_PATH#.claude/worktrees/*/}"
      ;;
  esac

  OWNS_PATHS=$(emacsclient -e "(with-current-buffer (org-agent--org-buffer) (save-excursion (goto-char (org-agent--find-heading-by-id \"$NODE\")) (or (org-entry-get nil \"OWNS_PATHS\" t) \"\")))" 2>/dev/null | tr -d '"')

  if [ -n "$OWNS_PATHS" ]; then
    # Check if the file matches any owned path prefix
    ALLOWED=false
    for prefix in $OWNS_PATHS; do
      case "$REL_PATH" in
        $prefix*) ALLOWED=true; break ;;
      esac
    done

    if [ "$ALLOWED" = "false" ]; then
      echo "BLOCKED: [$NODE] does not own '$REL_PATH'. Declared OWNS_PATHS: $OWNS_PATHS" >&2
      exit 2
    fi
  fi

  # ── Child ownership check (TODO/parent agents) ──
  # Block parent from editing files that DONE children modified.
  # Prevents parents from rewriting child work during merge — use git merge instead.
  if [ "$LIVE_STATE" = "TODO" ]; then
    CHILD_OWNER=$(emacsclient -e "
      (with-current-buffer (org-agent--org-buffer)
        (save-excursion
          (goto-char (org-agent--find-heading-by-id \"$NODE\"))
          (let ((parent-level (org-current-level))
                (result nil))
            (save-excursion
              (when (outline-next-heading)
                (while (and (not result)
                            (org-at-heading-p)
                            (> (org-current-level) parent-level))
                  (when (and (= (org-current-level) (1+ parent-level))
                             (member (org-get-todo-state) (quote (\"DONE\" \"NEXT\"))))
                    (let ((child-owns (org-entry-get nil \"OWNS_PATHS\")))
                      (when child-owns
                        (dolist (prefix (split-string child-owns))
                          (when (string-prefix-p prefix \"$REL_PATH\")
                            (setq result (substring-no-properties
                                          (org-get-heading t t t t))))))))
                  (unless (outline-next-heading)
                    (goto-char (point-max))))))
            (or result \"\"))))" 2>/dev/null | tr -d '"')

    if [ -n "$CHILD_OWNER" ] && [ "$CHILD_OWNER" != "" ]; then
      echo "BLOCKED: [$NODE] cannot edit '$REL_PATH' — owned by child: $CHILD_OWNER. Use git merge to integrate child work, not direct edits." >&2
      exit 2
    fi
  fi
fi

exit 0
