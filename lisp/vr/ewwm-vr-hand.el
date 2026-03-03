;;; ewwm-vr-hand.el --- Hand tracking integration  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Hand tracking for ewwm: OpenXR XR_EXT_hand_tracking, confidence
;; monitoring, skeleton visualization, and dominant hand configuration.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-hand nil
  "Hand tracking settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-hand-enable t
  "Master switch for hand tracking."
  :type 'boolean
  :group 'ewwm-vr-hand)

(defcustom ewwm-vr-hand-min-confidence 0.5
  "Minimum confidence to accept hand tracking data.
Samples below this threshold are ignored."
  :type 'number
  :group 'ewwm-vr-hand)

(defcustom ewwm-vr-hand-smoothing 0.3
  "EMA alpha for hand position smoothing.
0 = maximum smooth (high latency), 1 = no smoothing."
  :type 'number
  :group 'ewwm-vr-hand)

(defcustom ewwm-vr-hand-prediction-ms 20.0
  "Prediction lookahead in milliseconds.
Higher values reduce perceived latency but increase jitter."
  :type 'number
  :group 'ewwm-vr-hand)

(defcustom ewwm-vr-hand-show-skeleton nil
  "Non-nil to enable debug skeleton visualization."
  :type 'boolean
  :group 'ewwm-vr-hand)

(defcustom ewwm-vr-hand-dominant 'right
  "Dominant hand for asymmetric gesture bindings."
  :type '(choice (const left) (const right))
  :group 'ewwm-vr-hand)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-hand--left-active nil
  "Non-nil when the left hand is tracked.")

(defvar ewwm-vr-hand--right-active nil
  "Non-nil when the right hand is tracked.")

(defvar ewwm-vr-hand--left-confidence 0.0
  "Current left hand tracking confidence [0.0, 1.0].")

(defvar ewwm-vr-hand--right-confidence 0.0
  "Current right hand tracking confidence [0.0, 1.0].")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-hand-tracking-started-hook nil
  "Hook run when hand tracking starts.
Functions receive (HAND) where HAND is `left' or `right'.")

(defvar ewwm-vr-hand-tracking-lost-hook nil
  "Hook run when hand tracking is lost.
Functions receive (HAND) where HAND is `left' or `right'.")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-hand--on-tracking-started (msg)
  "Handle :hand-tracking-started event MSG.
Sets the appropriate hand to active state."
  (let ((hand (plist-get msg :hand)))
    (cond
     ((eq hand 'left)
      (setq ewwm-vr-hand--left-active t))
     ((eq hand 'right)
      (setq ewwm-vr-hand--right-active t)))
    (run-hook-with-args 'ewwm-vr-hand-tracking-started-hook hand)))

(defun ewwm-vr-hand--on-tracking-lost (msg)
  "Handle :hand-tracking-lost event MSG.
Clears active state for the lost hand."
  (let ((hand (plist-get msg :hand)))
    (cond
     ((eq hand 'left)
      (setq ewwm-vr-hand--left-active nil
            ewwm-vr-hand--left-confidence 0.0))
     ((eq hand 'right)
      (setq ewwm-vr-hand--right-active nil
            ewwm-vr-hand--right-confidence 0.0)))
    (run-hook-with-args 'ewwm-vr-hand-tracking-lost-hook hand)))

(defun ewwm-vr-hand--on-confidence-update (msg)
  "Handle :hand-confidence event MSG.
Updates per-hand confidence values."
  (let ((hand (plist-get msg :hand))
        (confidence (plist-get msg :confidence)))
    (when confidence
      (cond
       ((eq hand 'left)
        (setq ewwm-vr-hand--left-confidence confidence))
       ((eq hand 'right)
        (setq ewwm-vr-hand--right-confidence confidence))))))

(defun ewwm-vr-hand--handle-event (event)
  "Route hand tracking EVENT to the appropriate handler."
  (let ((type (plist-get event :type)))
    (cond
     ((eq type :hand-tracking-started)
      (ewwm-vr-hand--on-tracking-started event))
     ((eq type :hand-tracking-lost)
      (ewwm-vr-hand--on-tracking-lost event))
     ((eq type :hand-confidence)
      (ewwm-vr-hand--on-confidence-update event)))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-hand-status ()
  "Display hand tracking info in the minibuffer."
  (interactive)
  (message "ewwm-vr-hand: L=%s(%.2f) R=%s(%.2f) dom=%s skel=%s"
           (if ewwm-vr-hand--left-active "ON" "off")
           ewwm-vr-hand--left-confidence
           (if ewwm-vr-hand--right-active "ON" "off")
           ewwm-vr-hand--right-confidence
           ewwm-vr-hand-dominant
           (if ewwm-vr-hand-show-skeleton "on" "off")))

(defun ewwm-vr-hand-toggle ()
  "Toggle hand tracking on or off."
  (interactive)
  (setq ewwm-vr-hand-enable (not ewwm-vr-hand-enable))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :hand-tracking-toggle
       :enable ,ewwm-vr-hand-enable)))
  (message "ewwm-vr-hand: %s"
           (if ewwm-vr-hand-enable "enabled" "disabled")))

(defun ewwm-vr-hand-configure ()
  "Send hand tracking configuration to the compositor."
  (interactive)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :hand-tracking-configure
       :enable ,ewwm-vr-hand-enable
       :min-confidence ,ewwm-vr-hand-min-confidence
       :smoothing ,ewwm-vr-hand-smoothing
       :prediction-ms ,ewwm-vr-hand-prediction-ms
       :show-skeleton ,ewwm-vr-hand-show-skeleton
       :dominant ,(symbol-name ewwm-vr-hand-dominant)))
    (message "ewwm-vr-hand: configuration sent")))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-hand-mode-line-string ()
  "Return a mode-line string for hand tracking state.
Shows \" [H:L+R]\" when both tracked, \" [H:L]\", \" [H:R]\",
or \" [H:-]\" when none tracked.  Returns nil when disabled."
  (when ewwm-vr-hand-enable
    (cond
     ((and ewwm-vr-hand--left-active ewwm-vr-hand--right-active)
      " [H:L+R]")
     (ewwm-vr-hand--left-active  " [H:L]")
     (ewwm-vr-hand--right-active " [H:R]")
     (t " [H:-]"))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-hand--register-events ()
  "Register hand tracking event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:hand-tracking-started . ewwm-vr-hand--on-tracking-started)
     (:hand-tracking-lost    . ewwm-vr-hand--on-tracking-lost)
     (:hand-confidence       . ewwm-vr-hand--on-confidence-update))))

;; ── Minor mode ───────────────────────────────────────────────

(define-minor-mode ewwm-vr-hand-mode
  "Minor mode for hand tracking integration."
  :lighter " VR-Hand"
  :group 'ewwm-vr-hand
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c h s") #'ewwm-vr-hand-status)
            (define-key map (kbd "C-c h t") #'ewwm-vr-hand-toggle)
            (define-key map (kbd "C-c h c") #'ewwm-vr-hand-configure)
            map))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-hand-init ()
  "Initialize hand tracking integration."
  (ewwm-vr-hand--register-events)
  (when ewwm-vr-hand-enable
    (ewwm-vr-hand-configure)))

(defun ewwm-vr-hand-teardown ()
  "Clean up hand tracking state."
  (setq ewwm-vr-hand--left-active nil
        ewwm-vr-hand--right-active nil
        ewwm-vr-hand--left-confidence 0.0
        ewwm-vr-hand--right-confidence 0.0))

(provide 'ewwm-vr-hand)
;;; ewwm-vr-hand.el ends here
