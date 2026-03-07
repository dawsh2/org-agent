# Project Name

## Build rules (CRITICAL)

- Only check your own module: `<build-command> <module>`.
- Do NOT run workspace-wide commands.

## Git rules

- Do NOT commit unless explicitly asked.
- Do NOT use `git stash`.
- Do NOT amend existing commits.
- Stay within your assigned scope. Discoveries outside scope: report them, don't fix them.

## Agent workflow & operations

Task decomposition and dispatch use org-agent — an Emacs minor mode
that binds agents to org-mode headings in `TODO.org`.

**Key idea:** The org tree is the persistent state, not any terminal session.

**Do NOT edit `TODO.org` directly.** Always use `emacsclient` functions.

### Workflow states

`TODO` → `NEXT` → `DONE`

- **TODO**: planning/decomposition. Edit access (for merge resolution).
- **NEXT**: execution. Edit access + worktree isolation.
- **DONE**: complete. Session auto-terminated on clean merge.

### Spawning child agents

```bash
# Add a child heading (TODO = needs decomposition, NEXT = ready to execute)
emacsclient -e '(org-agent-add-child "A-1" "[A-1a] Child title" "NEXT")'

# Dispatch an agent on a heading
emacsclient -e '(org-agent-dispatch "A-1a")'

# Create + dispatch in one shot
emacsclient -e '(progn (org-agent-add-child "A-1" "[A-1a] Implement foo" "NEXT") (org-agent-dispatch "A-1a"))'

# Batch-dispatch multiple headings
emacsclient -e '(org-agent-dispatch-batch (list "A-1a" "A-1b" "A-1c"))'
```

### Message passing

All messaging goes through `emacsclient`. Works from any CWD.

```bash
# Send a live message (always pass t as 3rd arg)
emacsclient -e '(org-agent-send "A-1" "Your message here." t)'

# Add a persistent note (survives session restarts)
emacsclient -e '(org-agent-add-note "A-1" "Note text here.")'

# Read another heading's subtree
emacsclient -e '(org-agent-read-subtree "A-1")'

# Mark a heading done
emacsclient -e '(org-agent-mark-done "A-1")'

# Set arbitrary state
emacsclient -e '(org-agent-set-state "A-1" "NEXT")'
```

### Git & worktree model

**NEXT agents** get isolated worktrees on dedicated branches. They do not commit
manually — the NEXT→DONE hook auto-commits.

**TODO agents** own merge. The TODO→DONE hook merges all DONE children's branches.
On conflict, the parent stays TODO until resolved.

**Decomposition discipline:** Disjoint file sets per child. When overlap is
unavoidable: shared type changes go first as a single child, when in doubt sequence.
