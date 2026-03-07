;;; org-agent.el --- Orchestrate AI agents via org-mode headings -*- lexical-binding: t; -*-

;; Author: Bandit Project
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.0") (claude-code "0.4.0") (org "9.7") (org-edna "1.1"))
;; Keywords: tools, ai, org
;; URL: https://github.com/dawsh2/org-agent

;;; Commentary:
;;
;; org-agent binds AI agent sessions to org-mode headings.  Each heading
;; in the task file is one agent session.  Parent headings plan and decompose;
;; child headings execute in isolated git worktrees.  State transitions
;; (TODO → NEXT → DONE) trigger auto-commit, merge, and cascading dispatch.
;;
;; Requires claude-code.el for terminal management.  Supports multiple
;; backends: Claude (anthropic), Codex, z.ai.
;;
;; Quick start:
;;   M-x org-agent-init-project   — set up hooks, dirs, templates
;;   C-c C-x s                    — spawn agent on heading at point
;;   C-c C-x b                    — batch-spawn all NEXT leaves
;;
;; Session persistence: each node gets a stable session UUID stored
;; in the state directory.  Spawning a node with prior history uses
;; `claude --resume <uuid>` so the agent retains full conversation
;; context across Emacs restarts.  Purging (C-c C-x d) deletes the
;; session from disk for a fresh start.
;;
;; State sequence:
;;   TODO → NEXT → | → DONE
;;
;; Keybindings (in org-agent-mode):
;;   C-c C-x s  Spawn agent on heading at point
;;   C-c C-x b  Batch-spawn all NEXT leaves under heading
;;   C-c C-x p  Spawn agent to decompose heading into children
;;   C-c C-x r  Spawn review agent for DONE children
;;   C-c C-x q  Close review/read-only sessions
;;   C-c C-x k  Kill session for heading at point
;;   C-c C-x d  Purge persisted session (fresh start)

;;; Code:

