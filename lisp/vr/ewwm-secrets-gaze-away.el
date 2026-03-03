;;; ewwm-secrets-gaze-away.el --- Gaze-away detection during auto-type  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Monitors gaze position during secrets auto-type operations.  If the
;; user's gaze leaves the target surface, auto-type is paused.  When
;; gaze returns, auto-type resumes.  If gaze stays away too long, the
;; operation is aborted.  This prevents sensitive data from being typed
;; into the wrong surface.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-secrets-gaze-away nil
  "Gaze-away detection for auto-type safety."
  :group 'ewwm)

(defcustom ewwm-secrets-gaze-away-enable t
  "Non-nil to enable gaze-away detection during auto-type.
When the user's gaze leaves the target surface, auto-type is
paused and eventually aborted."
  :type 'boolean
  :group 'ewwm-secrets-gaze-away)

(defcustom ewwm-secrets-gaze-away-pause-ms 500
  "Milliseconds of gaze departure before pausing auto-type.
If the user looks away from the target surface for this long,
auto-type is paused until gaze returns."
  :type 'integer
  :group 'ewwm-secrets-gaze-away)

(defcustom ewwm-secrets-gaze-away-resume-ms 300
  "Milliseconds of gaze return required before resuming auto-type.
After gaze returns to the target surface, auto-type resumes
once the gaze has been stable for this duration."
  :type 'integer
  :group 'ewwm-secrets-gaze-away)

(defcustom ewwm-secrets-gaze-away-abort-ms 5000
  "Milliseconds of continuous gaze departure before aborting auto-type.
If the user does not return gaze within this time, the
auto-type operation is cancelled entirely."
  :type 'integer
  :group 'ewwm-secrets-gaze-away)

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-secrets-gaze-away-pause-hook nil
  "Hook run when auto-type is paused due to gaze departure.
Functions receive no arguments.")

(defvar ewwm-secrets-gaze-away-resume-hook nil
  "Hook run when auto-type resumes after gaze return.
Functions receive no arguments.")

(defvar ewwm-secrets-gaze-away-abort-hook nil
  "Hook run when auto-type is aborted due to prolonged gaze departure.
Functions receive no arguments.")

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-secrets-gaze-away--monitoring nil
  "Non-nil during active gaze-away monitoring.")

(defvar ewwm-secrets-gaze-away--target-surface nil
  "Surface ID being monitored for gaze departure.")

(defvar ewwm-secrets-gaze-away--away-since nil
  "Float-time when gaze left the target surface, or nil if on target.")

(defvar ewwm-secrets-gaze-away--paused nil
  "Non-nil if auto-type is currently paused due to gaze departure.")

(defvar ewwm-secrets-gaze-away--abort-timer nil
  "Timer for abort countdown when gaze leaves the target.")

;; ── Core functions ───────────────────────────────────────────

(defun ewwm-secrets-gaze-away-start (surface-id)
  "Begin gaze-away monitoring for SURFACE-ID.
Should be called when an auto-type operation begins.  Registers
for gaze update events and starts monitoring gaze position."
  (unless ewwm-secrets-gaze-away-enable
    (user-error "ewwm-secrets-gaze-away: gaze-away detection is disabled"))
  (ewwm-secrets-gaze-away-stop) ; clean any prior session
  (setq ewwm-secrets-gaze-away--monitoring t
        ewwm-secrets-gaze-away--target-surface surface-id
        ewwm-secrets-gaze-away--away-since nil
        ewwm-secrets-gaze-away--paused nil)
  ;; Notify compositor to track gaze against this surface
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     (list :command "gaze-away-monitor"
           :enable t
           :surface-id surface-id
           :pause-ms ewwm-secrets-gaze-away-pause-ms
           :resume-ms ewwm-secrets-gaze-away-resume-ms
           :abort-ms ewwm-secrets-gaze-away-abort-ms)))
  (message "ewwm-secrets-gaze-away: monitoring surface %d" surface-id))

(defun ewwm-secrets-gaze-away-stop ()
  "Stop gaze-away monitoring.
Cancels any pending abort timer and clears monitoring state."
  (when ewwm-secrets-gaze-away--abort-timer
    (cancel-timer ewwm-secrets-gaze-away--abort-timer)
    (setq ewwm-secrets-gaze-away--abort-timer nil))
  (when ewwm-secrets-gaze-away--monitoring
    ;; Notify compositor to stop monitoring
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       (list :command "gaze-away-monitor"
             :enable nil))))
  (setq ewwm-secrets-gaze-away--monitoring nil
        ewwm-secrets-gaze-away--target-surface nil
        ewwm-secrets-gaze-away--away-since nil
        ewwm-secrets-gaze-away--paused nil))

(defun ewwm-secrets-gaze-away--on-gaze-update (data)
  "Process gaze position update DATA, check if still on target surface.
DATA is a plist with :surface-id for the surface currently under gaze.
If the gaze is on a different surface than the target, start departure
tracking.  If gaze returns, cancel departure."
  (when ewwm-secrets-gaze-away--monitoring
    (let ((current-surface (plist-get data :surface-id)))
      (cond
       ;; Gaze is on the target surface
       ((and current-surface
             (equal current-surface ewwm-secrets-gaze-away--target-surface))
        (when ewwm-secrets-gaze-away--away-since
          ;; Gaze returned — clear departure tracking
          (setq ewwm-secrets-gaze-away--away-since nil)
          ;; Cancel abort timer
          (when ewwm-secrets-gaze-away--abort-timer
            (cancel-timer ewwm-secrets-gaze-away--abort-timer)
            (setq ewwm-secrets-gaze-away--abort-timer nil))
          ;; Resume if paused
          (when ewwm-secrets-gaze-away--paused
            (setq ewwm-secrets-gaze-away--paused nil)
            (message "Auto-type resumed.")
            (run-hooks 'ewwm-secrets-gaze-away-resume-hook))))
       ;; Gaze is NOT on the target surface
       (t
        (ewwm-secrets-gaze-away--check-departure))))))

(defun ewwm-secrets-gaze-away--check-departure ()
  "Evaluate gaze departure timing and trigger pause or abort.
Called when gaze is not on the target surface."
  (let ((now (float-time)))
    (cond
     ;; First frame of departure — record timestamp
     ((null ewwm-secrets-gaze-away--away-since)
      (setq ewwm-secrets-gaze-away--away-since now)
      ;; Start abort timer
      (when (and (null ewwm-secrets-gaze-away--abort-timer)
                 (> ewwm-secrets-gaze-away-abort-ms 0))
        (setq ewwm-secrets-gaze-away--abort-timer
              (run-at-time (/ ewwm-secrets-gaze-away-abort-ms 1000.0) nil
                           #'ewwm-secrets-gaze-away--do-abort))))
     ;; Already tracking departure — check if pause threshold reached
     ((and (not ewwm-secrets-gaze-away--paused)
           ewwm-secrets-gaze-away--away-since)
      (let ((elapsed-ms (* 1000.0
                           (- now ewwm-secrets-gaze-away--away-since))))
        (when (>= elapsed-ms ewwm-secrets-gaze-away-pause-ms)
          (setq ewwm-secrets-gaze-away--paused t)
          (message "Auto-type paused: gaze left target. Look back to resume, C-g to cancel.")
          (run-hooks 'ewwm-secrets-gaze-away-pause-hook)))))))

(defun ewwm-secrets-gaze-away--do-abort ()
  "Abort auto-type due to prolonged gaze departure."
  (when ewwm-secrets-gaze-away--monitoring
    (message "Auto-type aborted: gaze away too long.")
    (run-hooks 'ewwm-secrets-gaze-away-abort-hook)
    (ewwm-secrets-gaze-away-stop)))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-secrets-gaze-away--on-autotype-paused (data)
  "Handle autotype-paused event DATA from the compositor.
The compositor has paused auto-type because gaze left the target."
  (ignore data)
  (when ewwm-secrets-gaze-away--monitoring
    (setq ewwm-secrets-gaze-away--paused t)
    (message "Auto-type paused: gaze left target. Look back to resume, C-g to cancel.")
    (run-hooks 'ewwm-secrets-gaze-away-pause-hook)))

(defun ewwm-secrets-gaze-away--on-autotype-resumed (data)
  "Handle autotype-resumed event DATA from the compositor.
The compositor has resumed auto-type because gaze returned."
  (ignore data)
  (when ewwm-secrets-gaze-away--monitoring
    (setq ewwm-secrets-gaze-away--paused nil
          ewwm-secrets-gaze-away--away-since nil)
    (when ewwm-secrets-gaze-away--abort-timer
      (cancel-timer ewwm-secrets-gaze-away--abort-timer)
      (setq ewwm-secrets-gaze-away--abort-timer nil))
    (message "Auto-type resumed.")
    (run-hooks 'ewwm-secrets-gaze-away-resume-hook)))

(defun ewwm-secrets-gaze-away--on-gaze-target-changed (data)
  "Handle gaze-target-changed event DATA.
DATA contains :surface-id of the new gaze target.  Delegates to
the main gaze update handler."
  (when ewwm-secrets-gaze-away--monitoring
    (ewwm-secrets-gaze-away--on-gaze-update data)))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-secrets-gaze-away--register-events ()
  "Register gaze-away event handlers with IPC event dispatch.
Idempotent: will not duplicate handlers."
  (ewwm-ipc-register-events
   '((:gaze-update          . ewwm-secrets-gaze-away--on-gaze-update)
     (:autotype-paused      . ewwm-secrets-gaze-away--on-autotype-paused)
     (:autotype-resumed     . ewwm-secrets-gaze-away--on-autotype-resumed)
     (:gaze-target-changed  . ewwm-secrets-gaze-away--on-gaze-target-changed))))

;; ── Init / teardown ──────────────────────────────────────────

(defun ewwm-secrets-gaze-away-init ()
  "Initialize gaze-away detection.
Register IPC event handlers for gaze monitoring."
  (ewwm-secrets-gaze-away--register-events))

(defun ewwm-secrets-gaze-away-teardown ()
  "Tear down gaze-away detection.
Stop any active monitoring and clear all state."
  (ewwm-secrets-gaze-away-stop))

(provide 'ewwm-secrets-gaze-away)
;;; ewwm-secrets-gaze-away.el ends here
