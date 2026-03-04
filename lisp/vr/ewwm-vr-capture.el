;;; ewwm-vr-capture.el --- Screen capture visibility for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Per-surface screen capture visibility control.  Surfaces can be
;; hidden from screencopy/screen-share or marked as sensitive (content
;; redacted).  Sensitive patterns auto-detect windows that should not
;; appear in captures (password managers, credential prompts, etc.).

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")
(declare-function ewwm--surface-buffer-alist "ewwm-core")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-capture nil
  "Screen capture visibility settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-capture-default-visibility "visible"
  "Default capture visibility for surfaces.
\"visible\": included in screen captures.
\"hidden\": excluded from screen captures.
\"sensitive\": included but content is redacted."
  :type '(choice (const :tag "Visible" "visible")
                 (const :tag "Hidden" "hidden")
                 (const :tag "Sensitive" "sensitive"))
  :group 'ewwm-vr-capture)

(defcustom ewwm-vr-capture-sensitive-patterns
  '("\\*KeePass" "\\*pass " "\\*Password" "\\*TOTP"
    "\\*secrets\\*" "\\*auth-source" "\\*gnupg\\*")
  "List of buffer name patterns to auto-classify as sensitive.
When a surface's buffer name matches any of these patterns, it is
automatically marked as sensitive for screen capture."
  :type '(repeat regexp)
  :group 'ewwm-vr-capture)

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-capture--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-capture--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-capture: %s" (error-message-string err))
       nil))))

;; ── Auto-classify ────────────────────────────────────────────

(defun ewwm-vr-capture--auto-classify (buffer-name)
  "Return capture visibility for BUFFER-NAME based on sensitive patterns.
Returns \"sensitive\" if BUFFER-NAME matches any pattern in
`ewwm-vr-capture-sensitive-patterns', otherwise returns
`ewwm-vr-capture-default-visibility'."
  (if (cl-some (lambda (pattern)
                 (string-match-p pattern buffer-name))
               ewwm-vr-capture-sensitive-patterns)
      "sensitive"
    ewwm-vr-capture-default-visibility))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-capture-hide-surface (surface-id)
  "Hide SURFACE-ID from screen captures."
  (interactive "nSurface ID: ")
  (ewwm-vr-capture--send
   `(:type :vr-capture-set :surface ,surface-id :visibility "hidden"))
  (message "ewwm-vr-capture: surface %d hidden from captures" surface-id))

(defun ewwm-vr-capture-show-surface (surface-id)
  "Show SURFACE-ID in screen captures."
  (interactive "nSurface ID: ")
  (ewwm-vr-capture--send
   `(:type :vr-capture-set :surface ,surface-id :visibility "visible"))
  (message "ewwm-vr-capture: surface %d visible in captures" surface-id))

(defun ewwm-vr-capture-mark-sensitive (surface-id)
  "Mark SURFACE-ID as sensitive (redacted in captures)."
  (interactive "nSurface ID: ")
  (ewwm-vr-capture--send
   `(:type :vr-capture-set :surface ,surface-id :visibility "sensitive"))
  (message "ewwm-vr-capture: surface %d marked sensitive" surface-id))

(defun ewwm-vr-capture-status ()
  "Display current capture visibility state."
  (interactive)
  (let ((resp (ewwm-vr-capture--send-sync '(:type :vr-capture-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((capture (plist-get resp :capture)))
          (message "ewwm-vr-capture: default=%s overrides=%s"
                   (or (plist-get capture :default) ewwm-vr-capture-default-visibility)
                   (or (plist-get capture :override-count) 0)))
      (message "ewwm-vr-capture: default=%s (offline)"
               ewwm-vr-capture-default-visibility))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-capture--handle-status (msg)
  "Handle :capture-status event MSG from compositor."
  (let ((default-vis (plist-get msg :default)))
    (when default-vis
      (setq ewwm-vr-capture-default-visibility default-vis))))

(defun ewwm-vr-capture--register-events ()
  "Register capture visibility event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:capture-status . ewwm-vr-capture--handle-status))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-capture-init ()
  "Initialize capture visibility module.
Registers IPC event handlers."
  (ewwm-vr-capture--register-events))

(defun ewwm-vr-capture-teardown ()
  "Clean up capture visibility state."
  nil)

(provide 'ewwm-vr-capture)
;;; ewwm-vr-capture.el ends here
