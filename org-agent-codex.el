;;; org-agent-codex.el --- Codex CLI terminal integration for org-agent -*- lexical-binding: t; -*-

;; Author: Bandit Project
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.0") (claude-code "0.4.0"))
;; Keywords: tools, ai

;;; Commentary:
;;
;; Thin wrapper around claude-code.el's terminal abstraction for Codex CLI.
;; Codex has no bell-based ready detection and different TUI rendering,
;; so this module provides:
;;
;; 1. Native TUI rendering (Codex draws its own bordered prompt)
;; 2. Heuristic ready-state detection via idle timer + prompt patterns
;; 3. org-agent-codex-event-hook (same plist format as claude-code-event-hook)
;; 4. Session file lookup in ~/.codex/sessions/
;; 5. Visual polish: header-line, tinted background, left-margin padding
;;
;; All terminal creation/configuration delegates to claude-code--term-*
;; generics -- this module only adds Codex-specific behavior on top.

;;; Code:

(require 'cl-lib)

;; claude-code.el provides the terminal abstraction layer
(declare-function claude-code--term-make "claude-code")
(declare-function claude-code--term-send-string "claude-code")
(declare-function claude-code--term-configure "claude-code")
(declare-function claude-code--term-setup-keymap "claude-code")
(declare-function claude-code--term-customize-faces "claude-code")

(defvar claude-code-terminal-backend)
(defvar claude-code-term-name)
(defvar org-agent--buffer-node-id)

;;;; Customization

(defgroup org-agent-codex nil
  "Codex CLI terminal integration."
  :group 'claude-code
  :prefix "org-agent-codex-")

(defcustom org-agent-codex-idle-ready-delay 2.0
  "Seconds of output silence before declaring Codex ready.
Codex has no bell or structured event to signal readiness,
so we use an idle timer as a heuristic."
  :type 'number
  :group 'org-agent-codex)

(defcustom org-agent-codex-prompt-ready-delay 0.5
  "Seconds to wait after detecting a prompt pattern before confirming ready.
A short confirmation delay avoids false positives from partial renders."
  :type 'number
  :group 'org-agent-codex)


;;;; Event hook (same format as claude-code-event-hook)

(defvar org-agent-codex-event-hook nil
  "Hook run when Codex CLI triggers events.
Functions receive one argument: a plist with :type and :buffer-name keys.
:type is \"ready\" (waiting for input) or \"activity\" (processing).")

;;;; Buffer-local state for ready detection

(defvar-local org-agent-codex--idle-timer nil
  "Idle timer for the current Codex buffer's ready detection.")

(defvar-local org-agent-codex--prompt-timer nil
  "Prompt confirmation timer for the current Codex buffer.")

(defvar-local org-agent-codex--last-output-time nil
  "Timestamp of the last output activity in this Codex buffer.")

(defvar-local org-agent-codex--is-ready nil
  "Non-nil when this Codex buffer is believed to be waiting for input.")

(defvar-local org-agent-codex--buffer-p nil
  "Non-nil in buffers created by `org-agent-codex--term-make'.")

(defvar-local org-agent-codex--launch-time nil
  "Timestamp when this Codex session was launched.
Used to identify which ~/.codex/sessions/ file belongs to this session.")

;;;; Ready-state detection

(defconst org-agent-codex--prompt-patterns
  (list
   "^> $"                              ; simple prompt
   "\\$ $"                             ; shell-style prompt
   "^codex> "                          ; named prompt
   "What would you like"               ; initial greeting prompt
   "Press Enter"                       ; confirmation prompt
   )
  "Regex patterns that indicate Codex is waiting for input.")

(defun org-agent-codex--output-contains-prompt-p (output)
  "Return non-nil if OUTPUT contains a Codex prompt pattern."
  (cl-some (lambda (pat)
             (string-match-p pat output))
           org-agent-codex--prompt-patterns))

(defun org-agent-codex--fire-event (type)
  "Fire a org-agent-codex-event-hook event of TYPE for the current buffer."
  (let ((message (list :type type
                       :buffer-name (buffer-name))))
    (run-hook-with-args 'org-agent-codex-event-hook message)))

(defun org-agent-codex--mark-ready ()
  "Mark the current Codex buffer as ready (waiting for input)."
  (unless org-agent-codex--is-ready
    (setq org-agent-codex--is-ready t)
    (org-agent-codex--fire-event "ready")))

(defun org-agent-codex--mark-busy ()
  "Mark the current Codex buffer as busy (processing)."
  (when org-agent-codex--is-ready
    (setq org-agent-codex--is-ready nil)
    (org-agent-codex--fire-event "activity")))

(defun org-agent-codex--idle-check ()
  "Called by the idle timer -- if enough silence has passed, declare ready."
  (when (and org-agent-codex--last-output-time
             (>= (- (float-time) org-agent-codex--last-output-time)
                 org-agent-codex-idle-ready-delay))
    (org-agent-codex--mark-ready)))

(defun org-agent-codex--prompt-confirm ()
  "Called by the prompt confirmation timer -- confirm ready state."
  (org-agent-codex--mark-ready))

(defun org-agent-codex--on-output (buf output)
  "Handle terminal OUTPUT in BUF for ready-state detection."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq org-agent-codex--last-output-time (float-time))
      ;; Any output means activity
      (org-agent-codex--mark-busy)
      ;; Cancel pending prompt confirmation
      (when (and org-agent-codex--prompt-timer (timerp org-agent-codex--prompt-timer))
        (cancel-timer org-agent-codex--prompt-timer)
        (setq org-agent-codex--prompt-timer nil))
      ;; Reset idle timer
      (when (and org-agent-codex--idle-timer (timerp org-agent-codex--idle-timer))
        (cancel-timer org-agent-codex--idle-timer))
      (let ((this-buf buf))
        (setq org-agent-codex--idle-timer
              (run-with-timer org-agent-codex-idle-ready-delay nil
                              (lambda ()
                                (when (buffer-live-p this-buf)
                                  (with-current-buffer this-buf
                                    (org-agent-codex--idle-check))))))
        ;; Check for prompt patterns
        (when (org-agent-codex--output-contains-prompt-p output)
          (setq org-agent-codex--prompt-timer
                (run-with-timer org-agent-codex-prompt-ready-delay nil
                                (lambda ()
                                  (when (buffer-live-p this-buf)
                                    (with-current-buffer this-buf
                                      (org-agent-codex--prompt-confirm)))))))))))

(defun org-agent-codex--install-output-monitor (buf)
  "Install an output monitor on BUF for ready-state detection.
Wraps the process filter to intercept output."
  (when (buffer-live-p buf)
    (let ((proc (get-buffer-process buf)))
      (when proc
        (let ((orig-filter (process-filter proc)))
          (set-process-filter
           proc
           (lambda (process output)
             ;; Run the original filter first
             (funcall orig-filter process output)
             ;; Then our monitoring
             (org-agent-codex--on-output (process-buffer process) output))))))))

(defun org-agent-codex--cleanup-timers ()
  "Cancel any active timers for the current buffer.
Intended for `kill-buffer-hook'."
  (when (and org-agent-codex--idle-timer (timerp org-agent-codex--idle-timer))
    (cancel-timer org-agent-codex--idle-timer))
  (when (and org-agent-codex--prompt-timer (timerp org-agent-codex--prompt-timer))
    (cancel-timer org-agent-codex--prompt-timer)))

;;;; Terminal wrapper functions
;;
;; These mirror the claude-code--term-* interface but add Codex-specific
;; behavior.  org-agent.el dispatches to these via the adapter registry.

(defun org-agent-codex--term-make (backend buffer-name program &optional switches)
  "Create a terminal for Codex CLI.
BACKEND is the terminal backend (eat or vterm).
BUFFER-NAME and PROGRAM are passed to `claude-code--term-make'.
SWITCHES are CLI arguments passed through to Codex."
  (require 'claude-code)
  ;; Let Codex use its native TUI (bordered prompt, etc.) -- no --no-alt-screen.
  (let ((buf (claude-code--term-make backend buffer-name program switches)))
    ;; Install the output monitor for ready-state detection
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq org-agent-codex--buffer-p t)
        (setq org-agent-codex--is-ready nil)
        (setq org-agent-codex--last-output-time (float-time))
        ;; Clean up timers on buffer kill
        (add-hook 'kill-buffer-hook #'org-agent-codex--cleanup-timers nil t))
      ;; Delay monitor install slightly to let the process start
      (let ((target-buf buf))
        (run-with-timer 0.5 nil
                        (lambda ()
                          (when (buffer-live-p target-buf)
                            (org-agent-codex--install-output-monitor target-buf))))))
    buf))

(defun org-agent-codex--term-send-string (backend string)
  "Send STRING to the Codex terminal using BACKEND.
Delegates to `claude-code--term-send-string' and marks buffer busy."
  (require 'claude-code)
  ;; Mark busy before sending -- we're submitting input
  (org-agent-codex--mark-busy)
  (claude-code--term-send-string backend string))

(defun org-agent-codex--term-configure (backend)
  "Configure the Codex terminal buffer using BACKEND.
Delegates to `claude-code--term-configure' then applies Codex-specific settings:
header-line with node/status, tinted background, left-margin padding."
  (require 'claude-code)
  (claude-code--term-configure backend)
  ;; Codex-specific buffer configuration
  (setq-local mode-name "Codex")
  ;; Codex doesn't use bell for notifications, so disable the bell handler
  ;; that claude-code installs (it would never fire and is confusing).
  (when (and (eq backend 'eat)
             (bound-and-true-p eat-terminal))
    (eval '(setf (eat-term-parameter eat-terminal 'ring-bell-function) #'ignore)))
  ;; Disable scroll bar and fringes (match claude-code behavior)
  (setq-local vertical-scroll-bar nil)
  (setq-local fringe-mode 0))

(defun org-agent-codex--term-setup-keymap (backend)
  "Set up keybindings for the Codex terminal buffer using BACKEND.
Delegates to `claude-code--term-setup-keymap' -- same bindings for v1."
  (require 'claude-code)
  (claude-code--term-setup-keymap backend))

(defun org-agent-codex--term-customize-faces (backend)
  "Apply face customizations for the Codex terminal using BACKEND.
Delegates to `claude-code--term-customize-faces' -- same faces for v1."
  (require 'claude-code)
  (claude-code--term-customize-faces backend))

;;;; Session management — capture and resume Codex sessions
;;
;; Codex uses its own session UUIDs, stored as:
;;   ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<codex-uuid>.jsonl
;;
;; Our org-session UUIDs are meaningless to Codex.  To support resume:
;; 1. After launching Codex, detect the newest session file and extract
;;    the Codex UUID from its session_meta JSON.
;; 2. Store it as a :CODEX_SESSION_ID: org property on the heading.
;; 3. On re-open, read the property and pass it to `codex resume <id>'.

(defun org-agent-codex--extract-session-id-from-file (file)
  "Extract the Codex session ID from FILE's session_meta line.
Returns the UUID string, or nil on parse failure."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file nil 0 4096)
        (goto-char (point-min))
        (let ((json (json-parse-string
                     (buffer-substring (point-min) (line-end-position))
                     :object-type 'alist)))
          (when (equal (alist-get 'type json) "session_meta")
            (alist-get 'id (alist-get 'payload json)))))
    (error nil)))

(defun org-agent-codex--session-file-for-id (codex-uuid)
  "Find the session file for CODEX-UUID in ~/.codex/sessions/.
Returns the file path or nil."
  (let ((sessions-dir (expand-file-name "~/.codex/sessions")))
    (when (file-directory-p sessions-dir)
      (car (directory-files-recursively
            sessions-dir
            (concat (regexp-quote codex-uuid) "\\.jsonl$"))))))

(defun org-agent-codex--latest-session-after (timestamp)
  "Find the newest Codex session file created after TIMESTAMP.
Returns (CODEX-UUID . FILE-PATH) or nil."
  (let ((sessions-dir (expand-file-name "~/.codex/sessions"))
        (best nil)
        (best-mtime 0))
    (when (file-directory-p sessions-dir)
      (dolist (file (directory-files-recursively sessions-dir "\\.jsonl$"))
        (let ((mtime (float-time (file-attribute-modification-time
                                  (file-attributes file)))))
          (when (and (> mtime timestamp) (> mtime best-mtime))
            (setq best file best-mtime mtime)))))
    (when best
      (let ((id (org-agent-codex--extract-session-id-from-file best)))
        (when id (cons id best))))))

(defun org-agent-codex--store-org-property (node-id property value)
  "Store PROPERTY=VALUE on NODE-ID's org heading in the task org file."
  (let ((org-buf (cl-loop for buf in (buffer-list)
                          when (and (buffer-file-name buf)
                                    (string-match-p "\\.org\\'"
                                                    (buffer-file-name buf))
                                    (with-current-buffer buf
                                      (bound-and-true-p org-agent-mode)))
                          return buf)))
    (when org-buf
      (with-current-buffer org-buf
        (org-with-wide-buffer
         (goto-char (point-min))
         (when (re-search-forward
                (format "^\\*+ .*\\[%s\\]" (regexp-quote node-id))
                nil t)
           (org-entry-put nil property value)))))))

(defun org-agent-codex--capture-session-id (buf node-id launch-time)
  "Capture the Codex session ID for BUF and store on NODE-ID's heading.
Called via timer after Codex starts.  Finds the newest session file
created after LAUNCH-TIME and stores its UUID as :CODEX_SESSION_ID:."
  (when (buffer-live-p buf)
    (let ((result (org-agent-codex--latest-session-after launch-time)))
      (when result
        (let ((codex-uuid (car result)))
          (message "org-agent-codex: captured session ID %s for [%s]"
                   codex-uuid node-id)
          (org-agent-codex--store-org-property
           node-id "CODEX_SESSION_ID" codex-uuid))))))

(defun org-agent-codex--schedule-session-capture (buf node-id)
  "Schedule Codex session ID capture for BUF after startup.
Tries at 3s, 6s, and 10s — first successful capture wins."
  (let ((launch-time (float-time)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq org-agent-codex--launch-time launch-time)))
    (dolist (delay '(3.0 6.0 10.0))
      (run-with-timer delay nil
                      #'org-agent-codex--capture-session-id
                      buf node-id launch-time))))

(defun org-agent-codex--find-session-file (_uuid)
  "Session file lookup for the adapter registry.
Always returns nil — Codex resume is handled via :CODEX_SESSION_ID:
org property, not through this function.  See `org-agent--start-cc'."
  nil)

(provide 'org-agent-codex)
;;; org-agent-codex.el ends here
