;;; ewwm-vr-secure-input.el --- Secure input mode for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Secure input mode: temporarily disables gaze, wink, EEG, and fatigue
;; subsystems while the user is entering sensitive data (e.g. passwords).
;; Automatically wraps `read-passwd' to enter/exit secure mode, provides
;; IPC integration with the compositor, and shows mode-line indicator.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-secure-input nil
  "Secure input mode settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-secure-input-enable t
  "Master switch for secure input mode.
When non-nil, `read-passwd' and related functions automatically
enter secure mode to disable gaze/wink/EEG subsystems."
  :type 'boolean
  :group 'ewwm-vr-secure-input)

(defcustom ewwm-vr-secure-input-timeout 30
  "Seconds before secure input mode auto-exits.
Safety net to prevent subsystems from staying disabled if the
exit signal is missed."
  :type 'integer
  :group 'ewwm-vr-secure-input)

(defcustom ewwm-vr-secure-input-border-color "red"
  "Border color shown around the active surface in secure mode.
Sent to the compositor for visual indication."
  :type 'string
  :group 'ewwm-vr-secure-input)

(defcustom ewwm-vr-secure-input-pause-gaze t
  "Non-nil to pause gaze tracking during secure input."
  :type 'boolean
  :group 'ewwm-vr-secure-input)

(defcustom ewwm-vr-secure-input-pause-wink t
  "Non-nil to pause wink detection during secure input."
  :type 'boolean
  :group 'ewwm-vr-secure-input)

(defcustom ewwm-vr-secure-input-pause-eeg t
  "Non-nil to pause EEG input during secure input."
  :type 'boolean
  :group 'ewwm-vr-secure-input)

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-secure-input-enter-hook nil
  "Hook run when secure input mode is entered.
Functions receive no arguments.")

(defvar ewwm-vr-secure-input-exit-hook nil
  "Hook run when secure input mode is exited.
Functions receive no arguments.")

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-secure-input--active nil
  "Non-nil when secure input mode is active.")

(defvar ewwm-vr-secure-input--reason nil
  "Reason string for the current secure input session.")

(defvar ewwm-vr-secure-input--surface-id nil
  "Surface ID that triggered secure input mode, or nil.")

(defvar ewwm-vr-secure-input--timer nil
  "Safety timer for auto-exit from secure input mode.")

;; ── Core functions ───────────────────────────────────────────

(defun ewwm-vr-secure-input-enter (&optional reason surface-id)
  "Activate secure input mode.
REASON is a description string (default \"manual\").
SURFACE-ID is the compositor surface that triggered the mode.
Sends IPC command to the compositor, starts the auto-exit timer,
and runs `ewwm-vr-secure-input-enter-hook'."
  (unless ewwm-vr-secure-input-enable
    (user-error "ewwm-vr-secure-input: secure input mode is disabled"))
  (let ((reason (or reason "manual"))
        (sid (or surface-id 0)))
    (setq ewwm-vr-secure-input--active t
          ewwm-vr-secure-input--reason reason
          ewwm-vr-secure-input--surface-id sid)
    ;; Cancel any existing timer
    (when ewwm-vr-secure-input--timer
      (cancel-timer ewwm-vr-secure-input--timer)
      (setq ewwm-vr-secure-input--timer nil))
    ;; Start auto-exit timer
    (setq ewwm-vr-secure-input--timer
          (run-at-time ewwm-vr-secure-input-timeout nil
                       #'ewwm-vr-secure-input--auto-exit))
    ;; Send IPC to compositor
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       (list :command "secure-input-mode"
             :enable t
             :reason reason
             :surface-id sid
             :timeout ewwm-vr-secure-input-timeout
             :border-color ewwm-vr-secure-input-border-color
             :pause-gaze ewwm-vr-secure-input-pause-gaze
             :pause-wink ewwm-vr-secure-input-pause-wink
             :pause-eeg ewwm-vr-secure-input-pause-eeg)))
    (run-hooks 'ewwm-vr-secure-input-enter-hook)
    (message "ewwm-vr-secure-input: entered (%s)" reason)))

(defun ewwm-vr-secure-input-exit ()
  "Deactivate secure input mode.
Sends IPC command to the compositor, cancels the auto-exit timer,
clears state, and runs `ewwm-vr-secure-input-exit-hook'."
  (when ewwm-vr-secure-input--timer
    (cancel-timer ewwm-vr-secure-input--timer)
    (setq ewwm-vr-secure-input--timer nil))
  (when ewwm-vr-secure-input--active
    ;; Send IPC to compositor
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       (list :command "secure-input-mode"
             :enable nil)))
    (let ((reason ewwm-vr-secure-input--reason))
      (setq ewwm-vr-secure-input--active nil
            ewwm-vr-secure-input--reason nil
            ewwm-vr-secure-input--surface-id nil)
      (run-hooks 'ewwm-vr-secure-input-exit-hook)
      (message "ewwm-vr-secure-input: exited (%s)" (or reason "unknown")))))

(defun ewwm-vr-secure-input-active-p ()
  "Return non-nil if secure input mode is currently active."
  ewwm-vr-secure-input--active)

(defun ewwm-vr-secure-input--auto-exit ()
  "Auto-exit handler called when the safety timer fires."
  (when ewwm-vr-secure-input--active
    (message "ewwm-vr-secure-input: auto-exit after %ds timeout"
             ewwm-vr-secure-input-timeout)
    (ewwm-vr-secure-input-exit)))

;; ── read-passwd integration ──────────────────────────────────

(defun ewwm-vr-secure-input--read-passwd-advice (orig-fn &rest args)
  "Advice around `read-passwd' to automatically enter/exit secure mode.
ORIG-FN is the original `read-passwd' function.  ARGS are passed through.
Uses `unwind-protect' so secure mode exits even on C-g."
  (if (not ewwm-vr-secure-input-enable)
      (apply orig-fn args)
    (ewwm-vr-secure-input-enter "read-passwd" 0)
    (unwind-protect
        (apply orig-fn args)
      (ewwm-vr-secure-input-exit))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-secure-input--on-entered (data)
  "Handle secure-input-entered event DATA from the compositor.
Updates local state to reflect compositor confirmation."
  (let ((reason (plist-get data :reason))
        (sid (plist-get data :surface-id)))
    (setq ewwm-vr-secure-input--active t
          ewwm-vr-secure-input--reason (or reason "compositor")
          ewwm-vr-secure-input--surface-id sid)))

(defun ewwm-vr-secure-input--on-exited (data)
  "Handle secure-input-exited event DATA from the compositor.
Updates local state to reflect compositor confirmation."
  (ignore data)
  (setq ewwm-vr-secure-input--active nil
        ewwm-vr-secure-input--reason nil
        ewwm-vr-secure-input--surface-id nil)
  (when ewwm-vr-secure-input--timer
    (cancel-timer ewwm-vr-secure-input--timer)
    (setq ewwm-vr-secure-input--timer nil)))

(defun ewwm-vr-secure-input--on-timeout (data)
  "Handle secure-input-auto-exit-timeout event DATA from the compositor.
Synchronizes local state with compositor timeout."
  (ignore data)
  (when ewwm-vr-secure-input--active
    (message "ewwm-vr-secure-input: compositor reported auto-exit timeout")
    (setq ewwm-vr-secure-input--active nil
          ewwm-vr-secure-input--reason nil
          ewwm-vr-secure-input--surface-id nil)
    (when ewwm-vr-secure-input--timer
      (cancel-timer ewwm-vr-secure-input--timer)
      (setq ewwm-vr-secure-input--timer nil))
    (run-hooks 'ewwm-vr-secure-input-exit-hook)))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-secure-input--register-events ()
  "Register secure input event handlers with IPC event dispatch.
Idempotent: will not duplicate handlers."
  (ewwm-ipc-register-events
   '((:secure-input-entered         . ewwm-vr-secure-input--on-entered)
     (:secure-input-exited          . ewwm-vr-secure-input--on-exited)
     (:secure-input-auto-exit-timeout . ewwm-vr-secure-input--on-timeout))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-secure-input-toggle ()
  "Toggle secure input mode on or off."
  (interactive)
  (if ewwm-vr-secure-input--active
      (ewwm-vr-secure-input-exit)
    (ewwm-vr-secure-input-enter "manual-toggle")))

(defun ewwm-vr-secure-input-status ()
  "Display secure input mode status in the minibuffer."
  (interactive)
  (message "ewwm-vr-secure-input: active=%s reason=%s surface-id=%s timeout=%ds"
           (if ewwm-vr-secure-input--active "yes" "no")
           (or ewwm-vr-secure-input--reason "none")
           (or ewwm-vr-secure-input--surface-id "none")
           ewwm-vr-secure-input-timeout))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-secure-input-mode-line-string ()
  "Return a mode-line string for secure input state.
Returns \" [SECURE]\" when active, nil otherwise."
  (when ewwm-vr-secure-input--active
    " [SECURE]"))

;; ── Init / teardown ──────────────────────────────────────────

(defun ewwm-vr-secure-input-init ()
  "Initialize secure input mode.
Register IPC event handlers and install `read-passwd' advice."
  (ewwm-vr-secure-input--register-events)
  (advice-add 'read-passwd :around
              #'ewwm-vr-secure-input--read-passwd-advice))

(defun ewwm-vr-secure-input-teardown ()
  "Tear down secure input mode.
Remove `read-passwd' advice, cancel timer, and clear all state."
  (advice-remove 'read-passwd
                 #'ewwm-vr-secure-input--read-passwd-advice)
  (when ewwm-vr-secure-input--timer
    (cancel-timer ewwm-vr-secure-input--timer)
    (setq ewwm-vr-secure-input--timer nil))
  (setq ewwm-vr-secure-input--active nil
        ewwm-vr-secure-input--reason nil
        ewwm-vr-secure-input--surface-id nil))

(provide 'ewwm-vr-secure-input)
;;; ewwm-vr-secure-input.el ends here
