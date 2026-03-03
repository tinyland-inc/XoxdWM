;;; ewwm-bci-mi.el --- Motor imagery classification  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Motor imagery (MI) BCI integration for ewwm.
;; Classifies imagined left/right hand and foot movements from
;; EEG mu/beta desynchronization patterns.  Each class maps to
;; a configurable Emacs command.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-bci-mi nil
  "Motor imagery classification settings."
  :group 'ewwm-bci)

(defcustom ewwm-bci-mi-enabled nil
  "Non-nil to enable motor imagery classification.
Requires prior calibration for reliable results."
  :type 'boolean
  :group 'ewwm-bci-mi)

(defcustom ewwm-bci-mi-left-action #'previous-buffer
  "Function called on left hand MI classification."
  :type 'function
  :group 'ewwm-bci-mi)

(defcustom ewwm-bci-mi-right-action #'next-buffer
  "Function called on right hand MI classification."
  :type 'function
  :group 'ewwm-bci-mi)

(defcustom ewwm-bci-mi-foot-action
  (lambda ()
    (when (fboundp 'ewwm-workspace-switch)
      (ewwm-workspace-switch nil)))
  "Function called on foot MI classification.
Default cycles to the next workspace."
  :type 'function
  :group 'ewwm-bci-mi)

(defcustom ewwm-bci-mi-min-confidence 0.6
  "Minimum confidence for MI classification.
Values below this threshold are ignored."
  :type 'number
  :group 'ewwm-bci-mi)

(defcustom ewwm-bci-mi-cooldown-ms 1500
  "Cooldown in ms between MI action dispatches.
Prevents accidental rapid commands."
  :type 'integer
  :group 'ewwm-bci-mi)

(defcustom ewwm-bci-mi-feedback t
  "Non-nil to show feedback on MI classification."
  :type 'boolean
  :group 'ewwm-bci-mi)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-bci-mi--calibrated nil
  "Non-nil when MI classifier has been calibrated.")

(defvar ewwm-bci-mi--last-result nil
  "Plist of last MI classification result.
Contains :class, :confidence, :band-power.")

(defvar ewwm-bci-mi--classifications 0
  "Total MI classifications this session.")

(defvar ewwm-bci-mi--last-dispatch-time nil
  "Float-time of last MI action dispatch.")

(defvar ewwm-bci-mi--calibration-progress nil
  "Current calibration progress (0-100), or nil.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-bci-mi-classify-hook nil
  "Hook run on successful MI classification.
Functions receive (CLASS CONFIDENCE) where CLASS
is a symbol: left, right, or foot.")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-bci-mi--on-bci-mi (msg)
  "Handle :bci-mi event MSG.
Dispatches configured action for classified MI class."
  (when ewwm-bci-mi-enabled
    (let* ((class (plist-get msg :class))
           (confidence (plist-get msg :confidence))
           (now (float-time))
           (cooled-down
            (or (null ewwm-bci-mi--last-dispatch-time)
                (>= (* 1000.0
                       (- now
                          ewwm-bci-mi--last-dispatch-time))
                    ewwm-bci-mi-cooldown-ms))))
      ;; Always update last result
      (setq ewwm-bci-mi--last-result
            (list :class class
                  :confidence confidence
                  :band-power (plist-get msg :band-power)))
      ;; Dispatch if confident and cooled down
      (when (and class confidence
                 (>= confidence ewwm-bci-mi-min-confidence)
                 cooled-down)
        (let ((action (cond
                       ((eq class 'left)
                        ewwm-bci-mi-left-action)
                       ((eq class 'right)
                        ewwm-bci-mi-right-action)
                       ((eq class 'foot)
                        ewwm-bci-mi-foot-action)
                       (t nil))))
          (when (functionp action)
            (cl-incf ewwm-bci-mi--classifications)
            (setq ewwm-bci-mi--last-dispatch-time now)
            (funcall action)
            (when ewwm-bci-mi-feedback
              (message "ewwm-bci-mi: %s (%.0f%%)"
                       class (* 100.0 confidence)))
            (run-hook-with-args 'ewwm-bci-mi-classify-hook
                                class confidence)))))))

(defun ewwm-bci-mi--on-bci-mi-calibration (msg)
  "Handle :bci-mi-calibration event MSG.
Updates calibration progress and status."
  (let ((status (plist-get msg :status))
        (progress (plist-get msg :progress)))
    (when progress
      (setq ewwm-bci-mi--calibration-progress progress))
    (cond
     ((eq status 'complete)
      (setq ewwm-bci-mi--calibrated t
            ewwm-bci-mi--calibration-progress nil)
      (message "ewwm-bci-mi: calibration complete"))
     ((eq status 'failed)
      (setq ewwm-bci-mi--calibration-progress nil)
      (message "ewwm-bci-mi: calibration failed — %s"
               (or (plist-get msg :reason) "unknown")))
     ((eq status 'progress)
      (message "ewwm-bci-mi: calibration %d%%"
               (or progress 0))))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-bci-mi-calibrate ()
  "Start motor imagery calibration.
The user performs imagined hand/foot movements
as guided by visual cues."
  (interactive)
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-bci: compositor not connected")
    (setq ewwm-bci-mi--calibrated nil
          ewwm-bci-mi--calibration-progress 0)
    (ewwm-ipc-send
     `(:type :bci-mi-calibrate
       :classes ,(list 'left 'right 'foot)))
    (message
     "ewwm-bci-mi: calibration started — follow cues")))

(defun ewwm-bci-mi-status ()
  "Display MI classification status."
  (interactive)
  (let ((cls (plist-get ewwm-bci-mi--last-result :class))
        (conf (plist-get ewwm-bci-mi--last-result
                         :confidence)))
    (message
     "ewwm-bci-mi: enabled=%s cal=%s cls=%d last=%s(%.0f%%)"
     (if ewwm-bci-mi-enabled "yes" "no")
     (if ewwm-bci-mi--calibrated "yes" "no")
     ewwm-bci-mi--classifications
     (or cls "-")
     (* 100.0 (or conf 0.0)))))

(defun ewwm-bci-mi-toggle ()
  "Toggle motor imagery classification on or off."
  (interactive)
  (setq ewwm-bci-mi-enabled (not ewwm-bci-mi-enabled))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :bci-mi-toggle
       :enable ,ewwm-bci-mi-enabled)))
  (message "ewwm-bci-mi: %s"
           (if ewwm-bci-mi-enabled
               "enabled" "disabled")))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-bci-mi-mode-line-string ()
  "Return mode-line string for MI state.
Shows last class and confidence."
  (when ewwm-bci-mi-enabled
    (let ((cls (plist-get ewwm-bci-mi--last-result :class)))
      (cond
       ((eq cls 'left)  " [MI:L]")
       ((eq cls 'right) " [MI:R]")
       ((eq cls 'foot)  " [MI:F]")
       (t nil)))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-bci-mi--register-events ()
  "Register MI event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:bci-mi             . ewwm-bci-mi--on-bci-mi)
     (:bci-mi-calibration . ewwm-bci-mi--on-bci-mi-calibration))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-bci-mi-init ()
  "Initialize motor imagery classification."
  (ewwm-bci-mi--register-events))

(defun ewwm-bci-mi-teardown ()
  "Clean up MI state."
  (setq ewwm-bci-mi--calibrated nil
        ewwm-bci-mi--last-result nil
        ewwm-bci-mi--classifications 0
        ewwm-bci-mi--last-dispatch-time nil
        ewwm-bci-mi--calibration-progress nil))

(provide 'ewwm-bci-mi)
;;; ewwm-bci-mi.el ends here
