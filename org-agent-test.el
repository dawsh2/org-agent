;;; org-agent-test.el --- Tests for org-agent.el backend inheritance -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for :BACKEND: property inheritance in the org tree.
;; Tests verify that:
;; 1. Child headings inherit :BACKEND: from parent
;; 2. Child headings can override :BACKEND: from parent
;; 3. Default backend is used when no :BACKEND: property exists

;;; Code:

(require 'ert)
(require 'org)
(require 'cl-lib)

;; Load the main file
(load-file (expand-file-name "org-agent.el" (file-name-directory (or load-file-name (buffer-file-name)))))

(ert-deftest org-agent-test-backend-inheritance-child-inherits-from-parent ()
  "Test that child heading inherits :BACKEND: from parent."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent
:PROPERTIES:
:BACKEND: codex
:END:
** Child
")
    (goto-char (point-min))
    (search-forward "** Child")
    (let ((result (org-agent--resolve-backend)))
      (should (equal (cdr result) "codex")))))

(ert-deftest org-agent-test-backend-inheritance-child-override ()
  "Test that child heading can override :BACKEND: from parent."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent
:PROPERTIES:
:BACKEND: codex
:END:
** Child
:PROPERTIES:
:BACKEND: anthropic
:END:
")
    (goto-char (point-min))
    (search-forward "** Child")
    (let ((result (org-agent--resolve-backend)))
      (should (equal (cdr result) "anthropic")))))

(ert-deftest org-agent-test-backend-inheritance-default ()
  "Test that default backend is used when no :BACKEND: property exists."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent
** Child
")
    (goto-char (point-min))
    (search-forward "** Child")
    (let ((result (org-agent--resolve-backend)))
      (should (equal (cdr result) org-agent-default-backend)))))

(ert-deftest org-agent-test-backend-inheritance-multi-level ()
  "Test that backend inheritance works across multiple levels."
  (with-temp-buffer
    (org-mode)
    (insert "* Grandparent
:PROPERTIES:
:BACKEND: zai
:END:
** Parent
*** Child
")
    (goto-char (point-min))
    (search-forward "*** Child")
    (let ((result (org-agent--resolve-backend)))
      (should (equal (cdr result) "zai")))))

(ert-deftest org-agent-test-backend-inheritance-multi-level-override ()
  "Test that intermediate level can override grandparent backend."
  (with-temp-buffer
    (org-mode)
    (insert "* Grandparent
:PROPERTIES:
:BACKEND: zai
:END:
** Parent
:PROPERTIES:
:BACKEND: codex
:END:
*** Child
")
    (goto-char (point-min))
    (search-forward "*** Child")
    (let ((result (org-agent--resolve-backend)))
      (should (equal (cdr result) "codex")))))

(provide 'org-agent-test)

;;; org-agent-test.el ends here
