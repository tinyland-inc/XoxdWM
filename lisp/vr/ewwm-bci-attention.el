;;; ewwm-bci-attention.el --- Attention state tracking  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Attention state tracking from EEG band power ratios.
;; Adapts window manager behavior: auto-DND on deep focus,
;; break alerts on drowsiness, and auto-save on attention loss.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-bci-attention nil
  "BCI attention state tracking settings."
  :group 'ewwm-bci)

(defcustom ewwm-bci-attention-enabled t
  "Master switch for attention tracking."
  :type 'boolean
  :group 'ewwm-bci-attention)

(defcustom ewwm-bci-attention-threshold 0.6
  "Score threshold for focused state detection.
Values above this enter the focused state."
  :type 'number
  :group 'ewwm-bci-attention)

(defcustom ewwm-bci-attention-dnd-threshold 0.8
  "Score threshold for deep focus auto-DND.
When the attention score exceeds this threshold,
notifications are suppressed automatically."
  :type 'number
  :group 'ewwm-bci-attention)

(defcustom ewwm-bci-attention-drowsy-threshold 0.2
  "Score threshold for drowsiness detection.
Below this threshold, break alerts are shown."
  :type 'number
  :group 'ewwm-bci-attention)

(defcustom ewwm-bci-attention-break-minutes 5
  "Minutes of drowsiness before suggesting a break."
  :type 'integer
  :group 'ewwm-bci-attention)

(defcustom ewwm-bci-attention-auto-save t
  "Non-nil to auto-save buffers on attention loss.
Triggers `save-some-buffers' when transitioning
from focused to drowsy."
  :type 'boolean
  :group 'ewwm-bci-attention)

(defcustom ewwm-bci-attention-update-interval 2.0
  "Minimum seconds between state change processing.
Prevents rapid oscillation between states."
  :type 'number
  :group 'ewwm-bci-attention)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-bci-attention--state 'neutral
  "Current attention state symbol.
One of: neutral, focused, deep-focus, drowsy.")

(defvar ewwm-bci-attention--score 0.0
  "Current attention score in [0.0, 1.0].")

(defvar ewwm-bci-attention--band-powers nil
  "Plist of EEG band powers.
Keys: :delta :theta :alpha :beta :gamma.
Values are floats in microvolts squared.")

(defvar ewwm-bci-attention--dnd-active nil
  "Non-nil when auto-DND is currently active.")

(defvar ewwm-bci-attention--state-start-time nil
  "Float-time when current state was entered.")

(defvar ewwm-bci-attention--last-update-time nil
  "Float-time of last state update.")

(defvar ewwm-bci-attention--history nil
  "List of recent (TIME . SCORE) pairs.
Kept to a maximum of 60 entries for trend analysis.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-bci-attention-change-hook nil
  "Hook run when attention state changes.
Functions receive (OLD-STATE NEW-STATE SCORE).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-bci-attention--on-bci-attention (msg)
  "Handle :bci-attention event MSG.
Updates state, manages DND, handles drowsiness,
and fires hooks on transitions."
  (when ewwm-bci-attention-enabled
    (let* ((score (plist-get msg :score))
           (bands (plist-get msg :band-powers))
           (now (float-time))
           (old-state ewwm-bci-attention--state)
           (debounced
            (or (null ewwm-bci-attention--last-update-time)
                (>= (- now ewwm-bci-attention--last-update-time)
                    ewwm-bci-attention-update-interval))))
      ;; Always update raw score and bands
      (when score
        (setq ewwm-bci-attention--score score)
        ;; Record history
        (push (cons now score) ewwm-bci-attention--history)
        (when (> (length ewwm-bci-attention--history) 60)
          (setq ewwm-bci-attention--history
                (cl-subseq ewwm-bci-attention--history
                            0 60))))
      (when bands
        (setq ewwm-bci-attention--band-powers bands))
      ;; Process state transitions (debounced)
      (when (and score debounced)
        (setq ewwm-bci-attention--last-update-time now)
        (let ((new-state
               (cond
                ((>= score ewwm-bci-attention-dnd-threshold)
                 'deep-focus)
                ((>= score ewwm-bci-attention-threshold)
                 'focused)
                ((<= score ewwm-bci-attention-drowsy-threshold)
                 'drowsy)
                (t 'neutral))))
          (unless (eq new-state old-state)
            (setq ewwm-bci-attention--state new-state
                  ewwm-bci-attention--state-start-time now)
            ;; Handle DND transitions
            (ewwm-bci-attention--handle-dnd new-state)
            ;; Handle drowsy transitions
            (ewwm-bci-attention--handle-drowsy
             old-state new-state)
            ;; Fire hook
            (run-hook-with-args
             'ewwm-bci-attention-change-hook
             old-state new-state score)))))))

;; ── Attention-adaptive behavior ─────────────────────────────

(defun ewwm-bci-attention--handle-dnd (state)
  "Manage auto-DND based on attention STATE.
Activates DND on deep-focus, deactivates otherwise."
  (cond
   ((and (eq state 'deep-focus)
         (not ewwm-bci-attention--dnd-active))
    (setq ewwm-bci-attention--dnd-active t)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send '(:type :bci-dnd-enable)))
    (message "ewwm-bci: deep focus — DND enabled"))
   ((and (not (eq state 'deep-focus))
         ewwm-bci-attention--dnd-active)
    (setq ewwm-bci-attention--dnd-active nil)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send '(:type :bci-dnd-disable)))
    (message "ewwm-bci: DND disabled"))))

(defun ewwm-bci-attention--handle-drowsy (old-state new-state)
  "Handle drowsiness transition from OLD-STATE to NEW-STATE.
Auto-saves buffers and shows alert on drowsy entry."
  (when (and (eq new-state 'drowsy)
             (not (eq old-state 'drowsy)))
    ;; Auto-save on attention loss
    (when (and ewwm-bci-attention-auto-save
               (not noninteractive))
      (save-some-buffers t))
    ;; Alert user
    (unless noninteractive
      (display-warning
       'ewwm-bci-attention
       (format "Drowsiness detected (score=%.2f). %s"
               ewwm-bci-attention--score
               "Consider taking a break.")
       :warning))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-bci-attention-status ()
  "Display attention state in the minibuffer."
  (interactive)
  (let ((dur (if ewwm-bci-attention--state-start-time
                 (/ (- (float-time)
                       ewwm-bci-attention--state-start-time)
                    60.0)
               0.0)))
    (message
     "ewwm-bci-attention: state=%s score=%.2f dnd=%s dur=%.1fm"
     ewwm-bci-attention--state
     ewwm-bci-attention--score
     (if ewwm-bci-attention--dnd-active "on" "off")
     dur)))

(defun ewwm-bci-attention-calibrate ()
  "Request attention baseline calibration via IPC.
The user should sit relaxed with eyes open for 30s."
  (interactive)
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-bci: compositor not connected")
    (ewwm-ipc-send '(:type :bci-attention-calibrate))
    (message
     "ewwm-bci: calibrating — relax with eyes open for 30s")))

(defun ewwm-bci-attention-toggle ()
  "Toggle attention tracking on or off."
  (interactive)
  (setq ewwm-bci-attention-enabled
        (not ewwm-bci-attention-enabled))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :bci-attention-toggle
       :enable ,ewwm-bci-attention-enabled)))
  (message "ewwm-bci-attention: %s"
           (if ewwm-bci-attention-enabled
               "enabled" "disabled")))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-bci-attention-mode-line-string ()
  "Return mode-line string for attention state.
Shows score and state indicator."
  (when ewwm-bci-attention-enabled
    (let ((label (cond
                  ((eq ewwm-bci-attention--state 'deep-focus)
                   "DEEP")
                  ((eq ewwm-bci-attention--state 'focused)
                   "FOCUS")
                  ((eq ewwm-bci-attention--state 'drowsy)
                   "DROWSY")
                  (t nil))))
      (when label
        (format " [Att:%s %.0f%%]"
                label
                (* 100 ewwm-bci-attention--score))))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-bci-attention--register-events ()
  "Register attention event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:bci-attention . ewwm-bci-attention--on-bci-attention))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-bci-attention-init ()
  "Initialize attention tracking."
  (ewwm-bci-attention--register-events))

(defun ewwm-bci-attention-teardown ()
  "Clean up attention tracking state."
  (when ewwm-bci-attention--dnd-active
    (setq ewwm-bci-attention--dnd-active nil)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send '(:type :bci-dnd-disable))))
  (setq ewwm-bci-attention--state 'neutral
        ewwm-bci-attention--score 0.0
        ewwm-bci-attention--band-powers nil
        ewwm-bci-attention--state-start-time nil
        ewwm-bci-attention--last-update-time nil
        ewwm-bci-attention--history nil))

(provide 'ewwm-bci-attention)
;;; ewwm-bci-attention.el ends here
