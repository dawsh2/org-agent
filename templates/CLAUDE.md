# Project Name

## Agent workflow

Task decomposition and dispatch use org-agent — an Emacs minor mode
that binds AI agents to org-mode headings in TODO.org.

**Key idea:** The org tree is the persistent state, not any terminal session.
Sessions are ephemeral — they can die, run out of context, or be purged.  The
heading survives and re-opening it automatically resumes the prior conversation.

**How it works:**
- Each heading in `TODO.org` = one agent session.
- Parent nodes plan and create child headings; each child gets its own agent with
  ancestor context.  Recursive: planning agents decompose, leaf agents implement.
- Re-opening a node (`C-c C-x s`) automatically resumes via `--resume <uuid>`.
  Purge (`C-c C-x d`) for a fresh start.

**Do NOT edit `TODO.org` directly** with Edit/Write tools.  Always use `emacsclient`
functions (`org-agent-add-child`, `org-agent-add-note`, `org-agent-mark-done`,
`org-agent-set-state`, etc.).  Direct edits corrupt org structure and conflict
with the live Emacs buffer.

**Messaging between agents:**

```bash
# Send a live message to another agent
emacsclient -e '(org-agent-send "A-1" "Your message here." t)'

# Add a persistent note to a heading
emacsclient -e '(org-agent-add-note "A-1" "Note text here.")'

# Read another heading's subtree
emacsclient -e '(org-agent-read-subtree "A-1")'

# Mark a heading done
emacsclient -e '(org-agent-mark-done "A-1")'
```

**Spawning child agents:**

```bash
# Add a child heading
emacsclient -e '(org-agent-add-child "A-1" "[A-1a] Child title" "NEXT")'

# Dispatch an agent on a heading
emacsclient -e '(org-agent-dispatch "A-1a")'

# Batch-dispatch multiple headings
emacsclient -e '(org-agent-dispatch-batch (list "A-1a" "A-1b" "A-1c"))'
```

**Sequential chains** (when a later child needs files from an earlier one):

```bash
emacsclient -e '(org-agent-add-chain "A-1" (list "[A-1a] Define types" "[A-1b] Implement" "[A-1c] Test"))'
```

**Rules:**
- Do NOT use `Task` tool with `isolation: "worktree"` — worktrees are managed by
  org-agent, not by the AI tool's built-in worktree mechanism.
- Do NOT use `git stash`.  Stashing hides work from other agents and the org tree.
- Stay within your heading's scope.  Discoveries outside scope → note for parent.

## Development methodology

<!-- Replace this with your project's methodology -->

## Design principles

<!-- Replace this with your project's design principles -->
