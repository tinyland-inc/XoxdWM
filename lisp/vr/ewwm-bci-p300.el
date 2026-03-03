;;; ewwm-bci-p300.el --- P300 confirmation system  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; P300 event-related potential detection for target confirmation.
;; Presents visual stimuli (oddball paradigm), detects the P300
;; response when the target stimulus appears, and invokes a
;; callback with the selected target.  Useful for BCI-driven
;; menus and confirmation dialogs.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-bci-p300 nil
  "P300 confirmation system settings."
  :group 'ewwm-bci)

(defcustom ewwm-bci-p300-enabled nil
  "Non-nil to enable P300 detection system."
  :type 'boolean
  :group 'ewwm-bci-p300)

(defcustom ewwm-bci-p300-repetitions 5
  "Number of stimulus repetitions per trial.
More repetitions improve accuracy but increase latency.
Typical range: 3-10."
  :type 'integer
  :group 'ewwm-bci-p300)

(defcustom ewwm-bci-p300-min-confidence 0.7
  "Minimum confidence for P300 detection.
Values below this threshold reject the classification."
  :type 'number
  :group 'ewwm-bci-p300)

(defcustom ewwm-bci-p300-soa-ms 200
  "Stimulus Onset Asynchrony in milliseconds.
Time between consecutive stimulus flashes.
Must be long enough for ERP to develop (>= 150ms)."
  :type 'integer
  :group 'ewwm-bci-p300)

(defcustom ewwm-bci-p300-flash-duration-ms 100
  "Duration of each stimulus flash in milliseconds."
  :type 'integer
  :group 'ewwm-bci-p300)

(defcustom ewwm-bci-p300-timeout-ms 30000
  "Maximum time in ms to wait for P300 classification.
After timeout, the pending callback is canceled."
  :type 'integer
  :group 'ewwm-bci-p300)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-bci-p300--active nil
  "Non-nil when P300 stimulus sequence is running.")

(defvar ewwm-bci-p300--last-result nil
  "Plist of last P300 detection result.
Contains :target-id, :confidence, :latency-ms.")

(defvar ewwm-bci-p300--callback nil
  "Callback function for current P300 trial.
Called with (TARGET-ID CONFIDENCE) on detection,
or (nil nil) on timeout/cancel.")

(defvar ewwm-bci-p300--targets nil
  "List of target identifiers for current trial.")

(defvar ewwm-bci-p300--timeout-timer nil
  "Timer for P300 trial timeout, or nil.")

(defvar ewwm-bci-p300--trial-count 0
  "Total P300 trials completed this session.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-bci-p300-detect-hook nil
  "Hook run on successful P300 target detection.
Functions receive (TARGET-ID CONFIDENCE).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-bci-p300--on-bci-p300 (msg)
  "Handle :bci-p300 event MSG.
Invokes callback on detection or rejection."
  (when (and ewwm-bci-p300-enabled ewwm-bci-p300--active)
    (let* ((target (plist-get msg :target-id))
           (confidence (plist-get msg :confidence))
           (latency (plist-get msg :latency-ms))
           (status (plist-get msg :status)))
      (setq ewwm-bci-p300--last-result
            (list :target-id target
                  :confidence confidence
                  :latency-ms latency))
      (cond
       ;; Successful detection
       ((and (eq status 'detected)
             confidence
             (>= confidence ewwm-bci-p300-min-confidence))
        (ewwm-bci-p300--complete target confidence))
       ;; Rejected (below threshold)
       ((eq status 'rejected)
        (message "ewwm-bci-p300: rejected (%.0f%% < %.0f%%)"
                 (* 100.0 (or confidence 0))
                 (* 100.0 ewwm-bci-p300-min-confidence)))
       ;; Trial in progress
       ((eq status 'flash)
        nil)))))

(defun ewwm-bci-p300--complete (target confidence)
  "Complete the P300 trial with TARGET and CONFIDENCE.
Fires callback and hook, cleans up state."
  (let ((cb ewwm-bci-p300--callback))
    ;; Clean up
    (ewwm-bci-p300--cancel-timeout)
    (setq ewwm-bci-p300--active nil)
    (cl-incf ewwm-bci-p300--trial-count)
    ;; Notify
    (message "ewwm-bci-p300: detected target=%s (%.0f%%)"
             target (* 100.0 confidence))
    (run-hook-with-args 'ewwm-bci-p300-detect-hook
                        target confidence)
    ;; Invoke callback
    (when (functionp cb)
      (setq ewwm-bci-p300--callback nil)
      (funcall cb target confidence))))

(defun ewwm-bci-p300--on-timeout ()
  "Handle P300 trial timeout.
Cancels the active trial and invokes callback with nil."
  (when ewwm-bci-p300--active
    (let ((cb ewwm-bci-p300--callback))
      (setq ewwm-bci-p300--active nil
            ewwm-bci-p300--callback nil
            ewwm-bci-p300--timeout-timer nil)
      (when (and (fboundp 'ewwm-ipc-connected-p)
                 (ewwm-ipc-connected-p))
        (ewwm-ipc-send '(:type :bci-p300-cancel)))
      (message "ewwm-bci-p300: trial timed out")
      (when (functionp cb)
        (funcall cb nil nil)))))

(defun ewwm-bci-p300--cancel-timeout ()
  "Cancel the P300 timeout timer if active."
  (when ewwm-bci-p300--timeout-timer
    (cancel-timer ewwm-bci-p300--timeout-timer)
    (setq ewwm-bci-p300--timeout-timer nil)))

;; ── Core API ────────────────────────────────────────────────

(defun ewwm-bci-p300-confirm (prompt targets callback)
  "Start async P300 confirmation with PROMPT and TARGETS.
PROMPT is a string describing the selection.
TARGETS is a list of target identifiers (strings or symbols).
CALLBACK is called with (TARGET-ID CONFIDENCE) on completion
or (nil nil) on timeout/cancel."
  (when ewwm-bci-p300--active
    (ewwm-bci-p300--cancel-timeout)
    (setq ewwm-bci-p300--active nil))
  (setq ewwm-bci-p300--targets targets
        ewwm-bci-p300--callback callback
        ewwm-bci-p300--active t)
  ;; Set timeout
  (setq ewwm-bci-p300--timeout-timer
        (run-with-timer
         (/ ewwm-bci-p300-timeout-ms 1000.0)
         nil #'ewwm-bci-p300--on-timeout))
  ;; Send to compositor
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :bci-p300-start
       :prompt ,prompt
       :targets ,targets
       :repetitions ,ewwm-bci-p300-repetitions
       :soa-ms ,ewwm-bci-p300-soa-ms
       :flash-duration-ms ,ewwm-bci-p300-flash-duration-ms)))
  (message "ewwm-bci-p300: %s (%d targets)"
           prompt (length targets)))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-bci-p300-start ()
  "Start a P300 demo trial with workspace targets."
  (interactive)
  (if (not ewwm-bci-p300-enabled)
      (message "ewwm-bci-p300: not enabled")
    (ewwm-bci-p300-confirm
     "Select workspace"
     '("ws1" "ws2" "ws3" "ws4")
     (lambda (target _confidence)
       (if target
           (message "ewwm-bci-p300: selected %s" target)
         (message "ewwm-bci-p300: no selection"))))))

(defun ewwm-bci-p300-stop ()
  "Cancel the active P300 trial."
  (interactive)
  (if (not ewwm-bci-p300--active)
      (message "ewwm-bci-p300: no active trial")
    (let ((cb ewwm-bci-p300--callback))
      (ewwm-bci-p300--cancel-timeout)
      (setq ewwm-bci-p300--active nil
            ewwm-bci-p300--callback nil)
      (when (and (fboundp 'ewwm-ipc-connected-p)
                 (ewwm-ipc-connected-p))
        (ewwm-ipc-send '(:type :bci-p300-cancel)))
      (when (functionp cb)
        (funcall cb nil nil))
      (message "ewwm-bci-p300: trial canceled"))))

(defun ewwm-bci-p300-status ()
  "Display P300 status in the minibuffer."
  (interactive)
  (let ((last-target (plist-get ewwm-bci-p300--last-result
                                :target-id))
        (last-conf (plist-get ewwm-bci-p300--last-result
                              :confidence)))
    (message
     "ewwm-bci-p300: active=%s trials=%d last=%s(%.0f%%)"
     (if ewwm-bci-p300--active "yes" "no")
     ewwm-bci-p300--trial-count
     (or last-target "-")
     (* 100.0 (or last-conf 0.0)))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-bci-p300--register-events ()
  "Register P300 event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:bci-p300 . ewwm-bci-p300--on-bci-p300))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-bci-p300-init ()
  "Initialize P300 detection system."
  (ewwm-bci-p300--register-events))

(defun ewwm-bci-p300-teardown ()
  "Clean up P300 state."
  (when ewwm-bci-p300--active
    (ewwm-bci-p300-stop))
  (ewwm-bci-p300--cancel-timeout)
  (setq ewwm-bci-p300--active nil
        ewwm-bci-p300--last-result nil
        ewwm-bci-p300--callback nil
        ewwm-bci-p300--targets nil
        ewwm-bci-p300--trial-count 0))

(provide 'ewwm-bci-p300)
;;; ewwm-bci-p300.el ends here
