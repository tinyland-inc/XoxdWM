;;; ewwm-secrets-compositor.el --- Compositor auto-type backend  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Compositor-level auto-type for secure credential entry.
;; Sends synthetic wl_keyboard.key events via IPC to inject keystrokes
;; directly at the Wayland protocol level, bypassing X11/XTest.
;; Integrates with ewwm-ipc for bidirectional communication.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-secrets-compositor nil
  "Compositor auto-type backend settings."
  :group 'ewwm)

(defcustom ewwm-secrets-compositor-enable t
  "Master switch for compositor-level auto-type."
  :type 'boolean
  :group 'ewwm-secrets-compositor)

(defcustom ewwm-vr-autotype-delay-ms 10
  "Delay in milliseconds between synthetic keystrokes."
  :type 'integer
  :group 'ewwm-secrets-compositor)

(defcustom ewwm-secrets-compositor-verify-surface t
  "Non-nil to verify the target surface before each keystroke.
When enabled, the compositor checks that the intended surface still
has focus before injecting the next key event."
  :type 'boolean
  :group 'ewwm-secrets-compositor)

(defcustom ewwm-secrets-compositor-timeout-ms 2000
  "Timeout in milliseconds for auto-type IPC requests.
If the compositor does not respond within this duration, the
request is considered failed."
  :type 'integer
  :group 'ewwm-secrets-compositor)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-secrets-compositor--typing-p nil
  "Non-nil when an auto-type sequence is in progress.")

(defvar ewwm-secrets-compositor--last-surface-id nil
  "Surface ID of the last auto-type target.")

(defvar ewwm-secrets-compositor--last-result nil
  "Plist of the last auto-type completion result.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-secrets-compositor-complete-hook nil
  "Hook run when an auto-type sequence completes.
Functions receive (SURFACE-ID CHARS-TYPED).")

(defvar ewwm-secrets-compositor-error-hook nil
  "Hook run when an auto-type sequence encounters an error.
Functions receive (ERROR-MESSAGE).")

;; ── Core functions ───────────────────────────────────────────

(defun ewwm-secrets-compositor-available-p ()
  "Return non-nil if the compositor auto-type backend is available.
Checks that the feature is enabled and IPC is connected."
  (and ewwm-secrets-compositor-enable
       (fboundp 'ewwm-ipc-connected-p)
       (ewwm-ipc-connected-p)))

(defun ewwm-secrets-compositor--type-string (string surface-id)
  "Send STRING to the compositor for auto-type on SURFACE-ID.
Sends an IPC command and waits synchronously for the completion
event, up to `ewwm-secrets-compositor-timeout-ms'.
Returns the response plist on success, or signals an error."
  (unless (ewwm-secrets-compositor-available-p)
    (error "ewwm-secrets-compositor: backend not available"))
  (setq ewwm-secrets-compositor--typing-p t
        ewwm-secrets-compositor--last-surface-id surface-id)
  (condition-case err
      (let* ((timeout-s (/ (float ewwm-secrets-compositor-timeout-ms) 1000.0))
             (resp (ewwm-ipc-send-sync
                    `(:type :command
                      :command "autotype"
                      :text ,string
                      :surface-id ,surface-id
                      :delay-ms ,ewwm-vr-autotype-delay-ms
                      :verify-surface ,(if ewwm-secrets-compositor-verify-surface t nil))
                    timeout-s)))
        (setq ewwm-secrets-compositor--typing-p nil
              ewwm-secrets-compositor--last-result resp)
        (when (eq (plist-get resp :status) :ok)
          (let ((chars (plist-get resp :chars-typed)))
            (run-hook-with-args 'ewwm-secrets-compositor-complete-hook
                                surface-id (or chars 0))))
        resp)
    (error
     (setq ewwm-secrets-compositor--typing-p nil)
     (let ((msg (error-message-string err)))
       (run-hook-with-args 'ewwm-secrets-compositor-error-hook msg)
       (error "ewwm-secrets-compositor: %s" msg)))))

(defun ewwm-secrets-compositor--type-credentials (username password surface-id)
  "Type USERNAME and PASSWORD into SURFACE-ID.
Concatenates with a tab between username and password, and appends
a return at the end for form submission.  The combined string is
sent as a single auto-type sequence."
  (let ((combined (concat username "\t" password "\r")))
    (unwind-protect
        (ewwm-secrets-compositor--type-string combined surface-id)
      ;; Zero out the combined string to limit credential exposure
      (fillarray combined 0))))

(defun ewwm-secrets-compositor--abort ()
  "Send an abort command to stop the current auto-type sequence."
  (when (ewwm-secrets-compositor-available-p)
    (condition-case err
        (ewwm-ipc-send
         '(:type :command :command "autotype-abort"))
      (error
       (message "ewwm-secrets-compositor: abort failed: %s"
                (error-message-string err))))
    (setq ewwm-secrets-compositor--typing-p nil)))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-secrets-compositor--on-autotype-complete (data)
  "Handle :autotype-complete event DATA from the compositor."
  (let ((surface-id (plist-get data :surface-id))
        (chars-typed (plist-get data :chars-typed)))
    (setq ewwm-secrets-compositor--typing-p nil
          ewwm-secrets-compositor--last-result data)
    (message "ewwm-secrets-compositor: typed %d chars on surface %s"
             (or chars-typed 0) (or surface-id "?"))
    (run-hook-with-args 'ewwm-secrets-compositor-complete-hook
                        surface-id (or chars-typed 0))))

(defun ewwm-secrets-compositor--on-autotype-paused (data)
  "Handle :autotype-paused event DATA from the compositor."
  (let ((surface-id (plist-get data :surface-id))
        (reason (plist-get data :reason))
        (remaining (plist-get data :chars-remaining)))
    (message "ewwm-secrets-compositor: paused on surface %s (reason=%s, remaining=%s)"
             (or surface-id "?")
             (or reason "unknown")
             (or remaining "?"))))

(defun ewwm-secrets-compositor--on-autotype-resumed (data)
  "Handle :autotype-resumed event DATA from the compositor."
  (let ((surface-id (plist-get data :surface-id)))
    (message "ewwm-secrets-compositor: resumed on surface %s"
             (or surface-id "?"))))

(defun ewwm-secrets-compositor--on-autotype-error (data)
  "Handle :autotype-error event DATA from the compositor."
  (let ((message-text (plist-get data :message)))
    (setq ewwm-secrets-compositor--typing-p nil)
    (display-warning 'ewwm-secrets-compositor
                     (format "Auto-type error: %s" (or message-text "unknown"))
                     :error)
    (run-hook-with-args 'ewwm-secrets-compositor-error-hook
                        (or message-text "unknown error"))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-secrets-compositor--register-events ()
  "Register auto-type event handlers with IPC event dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:autotype-complete  . ewwm-secrets-compositor--on-autotype-complete)
     (:autotype-paused    . ewwm-secrets-compositor--on-autotype-paused)
     (:autotype-resumed   . ewwm-secrets-compositor--on-autotype-resumed)
     (:autotype-error     . ewwm-secrets-compositor--on-autotype-error))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-secrets-compositor-status ()
  "Display the current auto-type status."
  (interactive)
  (if (not (ewwm-secrets-compositor-available-p))
      (message "ewwm-secrets-compositor: backend unavailable (enable=%s, ipc=%s)"
               (if ewwm-secrets-compositor-enable "yes" "no")
               (if (and (fboundp 'ewwm-ipc-connected-p) (ewwm-ipc-connected-p))
                   "connected" "disconnected"))
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :command :command "autotype-status"))))
          (if (eq (plist-get resp :status) :ok)
              (message "ewwm-secrets-compositor: %s"
                       (or (plist-get resp :autotype) "ok"))
            (message "ewwm-secrets-compositor: status query failed")))
      (error
       (message "ewwm-secrets-compositor: %s" (error-message-string err))))))

(defun ewwm-secrets-compositor-abort ()
  "Interactively abort the current auto-type sequence."
  (interactive)
  (if ewwm-secrets-compositor--typing-p
      (progn
        (ewwm-secrets-compositor--abort)
        (message "ewwm-secrets-compositor: aborted"))
    (message "ewwm-secrets-compositor: no active auto-type sequence")))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-secrets-compositor-init ()
  "Initialize the compositor auto-type backend.
Registers IPC event handlers for auto-type events."
  (ewwm-secrets-compositor--register-events)
  (setq ewwm-secrets-compositor--typing-p nil
        ewwm-secrets-compositor--last-surface-id nil
        ewwm-secrets-compositor--last-result nil))

(defun ewwm-secrets-compositor-teardown ()
  "Clean up compositor auto-type state.
Aborts any active sequence and resets internal variables."
  (when ewwm-secrets-compositor--typing-p
    (ewwm-secrets-compositor--abort))
  (setq ewwm-secrets-compositor--typing-p nil
        ewwm-secrets-compositor--last-surface-id nil
        ewwm-secrets-compositor--last-result nil))

(provide 'ewwm-secrets-compositor)
;;; ewwm-secrets-compositor.el ends here