(require 'org)
(require 'org-id)
(require 'cl-lib)
(require 'org-edna)
(require 'json)

(defvar org-agent-data-directory
  (file-name-directory (or load-file-name (locate-library "org-agent") ""))
  "Directory containing org-agent package data files (guard scripts, templates).")

;; claude-code.el is needed at runtime (for term-make etc.) but not at load time.
(declare-function claude-code--term-make "claude-code")
(declare-function claude-code--term-send-string "claude-code")
(declare-function claude-code--term-configure "claude-code")
(declare-function claude-code--term-setup-keymap "claude-code")
(declare-function claude-code--term-customize-faces "claude-code")

;; org-agent-codex.el provides Codex CLI-specific terminal wrappers.
(declare-function org-agent-codex--term-make "org-agent-codex")
(declare-function org-agent-codex--term-send-string "org-agent-codex")
(declare-function org-agent-codex--term-configure "org-agent-codex")
(declare-function org-agent-codex--term-setup-keymap "org-agent-codex")
(declare-function org-agent-codex--term-customize-faces "org-agent-codex")
(declare-function org-agent-codex--find-session-file "org-agent-codex")
(declare-function org-agent-codex--session-file-for-id "org-agent-codex")
(declare-function org-agent-codex--schedule-session-capture "org-agent-codex")

(defvar claude-code-terminal-backend)
(defvar claude-code-start-hook)
(defvar claude-code-event-hook)
(defvar org-agent-codex-event-hook)
(defvar org-capture-templates)
(defvar org-capture-abort)

;; Fix: vterm's term-make calls pop-to-buffer to get window dimensions,
;; then delete-window.  During batch dispatch this churns the user's window
;; layout and can leak terminal content into the previously-focused buffer.
;; Wrapping in save-window-excursion preserves the layout while still giving
;; vterm the temporary window it needs for width detection.
(defun org-agent--term-make-preserve-windows (orig-fn backend buffer-name program &optional switches)
  "Advice around `claude-code--term-make' to preserve window layout.
For the vterm backend, wraps the call in `save-window-excursion' so that
the temporary pop-to-buffer (required for vterm width detection) does not
disrupt the user's window configuration during batch dispatch."
  (if (eq backend 'vterm)
      (save-window-excursion
        (funcall orig-fn backend buffer-name program switches))
    (funcall orig-fn backend buffer-name program switches)))

;;;; Customization

(defgroup org-agent nil
  "Org-mode Claude Code dispatch."
  :group 'org
  :prefix "org-agent-")

(defcustom org-agent-program "claude"
  "Path to the Claude Code CLI."
  :type 'string)

(defcustom org-agent-startup-delay 2.0
  "Seconds to wait after CC starts before sending the prompt."
  :type 'number)

(defcustom org-agent-permission-mode "bypassPermissions"
  "Default CC permission mode for spawned agents.
Choices: \"acceptEdits\", \"default\", \"plan\", \"bypassPermissions\"."
  :type '(choice (const "acceptEdits")
                 (const "default")
                 (const "plan")
                 (const "bypassPermissions")))

(defcustom org-agent-methodology-file nil
  "Path to a methodology markdown file to inject into prompts.
If nil, uses the built-in TDD methodology excerpt."
  :type '(choice (const nil) file))

(defcustom org-agent-workflow-files nil
  "List of file paths whose contents are injected as workflow context.
Each file is read and included under a # Workflow heading in prompts.
Relative paths are resolved from the project root."
  :type '(repeat file))

(defcustom org-agent-use-worktrees t
  "If non-nil, dispatch creates a git worktree per NEXT agent.
Each NEXT agent gets an isolated worktree on its own branch.
On NEXT→DONE the worktree is committed; on TODO→DONE the parent
merges all children's branches."
  :type 'boolean)

(defcustom org-agent-org-filename "TODO.org"
  "Name of the org file containing the task tree."
  :type 'string :group 'org-agent)

(defcustom org-agent-state-directory ".org-agent"
  "Directory (relative to project root) for org-agent state.
Sessions file lives at STATE-DIR/sessions.el."
  :type 'string :group 'org-agent)

(defcustom org-agent-worktree-directory ".org-agent/worktrees"
  "Directory (relative to project root) for git worktrees."
  :type 'string :group 'org-agent)

(defcustom org-agent-instructions-file ".claude/CLAUDE.md"
  "Project instructions file injected into every agent prompt."
  :type 'string :group 'org-agent)

(defcustom org-agent-methodology-fallback-path ".claude/methodology.md"
  "Fallback methodology file when org-agent-methodology-file is nil."
  :type 'string :group 'org-agent)

(defcustom org-agent-pre-commit-formatter nil
  "Shell command to format files before auto-commit.
Run in the worktree directory.  If nil, no formatting is done.
Examples: \"cargo fmt\", \"prettier --write .\", \"black .\""
  :type '(choice (const nil) string) :group 'org-agent)

(defcustom org-agent-merge-formatter nil
  "Shell command to format staged files after merge conflict resolution.
Run in the merge directory.  If nil, no formatting is done."
  :type '(choice (const nil) string) :group 'org-agent)

(defcustom org-agent-backend-programs
  '(("anthropic" . "claude")
    ("codex"     . "codex")
    ("zai"       . nil))  ; nil = use org-agent-program with z.ai env vars
  "Alist mapping backend names to CLI program paths.
Used by `org-agent--resolve-backend' to select the binary
based on the :BACKEND: org property.  A nil program value
means use `org-agent-program' (with backend-specific env vars)."
  :type '(alist :key-type string :value-type (choice string (const nil))))

(defcustom org-agent-default-backend "anthropic"
  "Default backend when no :BACKEND: property is set on the heading or ancestors.
Set to \"codex\" to default all agents to Codex CLI, or \"zai\" for z.ai.
Individual headings can override via :BACKEND: property."
  :type 'string)

(defcustom org-agent-review-backend "codex"
  "Default backend for review agents (C-c C-x r).
Codex excels at code review.  Set to nil to use the heading's
:BACKEND: property or the default anthropic backend."
  :type '(choice string (const nil)))

(defcustom org-agent-auto-activate t
  "If non-nil, auto-activate org-agent-mode in org files under project roots."
  :type 'boolean)

(defcustom org-agent-global-keybindings t
  "If non-nil, bind C-c n and C-c j globally when org-agent-mode activates."
  :type 'boolean :group 'org-agent)

;;;; Backend adapter registry
;;
;; Maps backend names to the correct set of terminal functions.
;; Each entry is a plist with :require (feature to load), :term-make,
;; :term-send-string, :term-configure, :term-setup-keymap,
;; :term-customize-faces, :event-hook, and :find-session-file.

(defvar org-agent-backend-adapters
  `(("anthropic" . (:require claude-code
                    :term-make claude-code--term-make
                    :term-send-string claude-code--term-send-string
                    :term-configure claude-code--term-configure
                    :term-setup-keymap claude-code--term-setup-keymap
                    :term-customize-faces claude-code--term-customize-faces
                    :event-hook claude-code-event-hook
                    :find-session-file nil))
    ("codex"     . (:require org-agent-codex
                    :term-make org-agent-codex--term-make
                    :term-send-string org-agent-codex--term-send-string
                    :term-configure org-agent-codex--term-configure
                    :term-setup-keymap org-agent-codex--term-setup-keymap
                    :term-customize-faces org-agent-codex--term-customize-faces
                    :event-hook org-agent-codex-event-hook
                    :find-session-file org-agent-codex--find-session-file))
    ("zai"       . (:require claude-code
                    :term-make claude-code--term-make
                    :term-send-string claude-code--term-send-string
                    :term-configure claude-code--term-configure
                    :term-setup-keymap claude-code--term-setup-keymap
                    :term-customize-faces claude-code--term-customize-faces
                    :event-hook claude-code-event-hook
                    :find-session-file nil)))
  "Alist mapping backend names to adapter plists.
Each plist provides the function/variable names for terminal operations.")

(defun org-agent--adapter (backend-name key)
  "Look up KEY in the adapter plist for BACKEND-NAME.
Falls back to the anthropic adapter if BACKEND-NAME is unknown."
  (let* ((entry (or (cdr (assoc backend-name org-agent-backend-adapters))
                    (cdr (assoc "anthropic" org-agent-backend-adapters)))))
    (plist-get entry key)))

;;;; Buffer-local backend tracking

(defvar-local org-agent--buffer-backend nil
  "Backend name for the current CC/Codex buffer.
Set by `org-agent--start-cc' so that send-time dispatch can look up
the correct adapter without re-reading the org tree.")

;;;; Hooks

(defcustom org-agent-pre-execute-hook nil
  "Functions called before spawning a CC agent.
Each function receives a plist with :id, :title, :state, :props."
  :type 'hook)

(defcustom org-agent-post-execute-hook nil
  "Functions called when a CC agent completes.
Each function receives a plist with :id, :title, :state, :props, :result."
  :type 'hook)

(defcustom org-agent-state-change-hook nil
  "Functions called on TODO state change.
Each function receives (id old-state new-state)."
  :type 'hook)

;;;; Buffer-local state

(defvar-local org-agent--project-root nil
  "Project root directory.")

(defun org-agent--resolve-project-root ()
  "Return the main repo root, even when called from a worktree.
Worktree .git is a file containing `gitdir: <path>` — chase it
to find the real root.  Falls back to `vc-root-dir' and `default-directory'."
  (let ((root (or org-agent--project-root
                  (vc-root-dir)
                  default-directory)))
    (setq root (expand-file-name root))
    ;; If .git is a file (worktree), chase to main repo
    (let ((dot-git (expand-file-name ".git" root)))
      (when (and (file-exists-p dot-git)
                 (not (file-directory-p dot-git)))
        ;; .git file: "gitdir: /path/to/main/.git/worktrees/<name>"
        (with-temp-buffer
          (insert-file-contents dot-git)
          (when (re-search-forward "gitdir: \\(.+\\)" nil t)
            (let ((gitdir (string-trim (match-string 1))))
              ;; gitdir is like /path/to/main/.git/worktrees/<name>
              ;; Go up past /worktrees/<name> to get /path/to/main/.git
              ;; then up one more for the repo root
              (when (string-match "/\\.git/worktrees/[^/]+$" gitdir)
                (setq root (expand-file-name
                            (substring gitdir 0 (match-beginning 0))))))))))
    (when (file-exists-p root)
      (setq root (file-truename root)))
    root))

(defun org-agent--todo-file (&optional root)
  "Return the authoritative org file path for ROOT or the current project."
  (expand-file-name org-agent-org-filename (or root (org-agent--resolve-project-root))))

(defvar org-agent--canonical-org-buffer nil
  "Cached canonical TODO.org buffer.  Cleared if the buffer dies.")

(defun org-agent--org-buffer ()
  "Return the ONE authoritative TODO.org buffer.
Always returns the same buffer for the main project tree, avoiding
the multiple-buffer problem caused by worktree copies.  Reverts
from disk if the file has changed (non-interactive)."
  (let ((buf org-agent--canonical-org-buffer))
    (when (or (null buf) (not (buffer-live-p buf)))
      (let ((file (org-agent--todo-file)))
        (setq buf (find-file-noselect file))
        (setq org-agent--canonical-org-buffer buf)))
    (with-current-buffer buf
      (unless (bound-and-true-p org-agent-mode)
        (org-agent-mode 1))
      ;; Revert if file changed on disk
      (when (and (buffer-file-name)
                 (file-exists-p (buffer-file-name))
                 (not (verify-visited-file-modtime buf)))
        (revert-buffer t t t)))
    buf))

(defvar-local org-agent--sessions (make-hash-table :test 'equal)
  "Map from heading ID to CC buffer.")

(defvar org-agent--buffer-ready (make-hash-table :test 'equal)
  "Map from CC buffer name to ready state (t = waiting for input).")

(defvar org-agent--message-queue (make-hash-table :test 'equal)
  "Map from CC buffer name to list of pending messages (FIFO order).
Messages are delivered when the agent becomes ready.")

(defvar org-agent--queue-timer nil
  "Timer that drains queued messages when agents become ready.")

(defconst org-agent--queue-poll-interval 2.0
  "Seconds between queue drain attempts.")

(defun org-agent--on-cc-event (message)
  "Handle CC event MESSAGE to track ready/busy state.
CC sends events as plists with :type and :buffer-name.
When an agent becomes ready, any queued messages are delivered."
  (let ((type (plist-get message :type))
        (buf-name (plist-get message :buffer-name)))
    (when buf-name
      (pcase type
        ;; CC is idle / waiting for input
        ("ready"
         (puthash buf-name t org-agent--buffer-ready)
         ;; Drain queue for this buffer immediately
         (org-agent--drain-queue-for buf-name))
        ;; CC started processing
        ("activity" (puthash buf-name nil org-agent--buffer-ready)))))
  ;; Return nil so other hooks can also run
  nil)

(defun org-agent--enqueue-message (buf-name message)
  "Add MESSAGE to the delivery queue for BUF-NAME.
Starts the drain timer if not already running."
  (let ((queue (gethash buf-name org-agent--message-queue)))
    (puthash buf-name (append queue (list message)) org-agent--message-queue))
  (org-agent--ensure-queue-timer)
  (message "org-agent: queued message for %s (agent busy)" buf-name))

(defun org-agent--drain-queue-for (buf-name)
  "Deliver queued messages for BUF-NAME if the agent is ready."
  (let ((queue (gethash buf-name org-agent--message-queue))
        (buf (get-buffer buf-name)))
    (when (and queue buf (buffer-live-p buf)
               (gethash buf-name org-agent--buffer-ready))
      ;; Deliver the first queued message
      (let ((msg (car queue)))
        (puthash buf-name (cdr queue) org-agent--message-queue)
        (with-current-buffer buf
          (let ((send-fn (org-agent--adapter
                          (or org-agent--buffer-backend "anthropic")
                          :term-send-string)))
            (funcall send-fn claude-code-terminal-backend msg)
            (cond
             ((bound-and-true-p vterm--process)
              (process-send-string vterm--process "\C-m"))
             ((bound-and-true-p eat-terminal)
              (eat-self-input 1 ?\C-m)))))
        (message "org-agent: delivered queued message to %s" buf-name)
        ;; Mark as busy — next message waits for next ready event
        (puthash buf-name nil org-agent--buffer-ready))
      ;; Clean up empty queue entries
      (unless (gethash buf-name org-agent--message-queue)
        (remhash buf-name org-agent--message-queue))))
  ;; Stop timer if all queues are empty
  (org-agent--maybe-stop-queue-timer))

(defun org-agent--drain-all-queues ()
  "Attempt to deliver queued messages for all agents.
Called periodically by the queue timer as a fallback in case
ready events are missed."
  (maphash (lambda (buf-name _queue)
             (org-agent--drain-queue-for buf-name))
           (copy-hash-table org-agent--message-queue)))

(defun org-agent--ensure-queue-timer ()
  "Start the queue drain timer if not already running."
  (unless (and org-agent--queue-timer
               (timerp org-agent--queue-timer)
               (memq org-agent--queue-timer timer-list))
    (setq org-agent--queue-timer
          (run-with-timer org-agent--queue-poll-interval
                          org-agent--queue-poll-interval
                          #'org-agent--drain-all-queues))))

(defun org-agent--maybe-stop-queue-timer ()
  "Stop the queue timer if all queues are empty."
  (let ((any-pending nil))
    (maphash (lambda (_k v) (when v (setq any-pending t)))
             org-agent--message-queue)
    (unless any-pending
      (when (and org-agent--queue-timer (timerp org-agent--queue-timer))
        (cancel-timer org-agent--queue-timer)
        (setq org-agent--queue-timer nil)))))

(defun org-agent--buffer-waiting-p (node-id)
  "Return t if the CC session for NODE-ID is waiting for user input."
  (let* ((buf-name (org-agent--cc-buffer-name node-id))
         (buf (get-buffer buf-name)))
    (and buf (buffer-live-p buf)
         (gethash buf-name org-agent--buffer-ready))))

;;;; TODO keywords

(defconst org-agent--todo-keywords
  '("TODO" "NEXT" "DONE")
  "TODO states used by org-agent.")

;;;; Built-in workflow description (injected so agents understand the tree)

(defcustom org-agent-workflow-text nil
  "Custom workflow text for prompt injection.
When non-nil, replaces `org-agent-default-workflow-text' entirely."
  :type '(choice (const nil) string) :group 'org-agent)

(defconst org-agent-default-workflow-text
  "## Tree-Based Agent Workflow

You are one agent in a tree-structured dispatch system.  Each node in an
org-mode tree represents a unit of work.  Your parent node dispatched you
with telescoping context: you see full detail for your own node and parent,
decreasing detail for grandparent and above.

### Your role
- You are a context manager and executor for your node.
- Your session persists across Emacs restarts (via `claude --resume`).
- You are a long-lived manager of this node's scope.

### State lifecycle
  TODO -> NEXT -> | -> DONE
- TODO: needs planning or decomposition into sub-headings
- NEXT: terminal leaf, ready for execution (ONLY state with code edit access)
- DONE: task complete (parent integrates and commits)

### Tool access rules
**Only NEXT agents can modify code.**  If your node has NEXT status, you have
full tool access including Edit, Write, and Bash.  All other agents (TODO,
parent planners, reviewers) are restricted to read-only tools (Read, Glob, Grep)
plus Bash (for emacsclient tree ops) and Task (for research subagents).  This
prevents parent/planning agents from making direct code changes — they must
decompose work into NEXT leaves.

When done, call `org-agent-mark-done` on yourself.  The parent agent
integrates your changes, runs workspace-wide checks, and commits.

### Dispatching child agents
You can spawn persistent child agents via emacsclient.  Each child gets
its own CC session with full telescoping context and workflow injection.

To spawn a single child (by its bracket ID in the org tree):
```bash
emacsclient -e '(org-agent-dispatch \"C-1\")'
```

To spawn multiple children:
```bash
emacsclient -e '(org-agent-dispatch-batch (list \"C-1\" \"C-2\" \"C-3\"))'
```

Each dispatched child:
- Gets a persistent session UUID (survives Emacs restarts)
- Receives ancestor context telescoping from its position in the tree
- Receives this same workflow description so it can dispatch further
- Transitions from NEXT -> ACTIVE automatically
- Opens as an interactive CC terminal in Emacs

### Messaging other agents
Send a prompt to any live agent by node ID:
```bash
emacsclient -e '(org-agent-send \"C-1\" \"Focus on test failures first.\")'
```

Send to multiple children:
```bash
emacsclient -e '(org-agent-send-all (list \"C-1\" \"C-2\") \"Report status.\")'
```

Broadcast to all live agents:
```bash
emacsclient -e '(org-agent-broadcast \"Pause and report status.\")'
```

### Marking yourself done
When your work is complete, mark yourself done:
```bash
emacsclient -e '(org-agent-mark-done \"YOUR-ID\")'
```

**If you are in a worktree** (ORG_AGENT_WORKTREE_PATH is set): your changes
are automatically committed on your branch when you transition to DONE.
You can commit freely during your session — you have an isolated branch.
The parent agent merges your branch when it closes out (TODO→DONE).

**If you are NOT in a worktree**: do not commit.  Leave your changes on
disk and describe what you changed.  The parent agent integrates and commits.

In both cases: DONE captures a :RESULTS: drawer with commit log and
diffstat, notifies the parent, and closes your CC buffer.

**Parent notification:** When you transition to DONE, your parent agent
automatically receives a message like:
  \"Child [X-1a] (task title) is DONE. Progress: 3/5 children DONE.\"
You do NOT need to manually notify your parent — the hook handles it.

### Updating the org tree (CRITICAL: no direct file edits)
NEVER use the Edit or Write tools on TODO.org.  Emacs owns the buffer and
direct disk writes cause revert prompts and data loss.  ALL org mutations
go through emacsclient:

```bash
# Change TODO state
emacsclient -e '(org-agent-set-state \"C-1\" \"DONE\")'

# Add a note/discovery to your heading
emacsclient -e '(org-agent-add-note \"C-1\" \"Found: edge case in X.\")'

# Add a child heading under yours
emacsclient -e '(org-agent-add-child \"C-1\" \"[C-1a] Sub-task title\" \"TODO\")'

# Read your subtree (returns text, avoids reading full file)
emacsclient -e '(org-agent-read-subtree \"C-1\")'

# Mark yourself for review (commits, runs tests, closes buffer)
emacsclient -e '(org-agent-mark-review \"C-1\")'
```

Do NOT read the full TODO.org — it is large and your context file already
contains your subtree and ancestor chain.

### Git commits
When committing code, include your node ID and session ID as trailers:
```
feat(C-1): populate exit_edge_bps for closed trades

Org-Node: C-1
Org-Session: $ORG_AGENT_SESSION
```
The `ORG_AGENT_SESSION` env var contains your persistent session UUID.
This links commits to conversation history for auditability.

### Environment variables
These are set in your shell environment:
- `ORG_AGENT_NODE` — your node ID (e.g. `C-1`)
- `ORG_AGENT_PARENT` — your parent's node ID
- `ORG_AGENT_SESSION` — your persistent session UUID
- `ORG_AGENT_STATE` — your org state (TODO/NEXT/DONE)
- `ORG_AGENT_FILE` — path to the org file
- `ORG_AGENT_ROOT` — project root directory

### When to decompose vs execute locally
- If a subtask is truly atomic (single file, <100 lines, no ambiguity) →
  use Claude Code's Task tool in your own terminal.
- If a subtask needs its own planning, touches multiple files, or could
  benefit from a persistent session → add a child heading via emacsclient
  and dispatch a new agent.  Prefer plan mode for the child if scope is unclear.
- When in doubt, go deeper in the tree.  A child agent that finishes quickly
  costs little.  A monolithic session that runs out of context loses work.
- Do NOT use Task tool with isolation: worktree.  All parallelism comes from
  the org tree.

### Sequential chains (data dependencies between children)
When a later child needs files or types from an earlier one, use `add-chain`
instead of parallel dispatch.  Chain children auto-dispatch in sequence:
the first starts immediately; successors auto-dispatch as predecessors complete.
Each successor's worktree includes all predecessor work.

```bash
emacsclient -e '(org-agent-add-chain \"C-1\" (list \"[C-1a] Define types\" \"[C-1b] Implement\" \"[C-1c] Test\"))'
```

This creates C-1a (NEXT), C-1b (TODO, blocked), C-1c (TODO, blocked) with
org-edna BLOCKER/TRIGGER properties that enforce ordering automatically.
When C-1a goes DONE, C-1b transitions to NEXT and dispatches.

**Default to parallel children.**  Chains are only for true data dependencies
(types defined by A, files written by A that B reads).  Logical ordering
without file dependency → use parallel `dispatch-batch` instead.

### File ownership (OWNS_PATHS)
When a NEXT agent goes DONE, its changed file paths are auto-recorded as
`:OWNS_PATHS:` on its heading.  The edit guard then prevents parent agents
from directly editing those files — parents must use `git merge` to integrate
child work, not rewrite it.  This enforces disjoint file sets.

You can also set OWNS_PATHS manually to scope an agent before dispatch:
```bash
emacsclient -e '(with-current-buffer (org-agent--org-buffer)
  (goto-char (org-agent--find-heading-by-id \"C-1a\"))
  (org-entry-put nil \"OWNS_PATHS\" \"src/auth/\"))'
```

### Coordination rules
- Your subtree and ancestor context are in the task file you were given — do not re-read TODO.org.
- Do NOT modify sibling nodes or ancestor specs.
- Report completion clearly so the parent can mark you DONE.
- If you discover work outside your scope, note it as a discovery for the parent.
- Follow the methodology section for implementation patterns."
  "Default tree-based workflow text injected into every agent prompt.")

;;;; Built-in TDD methodology

(defcustom org-agent-methodology-text nil
  "Custom methodology text for prompt injection.
When non-nil, replaces `org-agent-default-methodology-text' entirely."
  :type '(choice (const nil) string) :group 'org-agent)

(defconst org-agent-default-methodology-text
  "## TDD + Stubs + Smoke Methodology

### Phase 0: Architecture Skeleton
- Define core domain types + trait interfaces
- Add stub implementations for all required interfaces
- Add one golden smoke test
- Exit: project compiles, smoke test passes, no production logic

### Phase 1: Core Correctness
- Implement baseline continuous core
- Add algebraic/property tests for residuals and invariants
- Exit: core tests + smoke tests pass deterministically

### Phase 2: Realizations
- Add execution realization paths
- Add realization-gap tests and escalation policy tests
- Exit: realizations preserve core semantics within defined tolerances

### Guardrails
- Interface tests: no direct policy-to-trade bypass
- Geometry tests: task/null-space decomposition preserved
- Diagnostics tests: required telemetry emitted and consumed
- Deterministic smoke: fixed-seed e2e run reproducible"
  "Built-in TDD methodology excerpt for prompt injection.")

;;;; Inline property parser (ported from claude-tree.el)

(defun org-agent--parse-inline-props (body-text)
  "Parse inline YAML-style properties from BODY-TEXT.
Handles `- \\=`key\\=`: \\=`value\\=`` lines with multi-line continuation.
Returns alist of (key . value) pairs."
  (let ((props nil)
        (lines (split-string body-text "\n"))
        (current-key nil)
        (current-lines nil))
    (dolist (line lines)
      (cond
       ;; New property line: - `key`: ...
       ((string-match "^- `\\([^`]+\\)`: *\\(.*\\)$" line)
        ;; Flush previous property
        (when current-key
          (push (cons current-key
                      (string-trim (mapconcat #'identity
                                              (nreverse current-lines) "\n")))
                props))
        (setq current-key (match-string 1 line))
        (let ((val (string-trim (match-string 2 line))))
          ;; Strip surrounding backticks from simple single-token values
          (when (string-match "^`\\([^`]+\\)`\\.?$" val)
            (setq val (match-string 1 val)))
          (setq current-lines (if (string-empty-p val) nil (list val)))))
       ;; Continuation: indented line while we have a current key
       ((and current-key (string-match "^  +" line))
        (push (string-trim line) current-lines))
       ;; Non-matching, non-blank line ends current property
       ((and current-key
             (not (string-empty-p (string-trim line))))
        (push (cons current-key
                    (string-trim (mapconcat #'identity
                                            (nreverse current-lines) "\n")))
              props)
        (setq current-key nil
              current-lines nil))))
    ;; Flush last property
    (when current-key
      (push (cons current-key
                  (string-trim (mapconcat #'identity
                                          (nreverse current-lines) "\n")))
            props))
    (nreverse props)))

;;;; Heading introspection

(defun org-agent--heading-id ()
  "Extract bracketed ID like [X-N] from heading at point.
Skips org priority cookies like [#A].
Returns the ID string (without brackets) or nil."
  (let ((heading (org-get-heading t t t t)))
    ;; Strip leading priority cookie [#X] if present
    (when (string-match "^\\[#.\\] *" heading)
      (setq heading (substring heading (match-end 0))))
    (when (string-match "^\\[\\([^]]+\\)\\]" heading)
      (match-string 1 heading))))

(defun org-agent--heading-title ()
  "Extract title from heading at point (without [ID] prefix)."
  (let ((heading (org-get-heading t t t t)))
    (string-trim
     (replace-regexp-in-string "^\\[[^]]+\\] *" "" heading))))

(defun org-agent--heading-state ()
  "Return the TODO state of heading at point."
  (org-get-todo-state))

(defun org-agent--heading-body ()
  "Return body text of heading at point (between heading and next heading).
Excludes the heading line and any PROPERTIES drawer."
  (save-excursion
    (org-back-to-heading t)
    (let ((start (save-excursion
                   (org-end-of-meta-data t)
                   (point)))
          (end (save-excursion
                 (outline-next-heading)
                 (point))))
      (when (< start end)
        (string-trim (buffer-substring-no-properties start end))))))

(defun org-agent--heading-context ()
  "Extract full context plist for heading at point.
Returns (:id ID :title TITLE :state STATE :props PROPS :body BODY)."
  (let* ((id (org-agent--heading-id))
         (title (org-agent--heading-title))
         (state (org-agent--heading-state))
         (body (org-agent--heading-body))
         (props (when body (org-agent--parse-inline-props body))))
    (list :id (or id (org-agent--slug-id title))
          :title title
          :state state
          :props props
          :body body)))

(defun org-agent--slug-id (title)
  "Generate a stable slug ID from TITLE."
  (let* ((slug (downcase title))
         (slug (replace-regexp-in-string "[^a-z0-9]+" "-" slug))
         (slug (replace-regexp-in-string "^-+\\|-+$" "" slug)))
    slug))

;;;; Depth-limited ancestor context

(defun org-agent--ancestor-context ()
  "Walk up the heading tree and return ancestor context list.
Each entry is a plist. Depth-limited extraction:
  Self/Parent: full inline props
  Grandparent: scope + acceptance only
  Great-grandparent+: title + ID only"
  (let ((ancestors nil)
        (depth 0))
    (save-excursion
      (condition-case nil
          (while (org-up-heading-safe)
            (let* ((ctx (org-agent--heading-context))
                   (pruned
                    (cond
                     ;; Parent (depth 0): full props
                     ((= depth 0) ctx)
                     ;; Grandparent (depth 1): scope + acceptance only
                     ((= depth 1)
                      (list :id (plist-get ctx :id)
                            :title (plist-get ctx :title)
                            :state (plist-get ctx :state)
                            :props (cl-remove-if-not
                                    (lambda (p) (member (car p) '("scope" "acceptance")))
                                    (plist-get ctx :props))))
                     ;; Great-grandparent+: title + ID only
                     (t (list :id (plist-get ctx :id)
                              :title (plist-get ctx :title))))))
              (push pruned ancestors)
              (cl-incf depth)))
        (error nil)))
    ancestors))

(defun org-agent--subtree-text ()
  "Return org-formatted text of the subtree under heading at point.
Includes all sub-headings with their statuses and body text."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t) (point))))
      ;; Skip the current heading line itself
      (forward-line 1)
      (when (< (point) end)
        (buffer-substring-no-properties (point) end)))))

;;;; Workflow context loading

(defun org-agent--load-file-contents (path)
  "Load and return contents of PATH, or nil if not readable.
Relative paths resolved from `org-agent--project-root'."
  (let ((full-path (if (file-name-absolute-p path)
                       path
                     (expand-file-name path (or org-agent--project-root
                                                default-directory)))))
    (when (file-readable-p full-path)
      (with-temp-buffer
        (insert-file-contents full-path)
        (buffer-string)))))

(defun org-agent--workflow-context ()
  "Assemble workflow context string from project files.
Includes CLAUDE.md and any files in `org-agent-workflow-files'.
Returns a string or nil."
  (let ((parts nil)
        (root (org-agent--resolve-project-root)))
    ;; Always include project instructions if the file exists
    (let ((claude-md (expand-file-name org-agent-instructions-file root)))
      (when (file-readable-p claude-md)
        (push (format "### Project Instructions (CLAUDE.md)\n\n%s"
                      (org-agent--load-file-contents claude-md))
              parts)))
    ;; Include conventions section from the org buffer itself
    (let ((conventions (org-agent--extract-conventions)))
      (when conventions
        (push (format "### Project Conventions\n\n%s" conventions)
              parts)))
    ;; Include any extra workflow files
    (dolist (f org-agent-workflow-files)
      (let ((content (org-agent--load-file-contents f)))
        (when content
          (push (format "### %s\n\n%s"
                        (file-name-nondirectory f)
                        content)
                parts))))
    (when parts
      (mapconcat #'identity (nreverse parts) "\n\n"))))

(defun org-agent--extract-conventions ()
  "Extract the Conventions section from the current org buffer.
Returns the body text under the * Conventions heading, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\* Conventions$" nil t)
      (org-back-to-heading t)
      (let ((body (org-agent--heading-body)))
        (unless (or (null body) (string-empty-p body))
          body)))))

;;;; TDD methodology

(defun org-agent--methodology-text ()
  "Return methodology text for prompt injection.
Priority: `org-agent-methodology-text' defcustom > `org-agent-methodology-file'
> fallback path > built-in default."
  (or org-agent-methodology-text
      (when org-agent-methodology-file
        (org-agent--load-file-contents org-agent-methodology-file))
      (let ((default-path (expand-file-name
                           org-agent-methodology-fallback-path
                           (org-agent--resolve-project-root))))
        (org-agent--load-file-contents default-path))
      org-agent-default-methodology-text))

;;;; Prompt assembly

(defun org-agent--format-props (props)
  "Format a PROPS alist into readable markdown lines."
  (when props
    (mapconcat
     (lambda (p)
       (format "- **%s**: %s" (car p) (cdr p)))
     props "\n")))

(defun org-agent--format-ancestor (ancestor)
  "Format a single ANCESTOR plist into a context section."
  (let ((id (plist-get ancestor :id))
        (title (plist-get ancestor :title))
        (props (plist-get ancestor :props)))
    (concat
     (if id (format "## [%s] %s" id title) (format "## %s" title))
     (when props
       (concat "\n" (org-agent--format-props props))))))

(defun org-agent--state-instructions (state)
  "Return state-specific instructions for STATE."
  (pcase state
    ;; No STUB state — removed
    ("TODO"   "Decompose into NEXT actions. Each sub-heading should be a single executable step.")
    ("NEXT"   "Execute this task. Follow TDD methodology. When done, call org-agent-mark-done.")
    ("DONE"   "Review this completed task. The :RESULTS: drawer has commit
SHAs and diffstat.

1. Read the task description and ancestor context.
2. Get the actual diff via git (use the commit SHAs from :RESULTS:):
   `git diff <earliest-sha>^..<latest-sha>`
   Or for a single commit: `git show <sha>`
3. Review against acceptance criteria and scope.
4. Flag concerns via persistent note:
   ```
   emacsclient -e '(org-agent-add-note \"<node-id>\" \"Review: ...\")'
   ```
   Categories: ARCHITECTURAL, BEHAVIORAL, MINOR.

Do NOT read entire source files — review the diff only.
If fixes are needed, recommend setting the node back to NEXT.")
    (_        "Execute this task. Follow the methodology and report completion status.")))

(defun org-agent--assemble-prompt (heading-ctx &optional include-subtree extra-instructions)
  "Assemble a full prompt for CC from HEADING-CTX plist.
If INCLUDE-SUBTREE is non-nil, include subtree text.
EXTRA-INSTRUCTIONS overrides the default state-specific instructions."
  (let* ((id (plist-get heading-ctx :id))
         (title (plist-get heading-ctx :title))
         (state (plist-get heading-ctx :state))
         (props (plist-get heading-ctx :props))
         (parent-id (org-agent--parent-id-at-point))
         (ancestors (org-agent--ancestor-context))
         (subtree (when include-subtree (org-agent--subtree-text)))
         (methodology (org-agent--methodology-text))
         (workflow (org-agent--workflow-context))
         (instructions (or extra-instructions
                           (org-agent--state-instructions state))))
    (concat
     ;; Ancestors (outermost first)
     (when ancestors
       (concat "# Context (ancestors)\n\n"
               (mapconcat #'org-agent--format-ancestor ancestors "\n\n")
               "\n\n"))
     ;; Current task
     (format "# Current task: [%s] %s\n" (or id "?") title)
     (when state (format "State: %s\n" state))
     (format "Your node ID: `%s`\n" (or id "?"))
     (when parent-id (format "Parent node ID: `%s`\n" parent-id))
     "\n"
     (when props
       (concat (org-agent--format-props props) "\n\n"))
     ;; Subtree
     (when (and subtree (not (string-empty-p subtree)))
       (format "# Subtree\n\n```org\n%s```\n\n" subtree))
     ;; Tree workflow (always present)
     (format "# Agent Workflow\n\n%s\n\n" (or org-agent-workflow-text
                                                org-agent-default-workflow-text))
     ;; Project workflow context
     (when workflow
       (format "# Project Context\n\n%s\n\n" workflow))
     ;; Methodology
     (when methodology
       (format "# Methodology\n\n%s\n\n" methodology))
     ;; Instructions
     (format "# Instructions\n\nYou are working on [%s]. %s\n"
             (or id "?") instructions))))

;;;; Session persistence (node ID → CC session UUID)
;;
;; Each node gets a deterministic CC session UUID stored in
;; .claude/tree/sessions.el.  This allows `claude --resume <uuid>`
;; to reconnect with full conversation history across Emacs restarts.
;; When a node is deleted, its session file is cleaned up on disk.

(defun org-agent--sessions-file ()
  "Return path to the sessions persistence file."
  (expand-file-name (concat org-agent-state-directory "/sessions.el")
                    (org-agent--resolve-project-root)))

(defun org-agent--load-session-map ()
  "Load the node-ID → session-UUID map from disk.
Returns a hash table (string → string)."
  (let ((file (org-agent--sessions-file))
        (map (make-hash-table :test 'equal)))
    (when (file-readable-p file)
      (condition-case nil
          (let ((alist (with-temp-buffer
                         (insert-file-contents file)
                         (goto-char (point-min))
                         (read (current-buffer)))))
            (dolist (pair alist)
              (puthash (car pair) (cdr pair) map)))
        (error nil)))
    map))

(defun org-agent--save-session-map (map &optional replace)
  "Merge MAP into the on-disk session map and save.
Re-reads the file before writing to avoid clobbering entries added
by concurrent agents (load-modify-save race).  The caller's entries
take precedence on conflict.
When REPLACE is non-nil, skip the disk merge and write MAP as-is.
Use REPLACE when the caller has already loaded, modified, and wants
to write the exact result (e.g. after deleting an entry)."
  (let ((file (org-agent--sessions-file)))
    (let ((dir (file-name-directory file)))
      (unless (file-directory-p dir)
        (make-directory dir t)))
    (let ((final-map (if replace
                         map
                       ;; Re-read disk to pick up entries from other agents
                       (let ((disk-map (org-agent--load-session-map)))
                         ;; Merge: disk entries first, then caller's entries override
                         (maphash (lambda (k v)
                                    (puthash k v disk-map))
                                  map)
                         disk-map)))
          (alist nil))
      (maphash (lambda (k v)
                 (push (cons (substring-no-properties k) v) alist))
               final-map)
      (with-temp-file file
        (insert ";; org-agent session map — node ID → CC session UUID\n")
        (insert ";; Auto-generated. Do not edit.\n")
        (let ((print-length nil)
              (print-level nil))
          (pp (nreverse alist) (current-buffer)))))))

(defun org-agent--get-session-uuid (node-id)
  "Get or create a CC session UUID for NODE-ID.
Reads from the persistent map; creates a new UUID if none exists."
  (let* ((map (org-agent--load-session-map))
         (existing (gethash node-id map)))
    (or existing
        (let ((uuid (org-agent--generate-uuid)))
          (puthash node-id uuid map)
          (org-agent--save-session-map map)
          uuid))))

(defun org-agent-rebuild-session-map (&optional org-file)
  "Rebuild the session map by scanning CC session .jsonl files.
Matches `Current task: [NODE-ID]` in each session to identify ownership,
then keeps the latest (by mtime) session per node.  Recovers UUIDs lost
to save-race conditions."
  (interactive)
  (let* ((root (org-agent--resolve-project-root))
         (encoded (replace-regexp-in-string "/" "-" (directory-file-name root)))
         (project-dir (expand-file-name
                       (concat "projects/" encoded)
                       (expand-file-name "~/.claude")))
         (map (org-agent--load-session-map))
         (recovered 0))
    (when (file-directory-p project-dir)
      ;; Build (node-id . (mtime . uuid)) keeping latest per node
      (let ((candidates (make-hash-table :test 'equal)))
        (dolist (jsonl (directory-files project-dir t "\\.jsonl$"))
          (let ((uuid (file-name-sans-extension (file-name-nondirectory jsonl)))
                (mtime (float-time (file-attribute-modification-time
                                    (file-attributes jsonl)))))
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents jsonl nil 0 32768)
                  (goto-char (point-min))
                  ;; Primary: "Current task: [NODE-ID]" — definitive ownership
                  (when (re-search-forward
                         "Current task: \\\\?\\[\\([A-Za-z0-9_-]+\\)\\\\?\\]"
                         nil t)
                    (let ((id (match-string 1)))
                      (let ((existing (gethash id candidates)))
                        (unless (and existing (> (car existing) mtime))
                          (puthash id (cons mtime uuid) candidates))))))
              (error nil))))
        ;; Merge candidates into map (only if not already mapped)
        (maphash (lambda (id mtime-uuid)
                   (unless (gethash id map)
                     (puthash id (cdr mtime-uuid) map)
                     (cl-incf recovered)))
                 candidates)))
    (org-agent--save-session-map map)
    (message "Rebuilt session map: %d entries recovered, %d total"
             recovered (hash-table-count map))))

(defun org-agent--generate-uuid ()
  "Generate a random UUID v4 string."
  (format "%08x-%04x-%04x-%04x-%012x"
          (random (ash 1 32))
          (random (ash 1 16))
          (logior (ash 4 12) (random (ash 1 12)))   ; version 4
          (logior (ash 2 14) (random (ash 1 14)))    ; variant 1
          (random (ash 1 48))))

(defun org-agent--session-uuid-for-node (node-id)
  "Look up existing session UUID for NODE-ID without creating one.
Returns UUID string or nil."
  (let ((map (org-agent--load-session-map)))
    (gethash node-id map)))

(defun org-agent--delete-session (node-id)
  "Delete the CC session for NODE-ID from disk and persistence map.
Removes the .jsonl session file and the map entry.
Uses replace mode for save to prevent the disk merge from
re-adding the just-deleted entry."
  (let* ((map (org-agent--load-session-map))
         (uuid (gethash node-id map)))
    (when uuid
      ;; Try to delete the session file on disk
      (let ((session-file (org-agent--session-jsonl-path uuid)))
        (when (and session-file (file-exists-p session-file))
          (delete-file session-file)
          (message "Deleted session file: %s" (file-name-nondirectory session-file))))
      ;; Remove from map and save with replace=t to avoid re-reading
      ;; the old entry back from disk
      (remhash node-id map)
      (org-agent--save-session-map map t))))

(defun org-agent--session-jsonl-path (uuid &optional backend-name)
  "Return the path to the session file for UUID, or nil.
BACKEND-NAME selects the lookup strategy: codex backends use
`org-agent-codex--find-session-file'; all others check CC's
~/.claude/projects/ directory."
  (let ((find-fn (org-agent--adapter (or backend-name "anthropic")
                                      :find-session-file)))
    (if find-fn
        ;; Backend provides its own session file lookup
        (funcall find-fn uuid)
      ;; Default: CC session lookup
      (let* ((root (org-agent--resolve-project-root))
             (encoded (replace-regexp-in-string "/" "-" (directory-file-name root)))
             ;; CC stores sessions under ~/.claude/projects/-path-to-project/
             (project-dir (expand-file-name
                           (concat "projects/" encoded)
                           (expand-file-name "~/.claude")))
             (jsonl (expand-file-name (concat uuid ".jsonl") project-dir)))
        (when (file-exists-p jsonl) jsonl)))))

;;;; Worktree management — isolated working trees per NEXT agent
;;
;; Each NEXT agent gets a git worktree at <worktree-dir>/<node-id>
;; on a branch named <node-id>.  The agent works in total isolation:
;; it can commit, run cargo check --workspace, etc.  On DONE
;; the parent merges the branch and removes the worktree.

(defun org-agent--root-ancestor-id (node-id)
  "Find the root-level (level 2) ancestor ID for NODE-ID.
Returns NODE-ID itself if it is already a root heading.
Used to determine which long-lived branch a worktree should fork from."
  (with-current-buffer (org-agent--org-buffer)
    (save-excursion
      (goto-char (org-agent--find-heading-by-id node-id))
      (let ((root-id node-id))
        (while (and (> (org-current-level) 2)
                    (org-up-heading-safe))
          (let ((id (org-agent--heading-id)))
            (when id (setq root-id id))))
        root-id))))

(defun org-agent--root-branch (node-id)
  "Return the git branch for NODE-ID's root ancestor.
If the branch doesn't exist yet, create it from main."
  (let* ((root-id (org-agent--root-ancestor-id node-id))
         (default-directory (org-agent--resolve-project-root)))
    (unless (= 0 (call-process "git" nil nil nil
                                "rev-parse" "--verify" root-id))
      (message "org-agent: creating root branch %s from main" root-id)
      (call-process "git" nil nil nil "branch" root-id "main"))
    root-id))

(defun org-agent--worktree-path (node-id)
  "Return the worktree directory path for NODE-ID."
  (expand-file-name (format "%s/%s" org-agent-worktree-directory node-id)
                    (org-agent--resolve-project-root)))

(defun org-agent--worktree-branch (node-id)
  "Return the git branch name for NODE-ID's worktree."
  node-id)

(defun org-agent--worktree-exists-p (node-id)
  "Return t if a worktree exists for NODE-ID."
  (file-directory-p (org-agent--worktree-path node-id)))

(defun org-agent--parent-branch (node-id)
  "Return git branch to fork NODE-ID's worktree from.
Prefers immediate parent's branch (for chain children that build
on predecessors).  Falls back to root ancestor branch."
  (let* ((default-directory (org-agent--resolve-project-root))
         (parent-id (with-current-buffer (org-agent--org-buffer)
                      (save-excursion
                        (goto-char (org-agent--find-heading-by-id node-id))
                        (org-agent--parent-id-at-point)))))
    (if (and parent-id
             (org-agent--git-ref-exists-p parent-id))
        parent-id
      (org-agent--root-branch node-id))))

(defun org-agent--create-worktree (node-id)
  "Create or reuse an isolated git worktree for NODE-ID.
Returns the worktree path on success, nil on failure.
If a valid worktree already exists for NODE-ID, reuse it.
Creates worktree at `org-agent-worktree-directory'/NODE-ID on a branch named NODE-ID.
Forks from the parent's branch if it exists, otherwise from
the root ancestor's branch."
  (let* ((default-directory (org-agent--resolve-project-root))
         (wt-path (org-agent--worktree-path node-id))
         (branch (org-agent--worktree-branch node-id))
         (base-branch (org-agent--parent-branch node-id)))
    ;; Prune stale worktree metadata first
    (call-process "git" nil nil nil "worktree" "prune")
    ;; Reuse existing valid worktree
    (if (and (file-directory-p wt-path)
             (file-exists-p (expand-file-name ".git" wt-path)))
        (progn
          (message "org-agent: reusing existing worktree for [%s] at %s" node-id wt-path)
          wt-path)
      ;; Clean up leftover directory that isn't a valid worktree
      (when (file-directory-p wt-path)
        (ignore-errors (delete-directory wt-path t)))
      ;; Force-delete stale branch if it exists
      (call-process "git" nil nil nil "branch" "-D" branch)
      (make-directory (file-name-directory wt-path) t)
      ;; Create fresh worktree forking from root ancestor's branch
      (with-temp-buffer
        (let ((exit-code (call-process "git" nil t nil
                                       "worktree" "add"
                                       "-b" branch wt-path base-branch)))
          (if (= exit-code 0)
              (progn
                (message "org-agent: created worktree for [%s] at %s (base: %s)"
                         node-id wt-path base-branch)
                ;; Copy canonical settings.json and CLAUDE.md into worktree
                ;; so agents always use latest hooks/instructions.
                ;; (Cannot symlink .claude/ — worktrees live inside .claude/,
                ;; creating a cycle.)
                (let ((wt-claude (expand-file-name ".claude" wt-path))
                      (main-claude (expand-file-name ".claude" default-directory)))
                  (unless (file-directory-p wt-claude)
                    (make-directory wt-claude t))
                  (dolist (f '("settings.json" "CLAUDE.md"))
                    (let ((src (expand-file-name f main-claude))
                          (dst (expand-file-name f wt-claude)))
                      (when (file-exists-p src)
                        (copy-file src dst t)))))
                wt-path)
            (message "org-agent: FAILED to create worktree for [%s]: %s"
                     node-id (string-trim (buffer-string)))
            nil))))))

(defun org-agent--git-ref-exists-p (ref &optional directory)
  "Return t if REF resolves in DIRECTORY."
  (let ((default-directory (or directory (org-agent--resolve-project-root))))
    (= 0 (call-process "git" nil nil nil "rev-parse" "--verify" ref))))

(defun org-agent--git-ref-oid (ref &optional directory)
  "Return REF's object ID in DIRECTORY, or nil if REF does not resolve."
  (let ((default-directory (or directory (org-agent--resolve-project-root))))
    (with-temp-buffer
      (when (= 0 (call-process "git" nil t nil "rev-parse" ref))
        (string-trim (buffer-string))))))

(defun org-agent--merge-in-progress-p (&optional directory)
  "Return t if a git merge is currently in progress in DIRECTORY."
  (let ((default-directory (or directory (org-agent--resolve-project-root))))
    (= 0 (call-process "git" nil nil nil "rev-parse" "-q" "--verify" "MERGE_HEAD"))))

(defun org-agent--index-has-conflicts-p (&optional directory)
  "Return t if DIRECTORY's git index has unmerged paths."
  (let ((default-directory (or directory (org-agent--resolve-project-root))))
    (not (string-empty-p
          (string-trim
           (with-temp-buffer
             (call-process "git" nil t nil "diff" "--name-only" "--diff-filter=U")
             (buffer-string)))))))

(defun org-agent--staged-files (&optional directory)
  "Return files staged in DIRECTORY's index, relative to that worktree root."
  (let ((default-directory (or directory (org-agent--resolve-project-root))))
    (split-string
     (string-trim
      (with-temp-buffer
        (call-process "git" nil t nil "diff" "--cached" "--name-only")
        (buffer-string)))
     "\n" t)))

(defun org-agent--finalize-merge (&optional directory)
  "Finalize an in-progress merge in DIRECTORY.
Conflicts must already be resolved and files staged.
Runs merge formatter if configured, re-stages, then commits.
Does not touch unstaged working tree changes.
Returns t on success, nil if unmerged paths remain."
  (let ((default-directory (or directory (org-agent--resolve-project-root))))
    (if (org-agent--index-has-conflicts-p default-directory)
        (progn
          (message "org-agent: merge in progress but unresolved conflicts remain")
          nil)
      ;; Run merge formatter if configured
      (when org-agent-merge-formatter
        (let ((staged (org-agent--staged-files default-directory)))
          (when staged
            (message "org-agent: running merge formatter...")
            (call-process-shell-command org-agent-merge-formatter nil nil nil)
            (apply #'call-process "git" nil nil nil "add" staged))))
      ;; Commit the merge
      (let ((exit-code
             (with-temp-buffer
               (call-process "git" nil t nil "commit" "--no-edit"))))
        (if (= exit-code 0)
            (progn
              (message "org-agent: finalized in-progress merge")
              t)
          (message "org-agent: failed to finalize merge — pre-commit hook may have blocked it")
          nil)))))

(defun org-agent--merge-worktree (node-id &optional directory)
  "Merge NODE-ID's worktree branch into DIRECTORY's current HEAD.
Returns t on success, nil on failure."
  (let* ((default-directory (or directory (org-agent--resolve-project-root)))
         (branch (org-agent--worktree-branch node-id)))
    (with-temp-buffer
      (let ((exit-code (call-process "git" nil t nil "merge" branch
                                     "--no-edit"
                                     "-m" (format "merge(%s): integrate worktree"
                                                  node-id))))
        (if (= exit-code 0)
            (progn
              (message "org-agent: merged branch %s" branch)
              t)
          (message "org-agent: merge conflict on [%s] — resolve then: git add <files> && git commit --no-edit && org-agent-mark-done"
                   node-id)
          nil)))))

(defun org-agent--remove-worktree (node-id &optional force)
  "Remove NODE-ID's worktree and delete its branch.
Safe to call even if no worktree exists.  Refuses to remove
if the worktree has uncommitted changes unless FORCE is t.
Returns t if removed, nil if refused."
  (let* ((default-directory (org-agent--resolve-project-root))
         (wt-path (org-agent--worktree-path node-id))
         (branch (org-agent--worktree-branch node-id)))
    (if (and (not force)
             (file-directory-p wt-path)
             (org-agent--worktree-dirty-p node-id))
        ;; Safety: refuse on dirty worktree
        (progn
          (message "org-agent: WARNING — [%s] worktree has uncommitted changes, refusing to remove"
                   node-id)
          nil)
      ;; Remove worktree
      (when (file-directory-p wt-path)
        (call-process "git" nil nil nil "worktree" "remove" "--force" wt-path)
        (message "org-agent: removed worktree for [%s]" node-id))
      ;; Delete branch
      (call-process "git" nil nil nil "branch" "-d" branch)
      ;; Prune
      (call-process "git" nil nil nil "worktree" "prune")
      t)))

(defun org-agent--prune-worktrees ()
  "Prune stale git worktrees."
  (let ((default-directory (org-agent--resolve-project-root)))
    (call-process "git" nil nil nil "worktree" "prune")))

(defun org-agent--worktree-dirty-at-path-p (path)
  "Return t if PATH has uncommitted git changes."
  (when (file-directory-p path)
    (with-temp-buffer
      (let* ((default-directory path)
             (exit-code (call-process "git" nil t nil "status" "--porcelain")))
        (and (= exit-code 0)
             (not (string-empty-p (string-trim (buffer-string)))))))))

(defun org-agent--worktree-dirty-p (node-id)
  "Return t if NODE-ID's worktree has uncommitted changes."
  (org-agent--worktree-dirty-at-path-p (org-agent--worktree-path node-id)))

(defun org-agent--integration-worktree-path (node-id)
  "Return the detached integration worktree path for NODE-ID."
  (expand-file-name (format "%s/.merge-%s" org-agent-worktree-directory node-id)
                    (org-agent--resolve-project-root)))

(defun org-agent--ensure-integration-worktree (node-id target-branch)
  "Create or reuse NODE-ID's detached integration worktree for TARGET-BRANCH.
Clean integration worktrees are recreated from TARGET-BRANCH so retries start
from the latest branch tip.  Dirty or in-progress merge worktrees are reused
so manual conflict resolution is preserved."
  (let* ((default-directory (org-agent--resolve-project-root))
         (wt-path (org-agent--integration-worktree-path node-id))
         (valid-worktree (and (file-directory-p wt-path)
                              (file-exists-p (expand-file-name ".git" wt-path)))))
    (call-process "git" nil nil nil "worktree" "prune")
    (when (and valid-worktree
               (not (org-agent--merge-in-progress-p wt-path))
               (not (org-agent--worktree-dirty-at-path-p wt-path)))
      (call-process "git" nil nil nil "worktree" "remove" "--force" wt-path)
      (setq valid-worktree nil))
    (unless valid-worktree
      (when (file-directory-p wt-path)
        (ignore-errors (delete-directory wt-path t)))
      (make-directory (file-name-directory wt-path) t)
      (with-temp-buffer
        (let ((exit-code (call-process "git" nil t nil
                                       "worktree" "add" "--detach"
                                       wt-path target-branch)))
          (if (/= exit-code 0)
              (progn
                (message "org-agent: FAILED to create integration worktree for [%s]: %s"
                         node-id (string-trim (buffer-string)))
                (setq wt-path nil))
            (message "org-agent: created integration worktree for [%s] at %s"
                     node-id wt-path)))))
    (when (and wt-path valid-worktree)
      (message "org-agent: reusing integration worktree for [%s] at %s"
               node-id wt-path))
    wt-path))

(defun org-agent--remove-integration-worktree (node-id)
  "Remove NODE-ID's detached integration worktree."
  (let* ((default-directory (org-agent--resolve-project-root))
         (wt-path (org-agent--integration-worktree-path node-id)))
    (when (file-directory-p wt-path)
      (call-process "git" nil nil nil "worktree" "remove" "--force" wt-path)
      (call-process "git" nil nil nil "worktree" "prune"))
    t))

(defun org-agent--advance-branch-ref (branch new-oid old-oid &optional directory)
  "Advance BRANCH from OLD-OID to NEW-OID in DIRECTORY.
Returns t on success, nil if the ref update is rejected."
  (let ((default-directory (or directory (org-agent--resolve-project-root))))
    (= 0 (call-process "git" nil nil nil
                       "update-ref"
                       (format "refs/heads/%s" branch)
                       new-oid
                       old-oid))))

(defun org-agent--commit-in-worktree (node-id title)
  "Commit all changes in NODE-ID's worktree on its branch.
Runs pre-commit formatter + git add -A + commit.  Does NOT merge or remove the worktree.
Returns t on success, nil if commit failed or no worktree exists."
  (let ((wt-path (org-agent--worktree-path node-id)))
    (if (not (file-directory-p wt-path))
        (progn
          (message "org-agent: no worktree for [%s], nothing to commit" node-id)
          nil)
      (let ((default-directory wt-path))
        ;; Check for changes
        (let ((status (with-temp-buffer
                        (call-process "git" nil t nil "status" "--porcelain")
                        (string-trim (buffer-string)))))
          (if (string-empty-p status)
              (progn
                (message "org-agent: [%s] worktree clean, no commit needed" node-id)
                t)
            ;; Run pre-commit formatter before staging so hooks pass.
            ;; This is the #1 cause of silent commit failure — agents don't
            ;; always format before marking DONE.
            (when org-agent-pre-commit-formatter
              (message "org-agent: [%s] running formatter in worktree..." node-id)
              (let ((fmt-exit (call-process-shell-command
                               org-agent-pre-commit-formatter nil nil nil)))
                (unless (= fmt-exit 0)
                  (message "org-agent: [%s] formatter failed (exit %d) — trying commit anyway"
                           node-id fmt-exit))))
            ;; Stage and commit
            (let ((msg (format "feat(%s): %s\n\nOrg-Node: %s" node-id title node-id)))
              (call-process "git" nil nil nil "add" "-A")
              ;; Unstage worktree-local state dirs — these are artifacts,
              ;; not code changes, and cause spurious merge conflicts.
              (dolist (dir '(".claude/" ".org-agent/"))
                (when (file-directory-p dir)
                  (call-process "git" nil nil nil "reset" "HEAD" "--" dir)))
              (let ((exit-code
                     (with-temp-buffer
                       (call-process "git" nil t nil "commit" "-m" msg))))
                (if (= exit-code 0)
                    (progn
                      (message "org-agent: [%s] committed in worktree" node-id)
                      t)
                  (call-process "git" nil nil nil "reset" "HEAD")
                  (message "org-agent: [%s] commit FAILED in worktree: %s"
                           node-id (with-temp-buffer
                                     (call-process "git" nil t nil "commit" "--dry-run" "-m" msg)
                                     (string-trim (buffer-string))))
                  nil)))))))))

(defun org-agent--record-owns-paths (node-id)
  "Record OWNS_PATHS on NODE-ID from its commit diff.
Extracts the list of file path prefixes (at directory granularity)
that the node's branch modified relative to its fork point.
Sets the OWNS_PATHS org property so the edit guard can enforce
disjoint file ownership."
  (let* ((default-directory (org-agent--resolve-project-root))
         (branch (org-agent--worktree-branch node-id))
         ;; Find fork point: where this branch diverged from its parent
         (parent-id (with-current-buffer (org-agent--org-buffer)
                      (save-excursion
                        (goto-char (org-agent--find-heading-by-id node-id))
                        (org-agent--parent-id-at-point))))
         (base (if (and parent-id (org-agent--git-ref-exists-p parent-id))
                   parent-id
                 (org-agent--root-branch node-id)))
         ;; Get changed files relative to fork point
         (files (with-temp-buffer
                  (call-process "git" nil t nil "diff" "--name-only"
                                (format "%s...%s" base branch))
                  (string-trim (buffer-string)))))
    (when (and (not (string-empty-p files))
               (org-agent--git-ref-exists-p branch))
      ;; Extract unique directory prefixes (crate-level granularity)
      (let* ((file-list (split-string files "\n" t))
             (dirs (delete-dups
                    (mapcar (lambda (f)
                              ;; Use first two path components as prefix
                              ;; e.g. "crates/bandit-functional/" from
                              ;;      "crates/bandit-functional/src/foo.rs"
                              (let ((parts (split-string f "/")))
                                (if (>= (length parts) 2)
                                    (concat (nth 0 parts) "/" (nth 1 parts) "/")
                                  (concat (nth 0 parts) "/"))))
                            file-list)))
             (paths-str (string-join dirs " ")))
        (with-current-buffer (org-agent--org-buffer)
          (save-excursion
            (goto-char (org-agent--find-heading-by-id node-id))
            (org-entry-put nil "OWNS_PATHS" paths-str)))
        (message "org-agent: [%s] recorded OWNS_PATHS: %s" node-id paths-str)))))

(defun org-agent--merge-children-worktrees (parent-id)
  "Merge all DONE children's worktree branches into the root ancestor's branch.
Each child branch is merged in a detached integration worktree first.
The target branch ref is advanced only after all merges succeed; child
worktrees/branches are cleaned up only after that ref update succeeds.
Returns t if all merges and the ref update succeed, nil otherwise.
Point must be on the PARENT-ID heading when called."
  (let* ((default-directory (org-agent--resolve-project-root))
         (target-branch (org-agent--root-branch parent-id))
         (children (save-excursion
                     (org-agent--collect-children-by-state "DONE")))
         (target-tip (org-agent--git-ref-oid target-branch default-directory))
         (integration-path nil)
         (merged 0)
         (merged-children nil)
         (conflict nil))
    (unless target-tip
      (message "org-agent: FAILED to resolve target branch %s" target-branch)
      (setq conflict t))
    (unless conflict
      (setq integration-path
            (org-agent--ensure-integration-worktree parent-id target-branch))
      (unless integration-path
        (setq conflict t)))
    (when (and integration-path
               (org-agent--merge-in-progress-p integration-path))
      (if (org-agent--finalize-merge integration-path)
          (message "org-agent: [%s] finalized in-progress integration merge, continuing"
                   parent-id)
        (message "org-agent: [%s] BLOCKED — integration merge in progress at %s. Resolve there and rerun mark-done."
                 parent-id integration-path)
        (setq conflict t)))
    (dolist (child children)
      (unless conflict
        (let* ((child-id (plist-get child :id))
               (branch (org-agent--worktree-branch child-id))
               (wt-path (org-agent--worktree-path child-id)))
          ;; Only process children that have a worktree branch
          (when (and child-id
                     (org-agent--git-ref-exists-p branch default-directory))
            ;; Skip branches that are already ancestors of the target
            ;; (zero delta — merging them is a no-op).
            ;; BUT: if a dirty worktree exists for a zero-delta branch,
            ;; that means uncommitted work — block the merge to prevent loss.
            (let ((is-ancestor
                   (= 0 (let ((default-directory (org-agent--resolve-project-root)))
                           (call-process "git" nil nil nil
                                         "merge-base" "--is-ancestor"
                                         branch target-branch)))))
              (if is-ancestor
                  (if (and (file-directory-p wt-path)
                           (org-agent--worktree-dirty-p child-id))
                      (progn
                        (message "org-agent: [%s] BLOCKED — branch has no commits but worktree has uncommitted changes (lost work?)"
                                 child-id)
                        (setq conflict t))
                    (message "org-agent: [%s] branch already in %s — skipping (no-op)"
                             child-id target-branch)
                    (push child-id merged-children))
                ;; Refuse to merge if worktree is dirty
                (when (and (file-directory-p wt-path)
                           (org-agent--worktree-dirty-p child-id))
                  (message "org-agent: [%s] worktree has uncommitted changes — skipping merge"
                           child-id)
                  (setq conflict t))
                (unless conflict
                  ;; Merge the branch
                  (let ((merge-ok (org-agent--merge-worktree child-id integration-path)))
                    (if merge-ok
                        (progn
                          (cl-incf merged)
                          (push child-id merged-children)
                          (message "org-agent: merged [%s] into integration worktree" child-id))
                      (setq conflict t)
                      (message "org-agent: merge conflict on [%s] in %s — stopping"
                               child-id integration-path))))))))))
    (unless conflict
      (let ((new-tip (org-agent--git-ref-oid "HEAD" integration-path)))
        (if (not new-tip)
            (progn
              (message "org-agent: FAILED to resolve integration HEAD for [%s]" parent-id)
              (setq conflict t))
          (unless (or (string= new-tip target-tip)
                      (org-agent--advance-branch-ref target-branch new-tip target-tip
                                                      default-directory))
            (message "org-agent: FAILED to advance %s; preserving child worktrees and integration state at %s"
                     target-branch integration-path)
            (setq conflict t)))))
    (if conflict
        (progn
          (message "org-agent: merged %d children for [%s] into integration worktree, target branch %s unchanged"
                   merged parent-id target-branch)
          nil)
      (dolist (child-id (nreverse merged-children))
        (unless (org-agent--remove-worktree child-id)
          (message "org-agent: WARNING — merged [%s] but cleanup failed" child-id)))
      (org-agent--remove-integration-worktree parent-id)
      (when (> merged 0)
        (message "org-agent: merged all %d children for [%s] into %s"
                 merged parent-id target-branch))
      t)))

;;;; CC session management

(defun org-agent--cc-buffer-name (node-id)
  "Return the CC buffer name for NODE-ID."
  (let* ((root (org-agent--resolve-project-root))
         (project (file-name-nondirectory (directory-file-name root))))
    (format "*claude:%s:%s*" project node-id)))

(defun org-agent--session-alive-p (node-id)
  "Return t if a live CC session exists for NODE-ID."
  (let ((buf (gethash node-id org-agent--sessions)))
    (and buf (buffer-live-p buf))))

(defun org-agent--parent-id-at-point ()
  "Return the node ID of the parent heading, or nil at top level."
  (save-excursion
    (when (org-up-heading-safe)
      (or (org-agent--heading-id)
          (org-agent--slug-id (org-agent--heading-title))))))


(defun org-agent--resolve-backend ()
  "Return (PROGRAM . BACKEND-NAME) for the heading at point.
Checks the :BACKEND: property (inheritable), falls back to `org-agent-default-backend'."
  (let* ((backend (or (org-entry-get nil "BACKEND" t) org-agent-default-backend))
         (local-backend (org-entry-get nil "BACKEND" nil))
         (id (org-agent--heading-id))
         (entry (assoc backend org-agent-backend-programs))
         (program (if entry (cdr entry) org-agent-program)))
    (message "org-agent: [%s] resolved backend=%s (local=%s)"
             id backend (or local-backend "inherited"))
    (cons (or program org-agent-program) backend)))
(defun org-agent--start-cc (node-id prompt &optional parent-id permission-mode no-display can-edit state worktree-path backend)
  "Start a CC instance for NODE-ID with PROMPT.
PARENT-ID, if non-nil, is injected as ORG_AGENT_PARENT env var.
PERMISSION-MODE overrides `org-agent-permission-mode' (e.g. \"plan\").
NO-DISPLAY, if non-nil, creates the buffer without displaying it.
CAN-EDIT, if non-nil, grants full tool access (Edit, Write, etc.).
When CAN-EDIT is nil, the agent is restricted to read-only tools
plus Bash (for emacsclient) and Task (for subagent research).
Only NEXT-status nodes should get CAN-EDIT=t.
STATE, if non-nil, is injected as ORG_AGENT_STATE env var so
hooks can enforce tool-access rules per org state (e.g. blocking
Edit/Write for non-NEXT agents).
WORKTREE-PATH, if non-nil, sets the agent's working directory to
an isolated git worktree and injects ORG_AGENT_WORKTREE_PATH env var.
If a live buffer exists, switch to it (unless NO-DISPLAY).
If a persisted session UUID exists, resume it with `--resume'.
Otherwise create a new session with a deterministic `--session-id'.
BACKEND, if non-nil, overrides the :BACKEND: org property (e.g. \"codex\")."
  ;; Capture sessions/ready hashes before potential buffer switch —
  ;; these are buffer-local on TODO.org and would resolve to empty
  ;; hashes inside the vterm buffer's context.
  (let* ((sessions-map org-agent--sessions)
         (ready-map org-agent--buffer-ready)
         (buffer-name (org-agent--cc-buffer-name node-id))
         (existing (gethash node-id sessions-map))
         (backend-name (or backend "anthropic")))
    ;; Load the required feature for this backend
    (require (org-agent--adapter backend-name :require))
    ;; Clean up stale hash entries: killed buffers or dead processes.
    ;; Also nuke the persisted session so the next attempt starts fresh
    ;; instead of --resume'ing a dead conversation.
    (when existing
      (cond
       ;; Buffer was killed — remove dangling hash entry + stale session
       ((not (buffer-live-p existing))
        (message "org-agent: [%s] stale hash entry (buffer killed) — cleaning up" node-id)
        (remhash node-id sessions-map)
        (org-agent--delete-session node-id)
        (setq existing nil))
       ;; Buffer alive but process dead — kill and recreate fresh
       ((not (get-buffer-process existing))
        (message "org-agent: [%s] stale buffer (process dead) — cleaning up" node-id)
        (remhash node-id sessions-map)
        (remhash (buffer-name existing) ready-map)
        (kill-buffer existing)
        (org-agent--delete-session node-id)
        (setq existing nil))))
    (if (and existing (buffer-live-p existing))
        ;; Live buffer — just switch (unless no-display)
        (unless no-display (switch-to-buffer existing))
      ;; Determine session UUID and whether to resume
      (let* ((session-uuid (org-agent--get-session-uuid node-id))
             ;; For codex: check stored Codex session ID (their UUID, not ours)
             (codex-session-id
              (when (equal backend-name "codex")
                (save-excursion
                  (goto-char (or (org-agent--find-heading-by-id node-id) (point)))
                  (org-entry-get nil "CODEX_SESSION_ID"))))
             (has-history
              (if (equal backend-name "codex")
                  ;; Codex: verify the stored session file still exists
                  (and codex-session-id
                       (org-agent-codex--session-file-for-id codex-session-id))
                (org-agent--session-jsonl-path session-uuid backend-name)))
             (prompt-file (make-temp-file "org-agent-" nil ".md" prompt))
             (initial-msg (if has-history
                              (format "Read %s for updated task context since last session." prompt-file)
                            (format "Read %s for your full task context." prompt-file)))
             (quoted-msg (if (eq claude-code-terminal-backend 'vterm)
                             (shell-quote-argument initial-msg)
                           initial-msg))
             (backend-program (or (cdr (assoc backend-name org-agent-backend-programs))
                                  org-agent-program))
             (perm-mode (or permission-mode org-agent-permission-mode))
             (allowed-tools (if can-edit
                                nil  ; full access — no --allowedTools flag
                              "Read Glob Grep Bash Task WebFetch WebSearch"))
             (switches
              (pcase backend-name
                ("codex"
                 ;; codex resume <codex-uuid> "prompt" | codex --full-auto -C <dir> "prompt"
                 (append
                  (if has-history
                      (list "resume" codex-session-id)
                    (list "--full-auto"
                          "-C" (or worktree-path org-agent--project-root default-directory)))
                  (list quoted-msg)))
                (_
                 ;; claude / z.ai: --permission-mode ... --resume <uuid> "prompt"
                 (append
                  (list "--permission-mode" perm-mode)
                  (when allowed-tools
                    (list "--allowedTools" allowed-tools))
                  (if has-history
                      (list "--resume" session-uuid)
                    (list "--session-id" session-uuid))
                  (list quoted-msg)))))
             (default-directory (or worktree-path
                                    org-agent--project-root default-directory))
             (process-adaptive-read-buffering nil)
             (env-vars (list (format "ORG_AGENT_NODE=%s" node-id)
                             (format "ORG_AGENT_SESSION=%s" session-uuid)
                             (format "ORG_AGENT_FILE=%s"
                                     (or (buffer-file-name) ""))
                             (format "ORG_AGENT_ROOT=%s"
                                     (or org-agent--project-root ""))))
             (_  (when parent-id
                   (push (format "ORG_AGENT_PARENT=%s" parent-id) env-vars)))
             (_  (when state
                   (push (format "ORG_AGENT_STATE=%s" state) env-vars)))
             (_  (when worktree-path
                   (push (format "ORG_AGENT_WORKTREE_PATH=%s" worktree-path) env-vars)))
             ;; z.ai backend: inject env vars to redirect API
             (_  (when (equal backend-name "zai")
                   (let ((zai-key (or (getenv "Z_AI_API_KEY")
                                      (when (file-exists-p (expand-file-name "~/.config/zai/key"))
                                        (string-trim (with-temp-buffer
                                                       (insert-file-contents (expand-file-name "~/.config/zai/key"))
                                                       (buffer-string)))))))
                     (when zai-key
                       (push (format "ANTHROPIC_AUTH_TOKEN=%s" zai-key) env-vars)
                       (push "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic" env-vars)
                       (push "API_TIMEOUT_MS=3000000" env-vars)))))
             (process-environment (append env-vars process-environment))
             ;; Dispatch to backend-specific term-make.
             ;; Suppress ivy/helm completing-read to avoid "minibuffer
             ;; while in minibuffer" errors during programmatic dispatch.
             (make-fn (org-agent--adapter backend-name :term-make))
             (_  (message "org-agent: [%s] PRE term-make: backend=%s program=%s dir=%s switches=%S"
                          node-id backend-name backend-program default-directory
                          (mapcar (lambda (s) (if (> (length s) 80)
                                                  (concat (substring s 0 80) "...")
                                                s))
                                  switches)))
             (buf (let ((completing-read-function #'completing-read-default)
                        (enable-recursive-minibuffers t))
                    (funcall make-fn
                             claude-code-terminal-backend
                             buffer-name
                             backend-program
                             switches)))
             (_  (message "org-agent: [%s] POST term-make: buf=%s live=%s proc=%s"
                          node-id buf
                          (and buf (buffer-live-p buf))
                          (and buf (buffer-live-p buf)
                               (get-buffer-process buf) t))))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            ;; Dispatch to backend-specific configure/keymap/faces
            (funcall (org-agent--adapter backend-name :term-configure)
                     claude-code-terminal-backend)
            (funcall (org-agent--adapter backend-name :term-setup-keymap)
                     claude-code-terminal-backend)
            (funcall (org-agent--adapter backend-name :term-customize-faces)
                     claude-code-terminal-backend)
            (buffer-face-set :inherit 'claude-code-repl-face)
            (setq-local org-agent--buffer-node-id node-id)
            (setq-local org-agent--buffer-session-uuid session-uuid)
            (setq-local org-agent--buffer-backend backend-name)
            ;; Track ready state via the backend's event hook
            (let ((event-hook-var (org-agent--adapter backend-name :event-hook)))
              (add-hook event-hook-var #'org-agent--on-cc-event nil t))
            ;; Mark as busy initially
            (puthash (buffer-name) nil ready-map)
            ;; Remove from sessions hash + ready map on buffer kill
            (add-hook 'kill-buffer-hook
                      (lambda ()
                        (when (bound-and-true-p org-agent--buffer-node-id)
                          (remhash org-agent--buffer-node-id sessions-map))
                        (remhash (buffer-name) ready-map))
                      nil t)
            (run-hooks 'claude-code-start-hook))
          ;; Track in TODO.org's sessions hash (captured before buffer switch)
          (puthash node-id buf sessions-map)
          ;; For Codex: schedule session ID capture so resume works next time
          (when (equal backend-name "codex")
            (org-agent-codex--schedule-session-capture buf node-id))
          (if no-display
              ;; Programmatic dispatch: display in a non-selected window.
              ;; Terminal backends (eat/vterm) need a window for the pty
              ;; to render.  display-buffer avoids stealing focus.
              (display-buffer buf '((display-buffer-use-some-window)
                                    (inhibit-switch-frame . t)))
            (switch-to-buffer buf)))))))

;;;; Programmatic dispatch (callable from emacsclient by child agents)

(defun org-agent--find-heading-by-id (target-id)
  "Navigate to heading with bracket ID TARGET-ID in current buffer.
Also handles slug IDs by matching against slugified heading titles.
Widens the buffer first so narrowed views don't hide headings.
Returns point if found, nil otherwise."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((pattern (regexp-quote (format "[%s]" target-id))))
        (if (re-search-forward (concat "^\\*+ .*" pattern) nil t)
            (progn (org-back-to-heading t) (point))
          ;; Fallback: try matching slug IDs against heading titles
          (goto-char (point-min))
          (let ((found nil))
            (while (and (not found)
                        (re-search-forward org-heading-regexp nil t))
              (let* ((heading (org-get-heading t t t t))
                     (title (string-trim
                             (replace-regexp-in-string
                              "^\\[[^]]+\\] *" "" heading)))
                     (slug (org-agent--slug-id title)))
                (when (equal slug target-id)
                  (org-back-to-heading t)
                  (setq found (point)))))
            found))))))

;;;###autoload
(defun org-agent-dispatch (node-id &optional org-file)
  "Dispatch a CC agent for NODE-ID programmatically.
ORG-FILE defaults to TODO.org at the project root.
Designed to be called from emacsclient by a running CC agent:
  emacsclient -e \\='(org-agent-dispatch \"C-1\")\\='

Returns the session UUID string on success, nil on failure."
  (let* ((root (org-agent--resolve-project-root)))
    (with-current-buffer (org-agent--org-buffer)
      (let ((pos (org-agent--find-heading-by-id node-id)))
        (unless pos
          (error "Heading [%s] not found in %s" node-id file))
        (goto-char pos)
        (let* ((backend-name (cdr (org-agent--resolve-backend)))
               (ctx (org-agent--heading-context))
               (id (plist-get ctx :id))
               (state (plist-get ctx :state))
               (parent-id (org-agent--parent-id-at-point))
               (prompt (org-agent--assemble-prompt ctx t)))
          ;; NEXT nodes get edit access; worktrees gated by flag
          (let* ((can-edit (equal state "NEXT"))
                 (wt-path (when (and org-agent-use-worktrees can-edit)
                            (org-agent--create-worktree id))))
            (run-hook-with-args 'org-agent-pre-execute-hook ctx)
            (org-agent--start-cc id prompt parent-id nil t can-edit state wt-path backend-name)
            ;; Return the session UUID for the caller
            (org-agent--get-session-uuid id)))))))

;;;###autoload
(defun org-agent-dispatch-batch (node-ids &optional org-file)
  "Dispatch CC agents for each ID in NODE-IDS list.
Skips TODO children with :BLOCKER: properties (they auto-dispatch via triggers).
Returns alist of (id . uuid) pairs for dispatched agents."
  (let* ((root (org-agent--resolve-project-root))
         (file (or org-file (expand-file-name "TODO.org" root)))
         (results nil))
    (dolist (id node-ids)
      (let* ((state (with-current-buffer (org-agent--ensure-fresh-buffer file)
                      (let ((pos (org-agent--find-heading-by-id id)))
                        (when pos
                          (goto-char pos)
                          (cons (org-get-todo-state) (org-entry-get nil "BLOCKER"))))))
             (todo-state (car state))
             (blocker (cdr state)))
        (if (and (equal todo-state "TODO") blocker)
            (message "org-agent: skipping [%s] (blocked)" id)
          (push (cons id (org-agent-dispatch id org-file)) results))))
    (nreverse results)))

;;;; Inter-agent messaging

;;;###autoload
(defun org-agent-send (node-id message &optional no-queue)
  "Send MESSAGE to the live CC session for NODE-ID.
The message is submitted as a new prompt to the child agent.
If the agent is busy (not at a prompt), the message is queued and
delivered automatically when the agent becomes ready.
If NO-QUEUE is non-nil, send immediately regardless of ready state
\(legacy behavior, may paste into active output).
Designed for parent agents to coordinate children:
  emacsclient -e \\='(org-agent-send \"C-1\" \"Focus on the test failures first.\")\\='"
  (let* ((cc-buf-name (org-agent--cc-buffer-name node-id))
         (cc-buf (get-buffer cc-buf-name)))
    (unless (and cc-buf (buffer-live-p cc-buf))
      (error "No live CC session for [%s]" node-id))
    (if (or no-queue (gethash cc-buf-name org-agent--buffer-ready))
        ;; Agent is ready (or forced) — send immediately
        (progn
          (with-current-buffer cc-buf
            (let ((send-fn (org-agent--adapter
                            (or org-agent--buffer-backend "anthropic")
                            :term-send-string)))
              (require (org-agent--adapter
                        (or org-agent--buffer-backend "anthropic")
                        :require))
              (funcall send-fn claude-code-terminal-backend message)
              ;; Submit: send RET directly to the process
              (cond
               ((bound-and-true-p vterm--process)
                (process-send-string vterm--process "\C-m"))
               ((bound-and-true-p eat-terminal)
                (eat-self-input 1 ?\C-m)))))
          ;; Mark as busy since we just submitted a prompt
          (puthash cc-buf-name nil org-agent--buffer-ready)
          (format "Sent to [%s]" node-id))
      ;; Agent is busy — queue for later delivery
      (org-agent--enqueue-message cc-buf-name message)
      (format "Queued for [%s] (agent busy)" node-id))))

;;;###autoload
(defun org-agent-send-all (node-ids message)
  "Send MESSAGE to all live CC sessions in NODE-IDS list.
Usage: emacsclient -e \\='(org-agent-send-all
  (list \"C-1\" \"C-2\") \"Pause.\")\\='"
  (let ((sent 0))
    (dolist (id node-ids)
      (condition-case nil
          (progn (org-agent-send id message) (cl-incf sent))
        (error nil)))
    (format "Sent to %d/%d sessions" sent (length node-ids))))

;;;###autoload
(defun org-agent-broadcast (message)
  "Send MESSAGE to ALL live CC sessions in the project.
Messages are queued for busy agents and delivered when they become ready.
  emacsclient -e \\='(org-agent-broadcast \"Stop work and report status.\")\\='"
  (let ((sent 0)
        (queued 0))
    (dolist (buf (buffer-list))
      (when (and (string-match-p "\\*claude:.*\\*" (buffer-name buf))
                 (buffer-live-p buf))
        (let ((buf-name (buffer-name buf)))
          (condition-case nil
              (if (gethash buf-name org-agent--buffer-ready)
                  (progn
                    (with-current-buffer buf
                      (let ((send-fn (org-agent--adapter
                                      (or org-agent--buffer-backend "anthropic")
                                      :term-send-string)))
                        (funcall send-fn claude-code-terminal-backend message)
                        (cond
                         ((bound-and-true-p vterm--process)
                          (process-send-string vterm--process "\C-m"))
                         ((bound-and-true-p eat-terminal)
                          (eat-self-input 1 ?\C-m)))))
                    (puthash buf-name nil org-agent--buffer-ready)
                    (cl-incf sent))
                (org-agent--enqueue-message buf-name message)
                (cl-incf queued))
            (error nil)))))
    (format "Broadcast: %d sent, %d queued" sent queued)))

;;;; Interactive commands

;;;###autoload
(defun org-agent-spawn ()
  "Spawn CC on the heading at point with full subtree context.
NEXT nodes get full edit access; others are read-only."
  (interactive)
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((backend-info (org-agent--resolve-backend))
         (backend-name (cdr backend-info))
         (ctx (org-agent--heading-context))
         (id (plist-get ctx :id))
         (state (plist-get ctx :state))
         (parent-id (org-agent--parent-id-at-point))
         (prompt (org-agent--assemble-prompt ctx t))
         (can-edit (equal state "NEXT"))
         (wt-path (when (and org-agent-use-worktrees can-edit)
                    (org-agent--create-worktree id))))
    (run-hook-with-args 'org-agent-pre-execute-hook ctx)
    (org-agent--start-cc id prompt parent-id nil nil can-edit state wt-path backend-name)))

;;;###autoload
(defun org-agent-codex ()
  "Spawn Codex on the heading at point, ignoring :BACKEND: property.
NEXT nodes get full edit access; others are read-only."
  (interactive)
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((ctx (org-agent--heading-context))
         (id (plist-get ctx :id))
         (state (plist-get ctx :state))
         (parent-id (org-agent--parent-id-at-point))
         (prompt (org-agent--assemble-prompt ctx t))
         (can-edit (equal state "NEXT"))
         (wt-path (when (and org-agent-use-worktrees can-edit)
                    (org-agent--create-worktree id))))
    (run-hook-with-args 'org-agent-pre-execute-hook ctx)
    (org-agent--start-cc id prompt parent-id nil nil can-edit state wt-path "codex")))

;;;###autoload
(defun org-agent-plan ()
  "Spawn CC to decompose heading at point into sub-headings.
Sends decomposition-specific instructions."
  (interactive)
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((backend-info (org-agent--resolve-backend))
         (backend-name (cdr backend-info))
         (ctx (org-agent--heading-context))
         (id (plist-get ctx :id))
         (instructions
          (concat
           "Decompose this task into sub-headings. For each sub-heading provide:\n"
           (format "1. **ID**: Use parent prefix with sequential number (e.g. %s.1, %s.2)\n" id id)
           "2. **Title**: Brief descriptive name\n"
           "3. **Scope**: What needs to be done\n"
           "4. **Acceptance**: Concrete done conditions\n"
           "5. **State**: TODO for items needing further decomposition, NEXT for executable leaves\n\n"
           "Output in org format:\n"
           "```\n"
           (format "*** TODO [%s.1] Title\n" id)
           "- `scope`: ...\n"
           "- `acceptance`: ...\n"
           "```\n"))
         (prompt (org-agent--assemble-prompt ctx t instructions)))
    (run-hook-with-args 'org-agent-pre-execute-hook ctx)
    (org-agent--start-cc (concat id "/plan") prompt
                          (org-agent--parent-id-at-point) "plan" nil nil "TODO" nil backend-name)))

;;;###autoload
(defun org-agent-review ()
  "Spawn CC to review DONE children of heading at point.
Includes all DONE children's context in the prompt."
  (interactive)
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((backend-name (or org-agent-review-backend
                            (cdr (org-agent--resolve-backend))))
         (ctx (org-agent--heading-context))
         (id (plist-get ctx :id))
         (parent-id (org-agent--parent-id-at-point))
         (done-children (org-agent--collect-children-by-state "DONE"))
         (instructions
          (concat
           "Review all DONE children of this task.\n\n"
           "## Children to review\n\n"
           (if done-children
               (mapconcat
                (lambda (child)
                  (format "### [%s] %s\n%s"
                          (plist-get child :id)
                          (plist-get child :title)
                          (or (org-agent--format-props (plist-get child :props)) "(no props)")))
                done-children "\n\n---\n\n")
             "(No DONE children found)")
           "\n\n## Review checklist\n\n"
           "1. Does each child's output satisfy its acceptance criteria?\n"
           "2. Any interface drift between siblings?\n"
           "3. Any discoveries that require replanning?\n"
           "4. Are all children DONE and ready to integrate?\n"))
         (prompt (org-agent--assemble-prompt ctx nil instructions)))
    (run-hook-with-args 'org-agent-pre-execute-hook ctx)
    (org-agent--start-cc (concat id "/review") prompt parent-id nil nil nil "TODO" nil backend-name)))

;;;###autoload
(defun org-agent-batch ()
  "Batch-spawn CC for all NEXT leaves under heading at point.
Prompts for confirmation before spawning."
  (interactive)
  ;; Sync buffer with disk — CC agents edit via filesystem.
  (when (and (not (buffer-modified-p))
             (buffer-file-name)
             (not (verify-visited-file-modtime (current-buffer))))
    (revert-buffer t t t))
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((batch-parent-id (or (org-agent--heading-id)
                               (org-agent--slug-id (org-agent--heading-title))))
         (leaves (org-agent--collect-next-leaves))
         (count (length leaves)))
    (when (= count 0)
      (user-error "No NEXT leaves found under this heading"))
    (when (yes-or-no-p (format "Spawn %d agents for %d NEXT tasks? " count count))
      (dolist (leaf-pos leaves)
        (save-excursion
          (goto-char leaf-pos)
          (let* ((backend-name (cdr (org-agent--resolve-backend)))
                 (ctx (org-agent--heading-context))
                 (id (plist-get ctx :id))
                 (leaf-state (plist-get ctx :state))
                 (prompt (org-agent--assemble-prompt ctx nil))
                 (wt-path (when (and org-agent-use-worktrees (equal leaf-state "NEXT"))
                            (org-agent--create-worktree id))))
            ;; NEXT leaves get edit access
            (run-hook-with-args 'org-agent-pre-execute-hook ctx)
            (org-agent--start-cc id prompt batch-parent-id nil nil t leaf-state wt-path backend-name))))
      (message "Spawned %d agents" count))))

;;;###autoload
(defun org-agent-kill (&optional purge)
  "Kill the CC session for heading at point.
With prefix arg PURGE, also delete the persisted session from disk
so the next spawn starts fresh (no --resume)."
  (interactive "P")
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((id (or (org-agent--heading-id)
                 (org-agent--slug-id (org-agent--heading-title))))
         (buf (gethash id org-agent--sessions)))
    ;; Kill live buffer
    (when (and buf (buffer-live-p buf))
      (let ((proc (get-buffer-process buf)))
        (when proc
          (set-process-query-on-exit-flag proc nil)
          (delete-process proc)))
      (kill-buffer buf)
      (remhash id org-agent--sessions))
    ;; Purge disk session if requested
    (if purge
        (progn
          (org-agent--delete-session id)
          (message "Killed and purged CC session for [%s]" id))
      (if buf
          (message "Killed CC session for [%s]" id)
        (message "No live CC session for [%s]" id)))))

;;;###autoload
(defun org-agent-purge-node ()
  "Delete the persisted CC session for heading at point.
Removes the session UUID mapping and the .jsonl file from disk.
The next spawn will start a fresh session.
Refuses to purge if the working tree has uncommitted changes —
commit or stash first."
  (interactive)
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  ;; Guard: block purge if uncommitted changes exist
  (let ((default-directory (org-agent--resolve-project-root)))
    (let ((status (with-temp-buffer
                    (call-process "git" nil t nil "status" "--porcelain")
                    (string-trim (buffer-string)))))
      (unless (string-empty-p status)
        (user-error "Cannot purge: uncommitted changes in working tree. Commit or stash first"))))
  (let* ((id (or (org-agent--heading-id)
                 (org-agent--slug-id (org-agent--heading-title))))
         (uuid (org-agent--session-uuid-for-node id)))
    (if uuid
        (when (yes-or-no-p
               (format "Delete persisted session %s for [%s]? " uuid id))
          (org-agent--delete-session id)
          ;; Also kill live buffer if any
          (let ((buf (gethash id org-agent--sessions)))
            (when (and buf (buffer-live-p buf))
              (kill-buffer buf)
              (remhash id org-agent--sessions)))
          ;; Clean up worktree if one exists (force — user explicitly purged)
          (org-agent--remove-worktree id t)
          (message "Purged session for [%s]" id))
      (message "No persisted session for [%s]" id))))

;;;; Subtree collection helpers

(defun org-agent--collect-next-leaves ()
  "Collect positions of all NEXT headings under current subtree.
Returns list of buffer positions."
  (let ((leaves nil)
        (subtree-end (save-excursion (org-end-of-subtree t t) (point))))
    (save-excursion
      (org-back-to-heading t)
      ;; Skip the current heading
      (when (outline-next-heading)
        (while (and (< (point) subtree-end)
                    (org-at-heading-p))
          (when (equal (org-get-todo-state) "NEXT")
            (push (point) leaves))
          (unless (outline-next-heading)
            (goto-char subtree-end)))))
    (nreverse leaves)))

(defun org-agent--collect-children-by-state (target-state)
  "Collect context plists for direct children matching TARGET-STATE."
  (let ((children nil))
    (save-excursion
      (org-back-to-heading t)
      (let ((parent-level (org-current-level)))
        (when (outline-next-heading)
          (while (and (org-at-heading-p)
                      (> (org-current-level) parent-level))
            (when (and (= (org-current-level) (1+ parent-level))
                       (equal (org-get-todo-state) target-state))
              (push (org-agent--heading-context) children))
            (unless (outline-next-heading)
              (goto-char (point-max)))))))
    (nreverse children)))


;;;; Show diff for DONE nodes (human review via magit)

(defun org-agent--node-commit-range (node-id)
  "Return (BASE . TIP) commit range for NODE-ID's work.
Finds commits tagged with Org-Node or feat() prefix.
BASE is the parent of the earliest such commit; TIP is the latest."
  (let* ((default-directory (org-agent--resolve-project-root))
         (shas (with-temp-buffer
                 (call-process "git" nil t nil
                               "log" "--format=%H"
                               (format "--grep=Org-Node: %s" node-id)
                               "--all")
                 (let ((s (string-trim (buffer-string))))
                   (when (string-empty-p s)
                     (erase-buffer)
                     (call-process "git" nil t nil
                                   "log" "--format=%H"
                                   (format "--grep=feat(%s)" node-id)
                                   "--all")
                     (setq s (string-trim (buffer-string))))
                   (unless (string-empty-p s)
                     (split-string s "\n" t))))))
    (when shas
      (let ((tip (car shas))
            (earliest (car (last shas))))
        ;; BASE = parent of earliest commit
        (let ((base (with-temp-buffer
                      (call-process "git" nil t nil
                                    "rev-parse" (concat earliest "^"))
                      (string-trim (buffer-string)))))
          (cons base tip))))))

(defun org-agent--node-commit-range-recursive (node-id)
  "Return (BASE . TIP) commit range for NODE-ID and all its descendants.
For TODO nodes, this includes all children's commits."
  (let* ((default-directory (org-agent--resolve-project-root))
         ;; Collect this node + all descendant node IDs
         (all-ids (list node-id))
         (_ (save-excursion
              (with-current-buffer (org-agent--org-buffer)
                (org-with-wide-buffer
                 (goto-char (or (org-agent--find-heading-by-id node-id) (point-min)))
                 (let ((parent-level (org-current-level))
                       (start (point)))
                   (org-end-of-subtree t t)
                   (let ((end (point)))
                     (goto-char start)
                     (while (and (outline-next-heading) (< (point) end))
                       (when (> (org-current-level) parent-level)
                         (let ((cid (org-agent--heading-id)))
                           (when cid (push cid all-ids)))))))))))
         ;; Build grep pattern matching any of the IDs
         (all-shas nil))
    (dolist (id all-ids)
      (let ((shas (with-temp-buffer
                    (call-process "git" nil t nil
                                  "log" "--format=%H"
                                  (format "--grep=feat(%s)" id)
                                  "--all")
                    (let ((s (string-trim (buffer-string))))
                      (unless (string-empty-p s)
                        (split-string s "\n" t))))))
        (setq all-shas (append all-shas shas))))
    (when all-shas
      ;; Sort by commit timestamp to find earliest and latest
      (let* ((sorted (with-temp-buffer
                       (apply #'call-process "git" nil t nil
                              "log" "--format=%H" "--topo-order"
                              "--ancestry-path"
                              (append all-shas (list "--")))
                       ;; Fallback: just use our list as-is
                       all-shas))
             (tip (car all-shas))
             (earliest (car (last all-shas)))
             (base (with-temp-buffer
                     (call-process "git" nil t nil
                                   "rev-parse" (concat earliest "^"))
                     (string-trim (buffer-string)))))
        (cons base tip)))))

;;;###autoload
(defun org-agent-show-diff ()
  "Show magit-diff for the DONE heading at point.
Finds all commits tagged with this node's ID (and descendants for
TODO nodes) and displays the combined diff in magit."
  (interactive)
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((id (org-agent--heading-id))
         (state (org-get-todo-state))
         (range (if (equal state "DONE")
                    (org-agent--node-commit-range id)
                  (org-agent--node-commit-range-recursive id))))
    (unless range
      (user-error "No commits found for [%s]" id))
    (if (require 'magit nil t)
        (magit-diff-range (format "%s..%s" (car range) (cdr range)))
      ;; Fallback to plain diff buffer if magit isn't available
      (let ((buf (get-buffer-create (format "*diff[%s]*" id)))
            (default-directory (org-agent--resolve-project-root)))
        (with-current-buffer buf
          (erase-buffer)
          (call-process "git" nil t nil
                        "diff" (car range) (cdr range) "--stat")
          (insert "\n")
          (call-process "git" nil t nil
                        "diff" (car range) (cdr range))
          (diff-mode)
          (goto-char (point-min)))
        (switch-to-buffer buf)))))

;;;; Auto-capture :RESULTS: drawer for completed nodes

;;;; Rolling merge and chain auto-dispatch

(defun org-agent--rolling-merge-child (child-id)
  "Merge CHILD-ID's branch into its parent's branch immediately.
Uses the same integration worktree infrastructure as big-bang merge.
Returns t on success, nil on conflict (child left intact for manual resolution)."
  (let* ((default-directory (org-agent--resolve-project-root))
         (parent-id (with-current-buffer (org-agent--org-buffer)
                      (save-excursion
                        (goto-char (org-agent--find-heading-by-id child-id))
                        (org-agent--parent-id-at-point))))
         (child-branch (org-agent--worktree-branch child-id)))
    (cond
     ((not parent-id)
      (message "org-agent: [%s] has no parent — skipping rolling merge" child-id)
      nil)
     ((not (org-agent--git-ref-exists-p child-branch))
      (message "org-agent: [%s] has no branch — skipping rolling merge" child-id)
      nil)
     (t
      (let* ((target-branch (if (org-agent--git-ref-exists-p parent-id)
                                parent-id
                              (org-agent--root-branch child-id)))
             (target-tip (org-agent--git-ref-oid target-branch))
             (integration-path (org-agent--ensure-integration-worktree
                                parent-id target-branch)))
        (cond
         ((not integration-path)
          (message "org-agent: [%s] FAILED to create integration worktree" child-id)
          nil)
         (t
          (let ((merge-ok (org-agent--merge-worktree child-id integration-path)))
            (if (not merge-ok)
                (progn
                  (message "org-agent: rolling merge conflict on [%s] — leaving intact" child-id)
                  nil)
              (let ((new-tip (org-agent--git-ref-oid "HEAD" integration-path)))
                (if (or (string= new-tip target-tip)
                        (org-agent--advance-branch-ref target-branch new-tip target-tip))
                    (progn
                      (org-agent--remove-worktree child-id t)
                      (org-agent--remove-integration-worktree parent-id)
                      (message "org-agent: rolling-merged [%s] into %s" child-id target-branch)
                      t)
                  (message "org-agent: FAILED to advance %s after merging [%s]"
                           target-branch child-id)
                  nil)))))))))))

(defun org-agent--maybe-dispatch-next-in-chain (child-id)
  "If CHILD-ID has a TRIGGER property targeting successors, dispatch them.
Deferred by 1s to avoid re-entrancy with the current DONE transition.
Handles both single target ids(\"X\") and multi-target ids(\"X\" \"Y\")."
  (let* ((trigger (with-current-buffer (org-agent--org-buffer)
                    (save-excursion
                      (let ((pos (org-agent--find-heading-by-id child-id)))
                        (when pos
                          (goto-char pos)
                          (org-entry-get nil "TRIGGER")))))))
    (when (and trigger
               (string-match "ids(\\([^)]+\\))\\s-+todo!(NEXT)" trigger))
      (let* ((ids-str (match-string 1 trigger))
             (target-ids nil)
             (start 0))
        ;; Extract all quoted IDs from the ids(...) group
        (while (string-match "\"\\([^\"]+\\)\"" ids-str start)
          (push (match-string 1 ids-str) target-ids)
          (setq start (match-end 0)))
        (dolist (next-id (nreverse target-ids))
          ;; Verify the target actually transitioned to NEXT (edna did it)
          (let ((next-state (with-current-buffer (org-agent--org-buffer)
                              (save-excursion
                                (let ((pos (org-agent--find-heading-by-id next-id)))
                                  (when pos
                                    (goto-char pos)
                                    (org-get-todo-state)))))))
            (when (equal next-state "NEXT")
              (message "org-agent: chain auto-dispatch [%s] in 1s" next-id)
              (run-at-time 1 nil #'org-agent-dispatch next-id))))))))

;;;; State change advice — :around org-todo
;;
;; Wraps org-todo so that DONE transitions require a successful commit.
;; If the pre-commit hook fails, the state
;; is reverted and the node stays ACTIVE.

(defvar org-agent--inhibit-state-advice nil
  "When non-nil, the org-todo :around advice passes through without side effects.
Used to prevent recursion when reverting a failed DONE transition.")

(defun org-agent--on-state-change (orig-fn &rest args)
  "Around advice on `org-todo'.
Lets the state transition happen, then fires hooks.
NEXT→DONE: commit in worktree, close session.  Branch stays for parent review.
TODO→DONE: merge all DONE children's branches."
  (if (or org-agent--inhibit-state-advice
          (not (bound-and-true-p org-agent-mode)))
      (apply orig-fn args)
    ;; Capture pre-transition state.
    ;; Save point because org-edna triggers may move it to other headings.
    (let ((old-state (when (org-at-heading-p) (org-get-todo-state)))
          (saved-pos (point))
          (saved-buf (current-buffer)))
      (apply orig-fn args)
      ;; Restore point — org-edna triggers may move it to other headings.
      (when (buffer-live-p saved-buf)
        (set-buffer saved-buf))
      (goto-char saved-pos)
      (let* ((id (org-agent--heading-id))
             (new-state (org-get-todo-state)))
        ;; Fire state-change hook
        (when id
          (run-hook-with-args 'org-agent-state-change-hook
                              id old-state new-state))

        (when (and id (equal new-state "DONE"))
          (let ((title (org-agent--heading-title)))
            (cond
             ;; ── NEXT → DONE: commit in worktree, close session ──
             ;; Branch stays for parent to review before merging.
             ((equal old-state "NEXT")
              (let* ((commit-ok (if (org-agent--worktree-exists-p id)
                                    (org-agent--commit-in-worktree id title)
                                  (org-agent--auto-commit id title)))
                     ;; Post-commit sanity: if worktree still dirty, the commit
                     ;; silently did nothing (branch has no delta = lost work).
                     (commit-ok (and commit-ok
                                     (not (and (org-agent--worktree-exists-p id)
                                               (org-agent--worktree-dirty-p id))))))
                (if commit-ok
                    (let ((merge-ok (when org-agent-use-worktrees
                                      ;; Record file ownership before merge
                                      ;; (branch still exists at this point)
                                      (org-agent--record-owns-paths id)
                                      (org-agent--rolling-merge-child id))))
                      (org-agent--notify-parent id title)
                      (org-agent--close-session id)
                      ;; NOTE: do NOT set BACKEND on the heading here.
                      ;; That pollutes chain successors who inherit BACKEND.
                      (org-agent--maybe-prompt-parent-review)
                      ;; Auto-dispatch next in chain (deferred)
                      (when merge-ok
                        (org-agent--maybe-dispatch-next-in-chain id)))
                  (let ((err-msg (format "DONE blocked — %s. Fix and retry mark-done."
                                         (if (and (org-agent--worktree-exists-p id)
                                                  (org-agent--worktree-dirty-p id))
                                             "worktree still dirty after commit (changes not captured)"
                                           "commit failed"))))
                    (message "org-agent: [%s] %s" id err-msg)
                    (let ((org-agent--inhibit-state-advice t))
                      (org-todo "NEXT"))
                    ;; Notify the agent so it knows to act
                    (condition-case nil
                        (org-agent-send id err-msg t)
                      (error nil))))))

             ;; ── TODO → DONE: merge all DONE children's branches ──
             ((equal old-state "TODO")
              (let ((open-children
                     (save-excursion
                       (org-back-to-heading t)
                       (let ((parent-level (org-current-level))
                             (open nil))
                         (when (outline-next-heading)
                           (while (and (org-at-heading-p)
                                       (> (org-current-level) parent-level))
                             (when (and (= (org-current-level) (1+ parent-level))
                                        (member (org-get-todo-state) '("TODO" "NEXT")))
                               (push (format "[%s] %s"
                                             (or (org-agent--heading-id) "?")
                                             (org-get-heading t t t t))
                                     open))
                             (unless (outline-next-heading)
                               (goto-char (point-max)))))
                         (nreverse open)))))
                (if open-children
                    (let ((msg (format "BLOCKED: mark-done failed — %d open children: %s. Dispatch or mark-done children first."
                                       (length open-children)
                                       (string-join open-children ", "))))
                      (message "org-agent: [%s] %s" id msg)
                      (let ((org-agent--inhibit-state-advice t))
                        (org-todo "TODO"))
                      (ignore-errors (org-agent-send id msg t)))
                  ;; Check if all children are already merged (chain case)
                  (let* ((done-children (save-excursion
                                          (org-agent--collect-children-by-state "DONE")))
                         (unmerged (when org-agent-use-worktrees
                                     (cl-remove-if-not
                                      (lambda (child)
                                        (org-agent--git-ref-exists-p
                                         (org-agent--worktree-branch
                                          (plist-get child :id))))
                                      done-children)))
                         (merge-ok (cond
                                    ((not org-agent-use-worktrees) t)
                                    ((null unmerged)
                                     ;; All already merged (chain case)
                                     t)
                                    (t
                                     ;; Fallback: big-bang merge for non-chain children
                                     (org-agent--merge-children-worktrees id)))))
                    (if merge-ok
                        (progn
                          (org-agent--notify-parent id title)
                          (org-agent--close-session id)
                          (org-agent--maybe-prompt-parent-review))
                      (let ((msg "BLOCKED: mark-done failed — merge conflict. Resolve conflicts, then retry mark-done."))
                        (message "org-agent: [%s] %s" id msg)
                        (let ((org-agent--inhibit-state-advice t))
                          (org-todo "TODO"))
                        (ignore-errors (org-agent-send id msg t)))))))))))))))

(defun org-agent--close-session (node-id)
  "Kill the CC buffer for NODE-ID if it exists.
Does NOT purge the persisted session (history is kept for review).
Sends SIGTERM to the process and installs a sentinel that cleans up
the buffer once the process actually exits.  This avoids an arbitrary
timer delay — the process gets a graceful shutdown signal and the
buffer is reaped only after exit is confirmed."
  (when node-id
    (let* ((buf-name (org-agent--cc-buffer-name node-id))
           (cc-buf (get-buffer buf-name))
           (proc (and cc-buf (buffer-live-p cc-buf)
                      (get-buffer-process cc-buf))))
      (cond
       (proc
        ;; Install sentinel to kill buffer after process exits
        (set-process-sentinel
         proc
         (lambda (process _event)
           (when (memq (process-status process) '(exit signal))
             (let ((buf (process-buffer process)))
               (when (buffer-live-p buf)
                 (kill-buffer buf)))
             (message "Closed CC session for [%s]" node-id))))
        ;; Graceful shutdown
        (signal-process proc 'SIGTERM))
       ;; No process but buffer exists — just kill
       (cc-buf
        (kill-buffer cc-buf)
        (message "Closed CC session for [%s]" node-id))))))

(defun org-agent--review-session-ids-for-heading (node-id state)
  "Return live review/read-only session IDs associated with NODE-ID.
For DONE headings this includes the reopened read-only NODE-ID session
plus the synthetic NODE-ID/review session.  For non-DONE headings only
the synthetic review session is considered so active edit sessions are
left alone."
  (let ((candidates (list (concat node-id "/review"))))
    (when (equal state "DONE")
      (push node-id candidates))
    (cl-remove-if-not
     (lambda (session-id)
       (let ((buf (gethash session-id org-agent--sessions)))
         (and buf (buffer-live-p buf))))
     candidates)))

;;;###autoload
(defun org-agent-finish-review ()
  "Close review/read-only sessions associated with the heading at point.
This is the clean closeout path for reopened DONE nodes and synthetic
`/review' sessions without needing another state transition."
  (interactive)
  (unless (org-at-heading-p)
    (org-back-to-heading t))
  (let* ((id (or (org-agent--heading-id)
                 (org-agent--slug-id (org-agent--heading-title))))
         (state (org-get-todo-state)))
    (unless id
      (user-error "No node ID at point"))
    (let ((session-ids (org-agent--review-session-ids-for-heading id state)))
      (if (null session-ids)
          (message "No live review sessions for [%s]" id)
        (dolist (session-id session-ids)
          (org-agent--close-session session-id))
        (message "Closing %d review session(s) for [%s]"
                 (length session-ids) id)))))

;;;###autoload
(defun org-agent--ensure-fresh-buffer (file)
  "Return the buffer for FILE, reverting if the disk copy is newer.
This prevents stale-buffer conflicts when multiple agents edit concurrently.
When FILE is the project TODO.org, delegates to `org-agent--org-buffer'
to ensure a single canonical buffer is used."
  ;; Use canonical buffer for the project TODO.org
  (if (string= (expand-file-name file)
               (expand-file-name (org-agent--todo-file)))
      (org-agent--org-buffer)
    (let ((buf (find-file-noselect file)))
      (with-current-buffer buf
        (unless (bound-and-true-p org-agent-mode)
          (org-agent-mode 1))
        (when (and (buffer-file-name)
                   (file-exists-p (buffer-file-name))
                   (not (verify-visited-file-modtime buf)))
          (revert-buffer t t t)))
      buf)))

;;;###autoload
(defun org-agent-mark-review (node-id &optional org-file)
  "Alias for `org-agent-mark-done'.  Kept for backward compatibility.
NEXT agents call this to commit + close:
  emacsclient -e \\='(org-agent-mark-review \"C-1\")\\='"
  (org-agent-mark-done node-id org-file))

(defun org-agent--clear-satisfied-blocker ()
  "Remove BLOCKER property if all referenced blockers are satisfied.
org-edna BLOCKER properties like `ids(Z-4p3) done?' silently prevent
state transitions even when the referenced heading IS done, due to
buffer/timing issues.  This function checks each referenced ID and
clears the BLOCKER if all are satisfied (DONE state)."
  (let ((blocker (org-entry-get nil "BLOCKER")))
    (when blocker
      (let ((ids nil)
            (all-done t))
        (save-match-data
          (let ((start 0))
            (while (string-match "ids(\\([^)]+\\))" blocker start)
              (let ((id-str (match-string 1 blocker)))
                (dolist (raw-id (split-string id-str "[, \t\"']+" t))
                  (push raw-id ids)))
              (setq start (match-end 0)))))
        (dolist (ref-id ids)
          (let ((ref-pos (org-agent--find-heading-by-id ref-id)))
            (if ref-pos
                (save-excursion
                  (goto-char ref-pos)
                  (unless (equal (org-get-todo-state) "DONE")
                    (setq all-done nil)))
              (setq all-done nil))))
        (when (and ids all-done)
          (org-entry-delete nil "BLOCKER")
          (message "org-agent: cleared satisfied BLOCKER (all refs DONE)"))))))

;;;###autoload
(defun org-agent-mark-done (node-id &optional org-file)
  "Mark NODE-ID as DONE.
NEXT→DONE: commit in worktree, close session.  Branch stays for parent merge.
TODO→DONE: merge all DONE children's branches.  If merge fails, reverts to TODO.
  emacsclient -e \\='(org-agent-mark-done \"Z-3h\")\\='"
  (let* ((root (org-agent--resolve-project-root))
         (file (or org-file (expand-file-name "TODO.org" root))))
    (with-current-buffer (org-agent--ensure-fresh-buffer file)
      (let ((pos (org-agent--find-heading-by-id node-id)))
        (unless pos
          (error "Heading [%s] not found" node-id))
        (goto-char pos)
        (org-agent--clear-satisfied-blocker)
        (org-todo "DONE")
        (let ((post-state (org-get-todo-state)))
          (unless (equal post-state "DONE")
            (message "org-agent: [%s] DONE transition blocked (state=%s) — check BLOCKER properties"
                     node-id post-state)))
        (save-buffer)))
    (let ((final-state (with-current-buffer
                           (org-agent--ensure-fresh-buffer
                            (or org-file (expand-file-name "TODO.org" root)))
                         (let ((pos (org-agent--find-heading-by-id node-id)))
                           (when pos
                             (goto-char pos)
                             (org-get-todo-state))))))
      (if (equal final-state "DONE")
          (format "Marked [%s] DONE — merge succeeded" node-id)
        (format "DONE blocked for [%s] — still %s (check BLOCKER property)"
                node-id final-state)))))

;;;###autoload
(defun org-agent-add-note (node-id note &optional org-file)
  "Append NOTE text under NODE-ID's heading body.
Agents MUST use this instead of editing TODO.org directly.
  emacsclient -e \\='(org-agent-add-note \"C-1\" \"Found edge case in X.\")\\='"
  (let* ((root (org-agent--resolve-project-root))
         (file (or org-file (expand-file-name "TODO.org" root))))
    (with-current-buffer (org-agent--ensure-fresh-buffer file)
      (let ((pos (org-agent--find-heading-by-id node-id)))
        (unless pos
          (error "Heading [%s] not found" node-id))
        (goto-char pos)
        (org-end-of-subtree t)
        (insert "\n" note "\n")
        (save-buffer)))
    (format "Note added to [%s]" node-id)))

;;;###autoload
(defun org-agent-set-state (node-id new-state &optional org-file)
  "Set NODE-ID's TODO state to NEW-STATE.
Agents MUST use this instead of editing TODO.org directly.
NEXT agents MUST use `org-agent-mark-done' to transition to DONE —
set-state to DONE is blocked for NEXT agents to prevent bypassing
the commit/merge/notify pipeline.
  emacsclient -e \\='(org-agent-set-state \"C-1\" \"DONE\")\\='"
  (let* ((root (org-agent--resolve-project-root))
         (file (or org-file (expand-file-name "TODO.org" root))))
    (with-current-buffer (org-agent--ensure-fresh-buffer file)
      (let ((pos (org-agent--find-heading-by-id node-id)))
        (unless pos
          (error "Heading [%s] not found" node-id))
        (goto-char pos)
        ;; Block NEXT→DONE via set-state — agents must use mark-done
        (when (and (equal new-state "DONE")
                   (equal (org-get-todo-state) "NEXT"))
          (let ((msg (format "BLOCKED: [%s] is NEXT — use (org-agent-mark-done \"%s\") instead of set-state. mark-done handles commit, merge, and notification."
                             node-id node-id)))
            (ignore-errors (org-agent-send node-id msg t))
            (error "%s" msg)))
        ;; Block TODO→DONE if any direct child is still TODO or NEXT
        (when (and (equal new-state "DONE")
                   (equal (org-get-todo-state) "TODO"))
          (let ((open nil)
                (parent-level (org-current-level)))
            (save-excursion
              (when (outline-next-heading)
                (while (and (org-at-heading-p)
                            (> (org-current-level) parent-level))
                  (when (and (= (org-current-level) (1+ parent-level))
                             (member (org-get-todo-state) '("TODO" "NEXT")))
                    (push (org-get-heading t t t t) open))
                  (unless (outline-next-heading)
                    (goto-char (point-max))))))
            (when open
              (let ((msg (format "BLOCKED: [%s] has %d open children: %s. Use mark-done on children first, or dispatch them."
                                 node-id (length open)
                                 (string-join (nreverse open) ", "))))
                (ignore-errors (org-agent-send node-id msg t))
                (error "%s" msg)))))
        (org-todo new-state)
        (save-buffer)))
    (format "Set [%s] to %s" node-id new-state)))

;;;###autoload
(defun org-agent-add-child (parent-id title &optional state org-file)
  "Add a child heading under PARENT-ID with TITLE and optional STATE.
Agents MUST use this instead of editing TODO.org directly.
Rejects duplicate bracket IDs.  If the parent is DONE, reopens it to TODO.
  emacsclient -e \\='(org-agent-add-child \"Z-1\" \"New sub-task\" \"TODO\")\\='"
  (let* ((root (org-agent--resolve-project-root))
         (file (or org-file (expand-file-name "TODO.org" root)))
         (todo-state (or state "TODO"))
         (bracket-id (when (string-match "\\[\\([^]]+\\)\\]" title)
                       (match-string 1 title))))
    ;; Reject duplicate IDs
    (when bracket-id
      (with-current-buffer (org-agent--ensure-fresh-buffer file)
        (let ((existing (org-agent--find-heading-by-id bracket-id)))
          (when existing
            (error "BLOCKED: ID [%s] already exists in the org tree. Choose a unique ID."
                   bracket-id)))))
    (with-current-buffer (org-agent--ensure-fresh-buffer file)
      (let ((pos (org-agent--find-heading-by-id parent-id)))
        (unless pos
          (error "Heading [%s] not found" parent-id))
        (goto-char pos)
        ;; Bubble-up: reopen DONE parent to TODO when adding a child
        (when (equal (org-get-todo-state) "DONE")
          (let ((org-agent--inhibit-state-advice t))
            (org-todo "TODO"))
          (message "org-agent: reopened [%s] to TODO (new child added)" parent-id))
        (let ((level (1+ (org-current-level))))
          (org-end-of-subtree t)
          (insert "\n" (make-string level ?*) " " todo-state " " title "\n")
          ;; Set :ID: property for org-edna ids() finder
          (forward-line -1)
          (org-back-to-heading t)
          (when bracket-id
            (org-entry-put nil "ID" bracket-id)
            (org-id-add-location bracket-id (org-agent--todo-file)))
          (save-buffer))))
    (format "Added child '%s' under [%s]" title parent-id)))

;;;###autoload
(defun org-agent-add-chain (parent-id specs &optional org-file)
  "Add a chain of sequential children under PARENT-ID.
SPECS is a list of title strings (each containing [bracket-id]).
First child starts as NEXT; rest start as TODO with BLOCKER/TRIGGER
properties that enforce sequential execution via org-edna.

  emacsclient -e \\='(org-agent-add-chain \"Z-4\"
    (list \"[Z-4a] Define types\" \"[Z-4b] Implement\" \"[Z-4c] Test\"))\\='

Returns list of created bracket IDs."
  (let* ((root (org-agent--resolve-project-root))
         (file (or org-file (expand-file-name "TODO.org" root)))
         (ids nil))
    ;; First pass: create all headings
    (dolist (spec specs)
      (let ((state (if (eq spec (car specs)) "NEXT" "TODO")))
        (org-agent-add-child parent-id spec state org-file)
        (when (string-match "\\[\\([^]]+\\)\\]" spec)
          (push (match-string 1 spec) ids))))
    (setq ids (nreverse ids))
    ;; Second pass: wire BLOCKER/TRIGGER properties
    (with-current-buffer (org-agent--ensure-fresh-buffer file)
      (let ((len (length ids)))
        (dotimes (i len)
          (let* ((cur-id (nth i ids))
                 (pos (org-agent--find-heading-by-id cur-id)))
            (when pos
              (goto-char pos)
              ;; BLOCKER: wait for predecessor to be DONE
              (when (> i 0)
                (let ((prev-id (nth (1- i) ids)))
                  (org-entry-put nil "BLOCKER" (format "ids(\"%s\") done?" prev-id))))
              ;; TRIGGER: promote successor to NEXT when this goes DONE
              (when (< i (1- len))
                (let ((next-id (nth (1+ i) ids)))
                  (org-entry-put nil "TRIGGER" (format "ids(\"%s\") todo!(NEXT)" next-id))))))))
      (save-buffer))
    ;; Ensure parent has a git branch (needed for rolling merges)
    (let ((default-directory (org-agent--resolve-project-root)))
      (unless (org-agent--git-ref-exists-p parent-id)
        (call-process "git" nil nil nil "branch" parent-id
                      (org-agent--root-branch parent-id))))
    ids))

;;;###autoload
(defun org-agent-read-subtree (node-id &optional org-file)
  "Return the org subtree text under NODE-ID as a string.
Agents should use this to read their section of TODO.org without opening the full file.
  emacsclient -e \\='(org-agent-read-subtree \"Z-1\")\\='"
  (let* ((root (org-agent--resolve-project-root))
         (file (or org-file (expand-file-name "TODO.org" root))))
    (with-current-buffer (org-agent--ensure-fresh-buffer file)
      (let ((pos (org-agent--find-heading-by-id node-id)))
        (unless pos
          (error "Heading [%s] not found" node-id))
        (goto-char pos)
        (let ((beg (point))
              (end (save-excursion (org-end-of-subtree t) (point))))
          (buffer-substring-no-properties beg end))))))

(defun org-agent--sibling-status-summary ()
  "Return a summary string of sibling completion status.
Must be called with point on a child heading (will walk up to parent).
Returns a string like \"3/5 children DONE\" or nil if no parent."
  (save-excursion
    (when (org-up-heading-safe)
      (let ((total 0)
            (done 0))
        (save-excursion
          (let ((parent-level (org-current-level)))
            (when (outline-next-heading)
              (while (and (org-at-heading-p)
                          (> (org-current-level) parent-level))
                (when (= (org-current-level) (1+ parent-level))
                  (cl-incf total)
                  (let ((child-state (org-get-todo-state)))
                    (when (equal child-state "DONE")
                      (cl-incf done))))
                (unless (outline-next-heading)
                  (goto-char (point-max)))))))
        (format "%d/%d children DONE" done total)))))

(defun org-agent--notify-parent (child-id child-title)
  "Notify the nearest ancestor with a live CC session that CHILD-ID is DONE.
Walks up the org tree from the immediate parent.  If a given ancestor
has no live session, continues to its parent, prepending context.
Stops at the first ancestor that accepts the message, or at the root."
  (let ((summary (org-agent--sibling-status-summary)))
    (save-excursion
      (let ((notified nil))
        (while (and (not notified) (org-up-heading-safe))
          (let ((ancestor-id (org-agent--heading-id)))
            (when ancestor-id
              (let ((msg (format "Child [%s] (%s) is DONE. Progress: %s."
                                 child-id child-title (or summary "unknown"))))
                (condition-case nil
                    (progn
                      (org-agent-send ancestor-id msg)
                      (setq notified t))
                  (error
                   ;; No live session — keep walking up
                   (message "org-agent: [%s] DONE (ancestor [%s] has no live session, trying higher)"
                            child-id ancestor-id)))))))
        (unless notified
          (message "org-agent: [%s] DONE — no ancestor with live session found"
                   child-id))))))

(defun org-agent--maybe-prompt-parent-review ()
  "If all sibling children of parent are DONE, prompt user to review parent."
  (save-excursion
    (when (org-up-heading-safe)
      (let ((parent-id (org-agent--heading-id))
            (parent-title (org-agent--heading-title))
            (all-done t))
        (save-excursion
          (let ((parent-level (org-current-level)))
            (when (outline-next-heading)
              (while (and (org-at-heading-p)
                          (> (org-current-level) parent-level))
                (when (= (org-current-level) (1+ parent-level))
                  (let ((child-state (org-get-todo-state)))
                    (unless (or (equal child-state "DONE")
                                (null child-state))
                      (setq all-done nil))))
                (unless (outline-next-heading)
                  (goto-char (point-max)))))))
        (when (and all-done parent-id)
          (message "All children of [%s] %s are DONE. Use C-c C-x r to review."
                   parent-id parent-title))))))

;;;; Agent dashboard — tree view mirroring org structure
;;
;; A read-only buffer rendering the org heading hierarchy with
;; per-node agent status (live buffer, persisted history, idle).
;; Navigation in the dashboard jumps to the corresponding CC buffer.

(defvar-local org-agent-dashboard--org-file nil
  "The org file this dashboard mirrors.")

(defvar-local org-agent-dashboard--expanded (make-hash-table :test 'equal)
  "Set of expanded node IDs in the dashboard.")

(defvar org-agent-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")   #'org-agent-dashboard-visit)
    (define-key map (kbd "s")     #'org-agent-dashboard-spawn)
    (define-key map (kbd "TAB")   #'org-agent-dashboard-toggle)
    (define-key map (kbd "k")     #'org-agent-dashboard-kill-node)
    (define-key map (kbd "K")     #'org-agent-kill-all-sessions)
    (define-key map (kbd "d")     #'org-agent-dashboard-purge-node)
    (define-key map (kbd "g")     #'org-agent-dashboard-refresh)
    (define-key map (kbd "o")     #'org-agent-dashboard-goto-org)
    (define-key map (kbd "q")     #'quit-window)
    (define-key map (kbd "n")     #'next-line)
    (define-key map (kbd "p")     #'previous-line)
    map)
  "Keymap for `org-agent-dashboard-mode'.")

(define-derived-mode org-agent-dashboard-mode special-mode "CC-Dash"
  "Major mode for the Claude Org agent dashboard.
Displays the org heading tree with per-node agent status.

\\{org-agent-dashboard-mode-map}")

(defun org-agent-dashboard--parse-tree (org-file)
  "Parse ORG-FILE into a flat list of heading plists.
Each plist has :id :title :state :level :has-children."
  (let ((headings nil))
    (with-current-buffer (org-agent--ensure-fresh-buffer org-file)
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (re-search-forward org-heading-regexp nil t)
         (let* ((level (org-current-level))
                (heading (org-get-heading t t t t))
                (state (org-get-todo-state))
                (id (when (string-match "^\\[\\([^]]+\\)\\]" heading)
                      (match-string 1 heading)))
                (title (string-trim
                        (replace-regexp-in-string
                         "^\\[[^]]+\\] *" "" heading)))
                (has-children
                 (save-excursion
                   (let ((end (save-excursion (org-end-of-subtree t t) (point))))
                     (outline-next-heading)
                     (and (< (point) end) (> (org-current-level) level))))))
           (push (list :level level
                       :id (or id (org-agent--slug-id title))
                       :title title
                       :state state
                       :has-children has-children)
                 headings)))))
    (nreverse headings)))

(defun org-agent-dashboard--render (headings session-map)
  "Render HEADINGS list with SESSION-MAP into current buffer."
  (let ((inhibit-read-only t)
        (min-level (apply #'min (mapcar (lambda (h) (plist-get h :level)) headings))))
    (erase-buffer)
    (insert (propertize "Agent Dashboard" 'face '(:height 1.3 :weight bold)) "\n")
    (insert (propertize (format "Source: %s\n" org-agent-dashboard--org-file)
                        'face '(:foreground "gray60")))
    ;; Legend
    (insert (propertize " BUSY" 'face '(:foreground "green3"))
            "  " (propertize " WAIT" 'face '(:foreground "yellow3"))
            "  " (propertize " DEAD" 'face '(:foreground "red3"))
            "  " (propertize " IDLE" 'face '(:foreground "gray50"))
            "\n\n")
    ;; Track parent visibility
    (let ((skip-below nil))
      (dolist (h headings)
        (let* ((level (plist-get h :level))
               (id (plist-get h :id))
               (title (plist-get h :title))
               (state (plist-get h :state))
               (has-children (plist-get h :has-children))
               (depth (- level min-level))
               (indent (make-string (* depth 2) ?\s))
               (uuid (gethash id session-map))
               (cc-buf (when uuid
                         (get-buffer (org-agent--cc-buffer-name id))))
               (alive (and cc-buf (buffer-live-p cc-buf)))
               (waiting (and alive
                             (gethash (org-agent--cc-buffer-name id)
                                      org-agent--buffer-ready)))
               (has-jsonl (when uuid (org-agent--session-jsonl-path uuid)))
               (expanded (gethash id org-agent-dashboard--expanded))
               (line-start nil))
          ;; Skip rendering if an ancestor is collapsed
          (when skip-below
            (if (> level skip-below)
                (cl-decf level 0)  ; skip — handled by the when check below
              (setq skip-below nil)))
          (unless (and skip-below (> level skip-below))
            (setq line-start (point))
            ;; Fold indicator
            (insert indent)
            (if has-children
                (insert (if expanded "▼ " "▶ "))
              (insert "  "))
            ;; Agent status icon: green=busy, yellow=waiting, cyan=history, gray=idle
            (insert (cond
                     (waiting (propertize "● " 'face '(:foreground "yellow3")))
                     (alive   (propertize "● " 'face '(:foreground "green3")))
                     (has-jsonl (propertize "● " 'face '(:foreground "red3")))
                     (t       (propertize "○ " 'face '(:foreground "gray50")))))
            ;; TODO state
            (when state
              (let ((state-face
                     (pcase state
                       ("TODO"   '(:foreground "red" :weight bold))
                       ("NEXT"   '(:foreground "DodgerBlue" :weight bold))
                       ("DONE"   '(:foreground "gray50"))
                       (_        '(:foreground "gray60")))))
                (insert (propertize state 'face state-face) " ")))
            ;; Node ID + title
            (when (plist-get h :id)
              (insert (propertize (format "[%s] " id)
                                  'face '(:foreground "gray50"))))
            (insert title)
            ;; Size annotation for live/history sessions
            (when has-jsonl
              (let ((size (file-attribute-size (file-attributes has-jsonl))))
                (when size
                  (insert (propertize
                           (format " (%s)" (file-size-human-readable size))
                           'face '(:foreground "gray50" :height 0.8))))))
            ;; Store node ID for navigation
            (put-text-property (or line-start (point)) (point)
                               'org-agent-node-id id)
            (insert "\n")
            ;; If collapsed and has children, skip children
            (when (and has-children (not expanded))
              (setq skip-below level))))))))

(defun org-agent-dashboard--id-at-point ()
  "Return the node ID at point in the dashboard."
  (get-text-property (line-beginning-position) 'org-agent-node-id))

;;;###autoload
(defun org-agent-dashboard ()
  "Open the agent dashboard for the current project.
Shows org tree structure with per-node CC agent status."
  (interactive)
  (let* ((root (org-agent--resolve-project-root))
         (org-file (expand-file-name "TODO.org" root))
         (buf-name (format "*cc-dash:%s*"
                           (file-name-nondirectory (directory-file-name root))))
         (buf (get-buffer-create buf-name)))
    (unless (file-exists-p org-file)
      (user-error "No TODO.org found at %s" root))
    (with-current-buffer buf
      (org-agent-dashboard-mode)
      (setq org-agent-dashboard--org-file org-file)
      (setq org-agent--project-root root)
      ;; Expand top two levels by default
      (let ((headings (org-agent-dashboard--parse-tree org-file))
            (session-map (org-agent--load-session-map)))
        (let ((min-level (apply #'min (mapcar (lambda (h) (plist-get h :level))
                                              headings))))
          (dolist (h headings)
            (when (<= (- (plist-get h :level) min-level) 1)
              (puthash (plist-get h :id) t org-agent-dashboard--expanded))))
        (org-agent-dashboard--render headings session-map)))
    (pop-to-buffer buf)))

(defun org-agent-dashboard-refresh ()
  "Re-render the dashboard from the org file."
  (interactive)
  (when org-agent-dashboard--org-file
    (let ((headings (org-agent-dashboard--parse-tree
                     org-agent-dashboard--org-file))
          (session-map (org-agent--load-session-map))
          (pos (point)))
      (org-agent-dashboard--render headings session-map)
      (goto-char (min pos (point-max))))))

(defun org-agent-dashboard-toggle ()
  "Toggle expand/collapse of node at point."
  (interactive)
  (let ((id (org-agent-dashboard--id-at-point)))
    (when id
      (if (gethash id org-agent-dashboard--expanded)
          (remhash id org-agent-dashboard--expanded)
        (puthash id t org-agent-dashboard--expanded))
      (org-agent-dashboard-refresh))))

(defun org-agent-dashboard-visit ()
  "Visit the CC session for node at point.
If no live session, offer to spawn one."
  (interactive)
  (let* ((id (org-agent-dashboard--id-at-point))
         (cc-buf (when id (get-buffer (org-agent--cc-buffer-name id)))))
    (cond
     ((null id) (message "No node at point"))
     ((and cc-buf (buffer-live-p cc-buf))
      (pop-to-buffer cc-buf))
     (t
      (when (yes-or-no-p (format "No live session for [%s]. Spawn? " id))
        (org-agent-dispatch id org-agent-dashboard--org-file)
        (org-agent-dashboard-refresh))))))

(defun org-agent-dashboard-spawn ()
  "Spawn a CC session for node at point."
  (interactive)
  (let ((id (org-agent-dashboard--id-at-point)))
    (when id
      (org-agent-dispatch id org-agent-dashboard--org-file)
      (org-agent-dashboard-refresh))))

(defun org-agent-dashboard-kill-node ()
  "Kill the CC session for node at point."
  (interactive)
  (let* ((id (org-agent-dashboard--id-at-point))
         (cc-buf (when id (get-buffer (org-agent--cc-buffer-name id)))))
    (when (and cc-buf (buffer-live-p cc-buf))
      (kill-buffer cc-buf))
    (when id
      (remhash id org-agent--sessions)
      (org-agent-dashboard-refresh)
      (message "Killed session for [%s]" id))))

(defun org-agent-dashboard-purge-node ()
  "Purge persisted session for node at point."
  (interactive)
  (let ((id (org-agent-dashboard--id-at-point)))
    (when (and id (yes-or-no-p (format "Purge session for [%s]? " id)))
      (org-agent--delete-session id)
      (let ((cc-buf (get-buffer (org-agent--cc-buffer-name id))))
        (when (and cc-buf (buffer-live-p cc-buf))
          (kill-buffer cc-buf)))
      (remhash id org-agent--sessions)
      (org-agent-dashboard-refresh)
      (message "Purged [%s]" id))))

(defun org-agent-dashboard-goto-org ()
  "Jump to the heading in the org file for node at point."
  (interactive)
  (let ((id (org-agent-dashboard--id-at-point)))
    (when id
      (let ((buf (org-agent--ensure-fresh-buffer org-agent-dashboard--org-file)))
        (pop-to-buffer buf)
        (let ((pos (org-agent--find-heading-by-id id)))
          (when pos
            (goto-char pos)
            (org-reveal)))))))

;;;###autoload
(defun org-agent-switch-session ()
  "Switch to a CC session buffer using completing-read."
  (interactive)
  (let ((candidates nil))
    (dolist (buf (buffer-list))
      (when (string-match "\\*claude:.*:\\(.*\\)\\*" (buffer-name buf))
        (push (cons (match-string 1 (buffer-name buf)) buf) candidates)))
    (if (null candidates)
        (message "No active CC sessions")
      (let* ((choice (completing-read "CC session: " candidates nil t))
             (buf (cdr (assoc choice candidates))))
        (when buf (pop-to-buffer buf))))))

;;;###autoload
(defun org-agent-kill-all-sessions ()
  "Kill all CC session buffers.  Prompts for confirmation."
  (interactive)
  (let ((bufs (cl-remove-if-not
               (lambda (buf)
                 (string-match-p "\\*claude:.*\\*" (buffer-name buf)))
               (buffer-list))))
    (when (and bufs
               (yes-or-no-p (format "Kill %d CC session buffers? " (length bufs))))
      (dolist (buf bufs)
        (kill-buffer buf))
      (clrhash org-agent--sessions)
      (message "Killed %d sessions" (length bufs)))))

;;;; CC buffer list — dired-style session management

(defvar org-agent-buffers-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "d")   #'org-agent-buffers-mark-delete)
    (define-key map (kbd "u")   #'org-agent-buffers-unmark)
    (define-key map (kbd "U")   #'org-agent-buffers-unmark-all)
    (define-key map (kbd "x")   #'org-agent-buffers-execute)
    (define-key map (kbd "RET") #'org-agent-buffers-visit)
    (define-key map (kbd "o")   #'org-agent-buffers-visit-other)
    (define-key map (kbd "g")   #'org-agent-buffers-refresh)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `org-agent-buffers-mode'.")

(define-derived-mode org-agent-buffers-mode tabulated-list-mode "CC-Bufs"
  "Major mode for managing CC agent session buffers.
\\{org-agent-buffers-mode-map}"
  (setq tabulated-list-format
        [("" 1 t)              ; mark column
         ("Node" 20 t)
         ("Status" 10 t)
         ("Buffer" 45 t)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun org-agent-buffers--entries ()
  "Build tabulated-list entries from live CC session buffers."
  (let (entries)
    (maphash
     (lambda (k v)
       (when (and v (buffer-live-p v))
         (let* ((id (substring-no-properties k))
                (wins (get-buffer-window-list v nil t))
                (agent-st (org-agent--agent-status k))
                (status (cond
                         ((eq agent-st 'waiting) "waiting")
                         (wins                   "visible")
                         (t                      "background")))
                (status-face (cond
                              ((eq agent-st 'waiting) 'org-agent-status-waiting)
                              (wins                   'success)
                              (t                      'shadow))))
           (push (list id
                       (vector ""
                               id
                               (propertize status 'face status-face)
                               (buffer-name v)))
                 entries))))
     org-agent--sessions)
    (sort entries (lambda (a b) (string< (car a) (car b))))))

(defvar-local org-agent-buffers--marked nil
  "Set of node-IDs marked for deletion.")

(defun org-agent-buffers-mark-delete ()
  "Mark the session at point for deletion."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (add-to-list 'org-agent-buffers--marked id)
      (tabulated-list-set-col 0 (propertize "D" 'face 'error))
      (forward-line 1))))

(defun org-agent-buffers-unmark ()
  "Remove mark from session at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (setq org-agent-buffers--marked (delete id org-agent-buffers--marked))
      (tabulated-list-set-col 0 "")
      (forward-line 1))))

(defun org-agent-buffers-unmark-all ()
  "Remove all marks."
  (interactive)
  (setq org-agent-buffers--marked nil)
  (org-agent-buffers-refresh))

(defun org-agent-buffers-execute ()
  "Kill all sessions marked with D."
  (interactive)
  (when (and org-agent-buffers--marked
             (yes-or-no-p (format "Kill %d marked session(s)? "
                                  (length org-agent-buffers--marked))))
    (dolist (id org-agent-buffers--marked)
      (let ((buf (gethash id org-agent--sessions)))
        (when (and buf (buffer-live-p buf))
          ;; Stop the process first to avoid "deleting selected buffer"
          ;; errors from vterm's process filter.
          (let ((proc (get-buffer-process buf)))
            (when proc
              (set-process-query-on-exit-flag proc nil)
              (delete-process proc)))
          (kill-buffer buf))
        (remhash id org-agent--sessions)))
    (setq org-agent-buffers--marked nil)
    (org-agent-buffers-refresh)
    (org-agent--refresh-all-overlays)
    (org-agent--update-modeline)))

(defun org-agent-buffers-visit ()
  "Switch to the session buffer at point."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (buf (when id (gethash id org-agent--sessions))))
    (when (and buf (buffer-live-p buf))
      (pop-to-buffer buf))))

(defun org-agent-buffers-visit-other ()
  "Display the session buffer at point in another window."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (buf (when id (gethash id org-agent--sessions))))
    (when (and buf (buffer-live-p buf))
      (display-buffer buf '(display-buffer-use-some-window)))))

(defun org-agent-buffers-refresh ()
  "Refresh the CC buffer list."
  (interactive)
  (setq tabulated-list-entries (org-agent-buffers--entries))
  (tabulated-list-print t))

;;;###autoload
(defun org-agent-buffers ()
  "Open a buffer-list style manager for CC agent sessions.
\\<org-agent-buffers-mode-map>
\\[org-agent-buffers-mark-delete] mark for deletion, \
\\[org-agent-buffers-execute] execute, \
\\[org-agent-buffers-unmark] unmark, \
\\[org-agent-buffers-visit] visit, \
\\[quit-window] quit."
  (interactive)
  (let ((buf (get-buffer-create "*CC Sessions*")))
    (with-current-buffer buf
      (org-agent-buffers-mode)
      (org-agent-buffers-refresh))
    (pop-to-buffer buf)))

;;;; Quick capture — file TODO nodes from any buffer

(defvar org-agent--capture-context nil
  "Plist of context captured from source window before org-capture runs.
Keys: :file :mode :region :nearby :line.")

(defun org-agent--next-inbox-id (org-file)
  "Return the next available I-N ID from ORG-FILE."
  (let ((max-n 0))
    (with-current-buffer (org-agent--ensure-fresh-buffer org-file)
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (re-search-forward "\\[I-\\([0-9]+\\)\\]" nil t)
         (let ((n (string-to-number (match-string 1))))
           (when (> n max-n) (setq max-n n))))))
    (format "I-%d" (1+ max-n))))

(defun org-agent--grab-source-context ()
  "Capture context from the current buffer for injection into a TODO node."
  (let* ((root (org-agent--resolve-project-root))
         (file (when (buffer-file-name)
                 (file-relative-name (file-truename (buffer-file-name))
                                     (file-name-as-directory
                                      (file-truename root)))))
         (mode-name (symbol-name major-mode))
         (line (line-number-at-pos))
         (region (when (use-region-p)
                   (let ((text (buffer-substring-no-properties
                                (region-beginning) (region-end))))
                     ;; Cap at 50 lines
                     (let ((lines (split-string text "\n")))
                       (if (> (length lines) 50)
                           (concat (string-join (cl-subseq lines 0 50) "\n")
                                   "\n... (truncated)")
                         text)))))
         (nearby (unless region
                   ;; Grab ~10 lines around point
                   (let ((start (save-excursion
                                  (forward-line -5)
                                  (line-beginning-position)))
                         (end (save-excursion
                                (forward-line 6)
                                (line-end-position))))
                     (buffer-substring-no-properties start end)))))
    (list :file file :mode mode-name :line line
          :region region :nearby nearby)))

(defun org-agent--format-source-context (ctx)
  "Format context plist CTX as inline props for a TODO heading."
  (let ((parts nil))
    (when (plist-get ctx :file)
      (push (format "- `source`: `%s:%d` (%s)"
                    (plist-get ctx :file)
                    (plist-get ctx :line)
                    (plist-get ctx :mode))
            parts))
    (when (plist-get ctx :region)
      (push (format "- `context`:\n  #+begin_src\n%s\n  #+end_src"
                    (plist-get ctx :region))
            parts))
    (when (plist-get ctx :nearby)
      (push (format "- `context`:\n  #+begin_src\n%s\n  #+end_src"
                    (plist-get ctx :nearby))
            parts))
    (string-join (nreverse parts) "\n")))

;;;###autoload
(defun org-agent-capture ()
  "Capture a new TODO node into TODO.org with context from the current window.
Works from any buffer — grabs source file, line, and region/nearby code.
After capture, offers to spawn a CC plan agent to decompose the task.

Bind globally with: (global-set-key (kbd \"C-c n\") #\\='org-agent-capture)"
  (interactive)
  ;; Grab context BEFORE org-capture switches buffers
  (setq org-agent--capture-context (org-agent--grab-source-context))
  (let* ((root (org-agent--resolve-project-root))
         (org-file (org-agent--todo-file root))
         (node-id (org-agent--next-inbox-id org-file))
         (ctx-text (org-agent--format-source-context
                    org-agent--capture-context))
         ;; Build the capture template
         (template
          (concat "** TODO [" node-id "] %^{Title}\n"
                  "- `priority`: `%^{Priority|P2|P1|P0}`\n"
                  "- `scope`: %?\n"
                  (when (> (length ctx-text) 0)
                    (concat ctx-text "\n")))))
    ;; Set up org-capture with our template
    (let ((org-capture-templates
           `(("n" "New TODO node" entry
              (file+headline ,org-file "Inbox")
              ,template
              :empty-lines 1))))
      (org-capture nil "n")
      ;; After finalize hook — offer CC plan (must be global, not
      ;; buffer-local, because capture buffer is killed on finalize)
      (add-hook 'org-capture-after-finalize-hook
                (org-agent--make-post-capture-hook node-id org-file)))))

(defun org-agent--make-post-capture-hook (node-id org-file)
  "Return a one-shot hook that offers to spawn CC on NODE-ID.
Removes itself after running once."
  (let ((hook-fn nil))
    (setq hook-fn
          (lambda ()
            (remove-hook 'org-capture-after-finalize-hook hook-fn)
            ;; Only prompt if capture wasn't aborted
            (unless org-capture-abort
              (when (y-or-n-p
                     (format "Spawn CC to flesh out [%s]? " node-id))
                (org-agent-dispatch node-id org-file)))))))

;;;; Heading overlays — agent status indicators in org buffer

(defface org-agent-status-waiting
  '((t :foreground "#ff6b6b" :weight bold))
  "Face for agents waiting on user input."
  :group 'org-agent)

(defface org-agent-status-running
  '((t :foreground "#51cf66" :weight bold))
  "Face for agents actively working."
  :group 'org-agent)

(defface org-agent-status-idle
  '((t :foreground "#868e96"))
  "Face for agents with a live session but no activity."
  :group 'org-agent)

(defvar org-agent--status-overlays (make-hash-table :test 'equal)
  "Map from heading ID (plain string) to overlay.")

(defun org-agent--agent-status (node-id)
  "Return status symbol for NODE-ID: `waiting', `running', or nil.
NODE-ID is looked up in `org-agent--sessions' after stripping
text properties for robust matching."
  (let* ((clean-id (substring-no-properties node-id))
         (buf (or (gethash clean-id org-agent--sessions)
                  (gethash node-id org-agent--sessions))))
    (when (and buf (buffer-live-p buf))
      (let* ((buf-name (buffer-name buf))
             (sentinel (make-symbol "absent"))
             (ready-val (gethash buf-name org-agent--buffer-ready sentinel)))
        (cond
         ((eq ready-val sentinel) 'running)
         (ready-val               'waiting)
         (t                       'running))))))

(defun org-agent--status-label (status)
  "Return the raw label for STATUS."
  (pcase status
    ('waiting "waiting")
    ('running "running")
    (_        nil)))

(defun org-agent--status-string (status line-col)
  "Return right-aligned propertized indicator for STATUS.
LINE-COL is the current column at end of the heading line."
  (let ((label (org-agent--status-label status)))
    (when label
      (let* ((face (if (eq status 'waiting)
                       'org-agent-status-waiting
                     'org-agent-status-running))
             (tag (propertize (format ":%s:" label) 'face face))
             (tag-len (length (format ":%s:" label)))
             (win (get-buffer-window (current-buffer)))
             (edge (if win (1- (window-width win)) 77))
             (gap (max 1 (- edge line-col tag-len)))
             (pad (make-string gap ?\s)))
        (concat pad tag)))))

(defun org-agent--find-org-buffer ()
  "Find the live org buffer for this project's TODO.org."
  (let ((org-file (when org-agent--project-root
                    (expand-file-name "TODO.org" org-agent--project-root))))
    (when org-file (get-file-buffer org-file))))

(defun org-agent--live-node-ids ()
  "Return list of node-IDs with a CC buffer displayed in a window.
Background/stale buffers are excluded."
  (let (ids)
    (maphash (lambda (k v)
               (when (and v (buffer-live-p v)
                          (get-buffer-window-list v nil t))
                 (push (substring-no-properties k) ids)))
             org-agent--sessions)
    ids))

(defun org-agent--refresh-all-overlays ()
  "Add :running: overlays for headings that have open CC buffers."
  (org-agent--remove-all-overlays)
  (let ((org-buf (org-agent--find-org-buffer))
        (live-ids (org-agent--live-node-ids)))
    (when (and org-buf live-ids)
      (with-current-buffer org-buf
        (save-excursion
          (save-restriction
            (widen)
            (dolist (id live-ids)
              (let ((pos (org-agent--find-heading-by-id id)))
                (when pos
                  (goto-char pos)
                  (let* ((status (or (org-agent--agent-status id) 'running))
                         (eol (line-end-position))
                         (line-col (- eol (line-beginning-position)))
                         (status-str (org-agent--status-string status line-col))
                         ;; Place before the newline so org's invisible
                         ;; overlay on the newline doesn't hide us.
                         (anchor (max pos (1- eol)))
                         (ov (make-overlay anchor anchor)))
                    (overlay-put ov 'after-string status-str)
                    (overlay-put ov 'org-agent-status t)
                    (puthash id ov
                             org-agent--status-overlays)))))))))))
(defun org-agent--remove-all-overlays ()
  "Remove all status overlays."
  (maphash (lambda (_id ov)
             (when (overlayp ov) (delete-overlay ov)))
           org-agent--status-overlays)
  (clrhash org-agent--status-overlays))

;;;; Event-driven status via CC CLI hooks
;;
;; CC CLI fires hooks via emacsclient → claude-code-handle-hook →
;; claude-code-event-hook.  Requires hooks config in ~/.claude/settings.json:
;;   "Notification" → "claude-code-hook-wrapper notification"
;;   "Stop"         → "claude-code-hook-wrapper stop"

(defun org-agent--node-id-from-buffer-name (buf-name)
  "Extract node-ID from BUF-NAME by reverse-looking up sessions."
  (let ((found nil))
    ;; Find the org buffer with sessions
    (let ((org-buf (cl-find-if
                    (lambda (b)
                      (and (buffer-live-p b)
                           (buffer-local-value 'org-agent-mode b)))
                    (buffer-list))))
      (when org-buf
        (let ((sessions (buffer-local-value 'org-agent--sessions org-buf)))
          (maphash (lambda (id buf)
                     (when (and buf (buffer-live-p buf)
                                (string= (buffer-name buf) buf-name))
                       (setq found (substring-no-properties id))))
                   sessions))))
    found))

(defun org-agent--on-cc-event-overlay (message)
  "Handle CC CLI hook events to update waiting/running state.
MESSAGE is a plist with :type and :buffer-name from claude-code-event-hook.
Notification = agent waiting for input, activity/stop = agent working/done."
  ;; Update buffer-ready state
  (org-agent--on-cc-event message)
  ;; Notify user when an agent starts waiting
  (let ((type (plist-get message :type))
        (buf-name (plist-get message :buffer-name)))
    (when (eq type 'notification)
      (let ((node-id (org-agent--node-id-from-buffer-name buf-name)))
        (when node-id
          (message "CC: %s waiting for input — C-c j to jump" node-id)))))
  ;; Refresh UI
  (org-agent--refresh-all-overlays)
  (org-agent--update-modeline)
  (ignore-errors
    (let ((sb (get-buffer "*CC Sessions*")))
      (when (and sb (buffer-live-p sb))
        (with-current-buffer sb
          (let ((pos (point)))
            (setq tabulated-list-entries (org-agent-buffers--entries))
            (tabulated-list-print t)
            (goto-char (min pos (point-max)))))))))

;;;; Modeline lighter — CC[waiting/total]

(defvar org-agent--modeline-string ""
  "Current modeline string showing agent counts.")

(defun org-agent--waiting-node-ids ()
  "Return list of node-IDs whose agents are waiting for input."
  (let (ids)
    (let ((org-buf (cl-find-if
                    (lambda (b)
                      (and (buffer-live-p b)
                           (buffer-local-value 'org-agent-mode b)))
                    (buffer-list))))
      (when org-buf
        (let ((sessions (buffer-local-value 'org-agent--sessions org-buf)))
          (maphash (lambda (id buf)
                     (when (and buf (buffer-live-p buf))
                       (let ((ready (gethash (buffer-name buf)
                                             org-agent--buffer-ready)))
                         (when ready
                           (push (substring-no-properties id) ids)))))
                   sessions))))
    ids))

(defun org-agent--update-modeline ()
  "Recompute the modeline lighter.  Shows waiting agent names."
  (let ((waiting (org-agent--waiting-node-ids))
        (total (hash-table-count org-agent--status-overlays)))
    (setq org-agent--modeline-string
          (cond
           (waiting
            (propertize (format " CC: %s waiting"
                                (string-join (sort waiting #'string<) ", "))
                        'face 'warning))
           ((> total 0)
            (propertize (format " CC[%d]" total) 'face 'shadow))
           (t "")))))

(defun org-agent--modeline-segment ()
  "Return the modeline segment string."
  org-agent--modeline-string)

;;;; Jump to next waiting agent

(defun org-agent-next-waiting ()
  "Switch to the next CC agent buffer waiting for input."
  (interactive)
  (let ((waiting-bufs nil)
        (current (current-buffer)))
    (maphash (lambda (node-id buf)
               (when (and buf (buffer-live-p buf)
                          (eq (org-agent--agent-status node-id) 'waiting))
                 (push buf waiting-bufs)))
             org-agent--sessions)
    (if (null waiting-bufs)
        (message "No agents waiting for input.")
      (let* ((bufs (sort waiting-bufs
                         (lambda (a b) (string< (buffer-name a)
                                                (buffer-name b)))))
             (rest (cdr (memq current bufs)))
             (target (or (car rest) (car bufs))))
        (pop-to-buffer target)))))

;;;; Minor mode

(defvar org-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-x s") #'org-agent-spawn)
    (define-key map (kbd "C-c C-x x") #'org-agent-codex)
    (define-key map (kbd "C-c C-x b") #'org-agent-batch)
    (define-key map (kbd "C-c C-x p") #'org-agent-plan)
    (define-key map (kbd "C-c C-x r") #'org-agent-review)
    (define-key map (kbd "C-c C-x q") #'org-agent-finish-review)
    (define-key map (kbd "C-c C-x k") #'org-agent-kill)
    (define-key map (kbd "C-c C-x d") #'org-agent-purge-node)
    (define-key map (kbd "C-c C-x g") #'org-agent-show-diff)
    (define-key map (kbd "C-c C-x l") #'org-agent-dashboard)
    (define-key map (kbd "C-c C-x o") #'org-agent-switch-session)
    (define-key map (kbd "C-c C-x n") #'org-agent-capture)
    (define-key map (kbd "C-c C-x j") #'org-agent-next-waiting)
    map)
  "Keymap for `org-agent-mode'.")

;; Ensure new bindings picked up on reload (defvar skips if already bound).
(define-key org-agent-mode-map (kbd "C-c C-x j") #'org-agent-next-waiting)
(define-key org-agent-mode-map (kbd "C-c C-x x") #'org-agent-codex)
(define-key org-agent-mode-map (kbd "C-c C-x q") #'org-agent-finish-review)
;;;; Scroll preservation for vterm CC buffers
;;
;; vterm--filter moves window-point to the terminal cursor on every output
;; chunk.  When Claude Code is streaming, this yanks the user back to the
;; bottom if they scrolled up to read earlier output.  We advise the filter
;; to save/restore window-start for any CC window where the user has
;; scrolled away from the bottom.

(defun org-agent--vterm-preserve-scroll (orig-fun &rest args)
  "Around advice for `vterm--filter' that preserves scroll position.
If the user has scrolled up in a CC vterm buffer, restore their
window-start after the filter runs so they aren't yanked to the bottom."
  (let ((saved-windows nil))
    ;; Snapshot window state for CC buffers where user has scrolled up
    (dolist (frame (frame-list))
      (dolist (window (window-list frame 'no-minibuf))
        (let ((buf (window-buffer window)))
          (when (and buf
                     (buffer-live-p buf)
                     (string-match-p "\\*claude:.*\\*" (buffer-name buf)))
            (let* ((win-point (window-point window))
                   (win-start (window-start window))
                   (buf-end (with-current-buffer buf (point-max)))
                   ;; "At bottom" = window-point is within last 2 lines of buffer
                   (at-bottom (<= (- buf-end win-point) 200)))
              (unless at-bottom
                (push (list window win-start win-point) saved-windows)))))))
    ;; Run the original filter
    (apply orig-fun args)
    ;; Restore scroll position for windows that were scrolled up
    (dolist (entry saved-windows)
      (cl-destructuring-bind (window win-start win-point) entry
        (when (window-live-p window)
          (set-window-start window win-start t)
          (set-window-point window win-point))))))

;; Install the advice (idempotent — :around deduplicates by function identity)
(with-eval-after-load 'vterm
  (advice-add 'vterm--filter :around #'org-agent--vterm-preserve-scroll))

;;;###autoload
(define-minor-mode org-agent-mode
  "Minor mode for dispatching Claude Code agents from org headings.

Adds keybindings under C-c C-x for spawning CC agents with full
context (ancestors, subtree, methodology, workflow information).

\\{org-agent-mode-map}"
  :lighter (:eval (org-agent--modeline-segment))
  :keymap org-agent-mode-map
  (if org-agent-mode
      (progn
        ;; Set project root
        (setq org-agent--project-root
              (org-agent--resolve-project-root))
        ;; Initialize sessions hash
        (unless org-agent--sessions
          (setq org-agent--sessions (make-hash-table :test 'equal)))
        ;; Set up TODO keywords if not already configured
        (unless (cl-intersection org-agent--todo-keywords
                                 (mapcar #'car (org-collect-keywords '("TODO")))
                                 :test #'string=)
          (setq-local org-todo-keywords
                      '((sequence "TODO(t)" "NEXT(n)"
                                  "|" "DONE(d)"))))
        ;; Enable org-edna for declarative BLOCKER/TRIGGER task dependencies
        (org-edna-mode 1)
        ;; Enable auto-revert so external edits (from emacsclient helpers
        ;; called by CC agents) are picked up without prompting the user.
        (auto-revert-mode 1)
        ;; Advise org-todo for state change hooks + DONE commit gate
        (advice-add 'org-todo :around #'org-agent--on-state-change)
        ;; Advise term-make to preserve window layout during vterm dispatch
        (advice-add 'claude-code--term-make :around
                     #'org-agent--term-make-preserve-windows)
        ;; Register event hook for waiting/running detection
        (add-hook 'claude-code-event-hook #'org-agent--on-cc-event-overlay)
        ;; Prune stale git worktrees
        (org-agent--prune-worktrees)
        ;; Seed overlays for existing sessions
        (org-agent--refresh-all-overlays)
        (org-agent--update-modeline))
    ;; Teardown
    (remove-hook 'claude-code-event-hook #'org-agent--on-cc-event-overlay)
    (org-agent--remove-all-overlays)
    (advice-remove 'claude-code--term-make
                   #'org-agent--term-make-preserve-windows)))

;;;###autoload
(defun org-agent--maybe-activate ()
  "Auto-activate `org-agent-mode' in org files under project roots with .claude/."
  (when (and org-agent-auto-activate
             (derived-mode-p 'org-mode)
             (buffer-file-name))
    (let* ((root (vc-root-dir))
           (claude-dir (when root (expand-file-name ".claude" root))))
      (when (and claude-dir (file-directory-p claude-dir))
        (org-agent-mode 1)))))

;;;###autoload
(add-hook 'org-mode-hook #'org-agent--maybe-activate)

;; Global bindings — work from any buffer, not just org
(when org-agent-global-keybindings
  (global-set-key (kbd "C-c n") #'org-agent-capture)
  (global-set-key (kbd "C-c j") #'org-agent-next-waiting))

;;;; Guard script helpers

(defun org-agent-guard-script-path (name)
  "Return absolute path to guard script NAME."
  (expand-file-name name org-agent-data-directory))

;;;###autoload
(defun org-agent-install-hooks (&optional project-root)
  "Install PreToolUse hooks in .claude/settings.json.
Creates the file if needed.  Idempotent — removes old entries first.
PROJECT-ROOT defaults to the current project root."
  (interactive)
  (let* ((root (or project-root (org-agent--resolve-project-root)))
         (settings-dir (expand-file-name ".claude" root))
         (settings-file (expand-file-name "settings.json" settings-dir))
         (edit-guard (org-agent-guard-script-path "org-agent-edit-guard.sh"))
         (commit-guard (org-agent-guard-script-path "org-agent-commit-guard.sh"))
         (settings (if (file-readable-p settings-file)
                       (json-read-file settings-file)
                     nil))
         (hooks (cdr (assq 'hooks settings)))
         (pre-tool (cdr (assq 'PreToolUse hooks)))
         ;; Remove any existing org-agent or claude-org entries
         (filtered (cl-remove-if
                    (lambda (entry)
                      (let ((cmd (cdr (assq 'command (car (cdr (assq 'hooks entry)))))))
                        (and cmd (or (string-match-p "org-agent-" cmd)
                                     (string-match-p "claude-org-" cmd)))))
                    (append pre-tool nil)))
         ;; Build new entries
         (edit-entry `((matcher . "Edit|Write|NotebookEdit")
                       (hooks . [((type . "command")
                                  (command . ,edit-guard))])))
         (commit-entry `((matcher . "Bash")
                         (hooks . [((type . "command")
                                    (command . ,commit-guard))])))
         (new-pre-tool (vconcat (append filtered (list edit-entry commit-entry))))
         (new-hooks `((PreToolUse . ,new-pre-tool)))
         (permissions (cdr (assq 'permissions settings))))
    (unless (file-directory-p settings-dir)
      (make-directory settings-dir t))
    (let ((new-settings `((permissions . ,(or permissions '((allow . []))))
                          (hooks . ,new-hooks))))
      (with-temp-file settings-file
        (insert (json-encode new-settings)))
      ;; Pretty-print with jq if available
      (when (executable-find "jq")
        (let ((tmp (make-temp-file "settings" nil ".json")))
          (when (= 0 (call-process "jq" nil `(:file ,tmp) nil "." settings-file))
            (rename-file tmp settings-file t)))))
    (message "org-agent: installed hooks in %s" settings-file)))

;;;###autoload
(defun org-agent-init-project (&optional project-root)
  "Initialize org-agent for a project.
Creates state directory, installs hooks, copies template files."
  (interactive)
  (let* ((root (or project-root (org-agent--resolve-project-root)
                   default-directory))
         (state-dir (expand-file-name org-agent-state-directory root))
         (org-file (expand-file-name org-agent-org-filename root))
         (template-dir (expand-file-name "templates" org-agent-data-directory))
         (claude-md (expand-file-name org-agent-instructions-file root))
         (agents-md (expand-file-name ".agents.md" root))
         (gitignore (expand-file-name ".gitignore" root)))
    ;; 1. Create state directory
    (unless (file-directory-p state-dir)
      (make-directory state-dir t)
      (message "org-agent: created %s" state-dir))
    ;; 2. Install hooks
    (org-agent-install-hooks root)
    ;; 3. Copy CLAUDE.md template if not exists
    (let ((tmpl (expand-file-name "CLAUDE.md" template-dir)))
      (when (and (file-exists-p tmpl) (not (file-exists-p claude-md)))
        (let ((dir (file-name-directory claude-md)))
          (unless (file-directory-p dir)
            (make-directory dir t)))
        (copy-file tmpl claude-md)
        (message "org-agent: created %s" claude-md)))
    ;; 4. Copy .agents.md template if not exists
    (let ((tmpl (expand-file-name "agents.md" template-dir)))
      (when (and (file-exists-p tmpl) (not (file-exists-p agents-md)))
        (copy-file tmpl agents-md)
        (message "org-agent: created %s" agents-md)))
    ;; 5. Create org file if not exists
    (unless (file-exists-p org-file)
      (with-temp-file org-file
        (insert (format "#+TITLE: %s Task Board\n#+TODO: TODO(t) NEXT(n) | DONE(d)\n\n* Inbox\n"
                        (file-name-nondirectory (directory-file-name root)))))
      (message "org-agent: created %s" org-file))
    ;; 6. Update .gitignore
    (let ((wt-pattern (concat org-agent-worktree-directory "/"))
          (sessions-pattern (concat org-agent-state-directory "/sessions.el")))
      (when (file-writable-p gitignore)
        (let ((contents (if (file-exists-p gitignore)
                            (with-temp-buffer
                              (insert-file-contents gitignore)
                              (buffer-string))
                          "")))
          (let ((needs-write nil))
            (unless (string-match-p (regexp-quote wt-pattern) contents)
              (setq contents (concat contents "\n" wt-pattern))
              (setq needs-write t))
            (unless (string-match-p (regexp-quote sessions-pattern) contents)
              (setq contents (concat contents "\n" sessions-pattern))
              (setq needs-write t))
            (when needs-write
              (with-temp-file gitignore
                (insert contents))
              (message "org-agent: updated .gitignore"))))))
    (message "org-agent: project initialized at %s" root)))

;;;; Backward compatibility aliases

;; These allow existing projects, guard scripts, and running agents
;; to continue using claude-org-* names during migration.

(dolist (pair '((claude-org-dispatch . org-agent-dispatch)
               (claude-org-dispatch-batch . org-agent-dispatch-batch)
               (claude-org-send . org-agent-send)
               (claude-org-send-all . org-agent-send-all)
               (claude-org-mark-done . org-agent-mark-done)
               (claude-org-add-note . org-agent-add-note)
               (claude-org-add-child . org-agent-add-child)
               (claude-org-add-chain . org-agent-add-chain)
               (claude-org-set-state . org-agent-set-state)
               (claude-org-read-subtree . org-agent-read-subtree)
               (claude-org-mark-review . org-agent-mark-review)
               (claude-org-set-backend . org-agent-set-backend)
               (claude-org-broadcast . org-agent-broadcast)
               (claude-org-spawn . org-agent-spawn)
               (claude-org-batch . org-agent-batch)
               (claude-org-plan . org-agent-plan)
               (claude-org-review . org-agent-review)
               (claude-org-capture . org-agent-capture)
               (claude-org-next-waiting . org-agent-next-waiting)
               (claude-org-finish-review . org-agent-finish-review)
               ;; Internal functions called by guard scripts via emacsclient
               (claude-org--org-buffer . org-agent--org-buffer)
               (claude-org--find-heading-by-id . org-agent--find-heading-by-id)
               (claude-org--parent-id-at-point . org-agent--parent-id-at-point)))
  (defalias (car pair) (cdr pair)))

;; Compat variables
(defvaralias 'claude-org-default-backend 'org-agent-default-backend)
(defvaralias 'claude-org-review-backend 'org-agent-review-backend)
(defvaralias 'claude-org-backend-adapters 'org-agent-backend-adapters)

;; Old feature name — (require 'claude-org) still works
(provide 'claude-org)
(provide 'org-agent)
;;; org-agent.el ends here
