;;; ewwm-bci-multimodal.el --- Multi-modal fusion  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Multi-modal input fusion for ewwm: combines EEG attention
;; state with gaze tracking and hand gestures.  Provides
;; adaptive dwell timing based on focus level, two-factor
;; confirmation (gaze + MI), and three-factor high-assurance
;; mode (gaze + P300 + pinch) for security-critical actions.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")
(declare-function ewwm-bci-p300-confirm "ewwm-bci-p300")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-bci-multimodal nil
  "Multi-modal input fusion settings."
  :group 'ewwm-bci)

(defcustom ewwm-bci-multimodal-enabled nil
  "Non-nil to enable multi-modal fusion."
  :type 'boolean
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-adaptive-dwell t
  "Non-nil to adjust gaze dwell time by focus level.
When the user is deeply focused, dwell time shortens.
When relaxed or drowsy, dwell time lengthens."
  :type 'boolean
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-dwell-focused-ms 150
  "Gaze dwell time in ms when deeply focused.
Used when attention score is above the focused threshold."
  :type 'integer
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-dwell-relaxed-ms 400
  "Gaze dwell time in ms when relaxed or drowsy.
Used when attention score is below the relaxed threshold."
  :type 'integer
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-dwell-default-ms 250
  "Default gaze dwell time in ms for neutral state."
  :type 'integer
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-focused-threshold 0.7
  "Attention score threshold for focused dwell time."
  :type 'number
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-relaxed-threshold 0.4
  "Attention score threshold for relaxed dwell time."
  :type 'number
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-two-factor nil
  "Non-nil to require two-factor confirmation.
Gaze selects a target, motor imagery confirms it.
This reduces accidental activations by requiring
intentional thought to confirm gaze selections."
  :type 'boolean
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-two-factor-timeout-ms 3000
  "Timeout in ms for MI confirmation after gaze select."
  :type 'integer
  :group 'ewwm-bci-multimodal)

(defcustom ewwm-bci-multimodal-three-factor-security nil
  "Non-nil to enable three-factor security mode.
Requires gaze + P300 + pinch gesture for high-assurance
actions like credential entry or destructive commands."
  :type 'boolean
  :group 'ewwm-bci-multimodal)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-bci-multimodal--active nil
  "Non-nil when multi-modal fusion is active.")

(defvar ewwm-bci-multimodal--dwell-override nil
  "Current dwell time override in ms, or nil for default.")

(defvar ewwm-bci-multimodal--pending-confirm nil
  "Pending two-factor confirmation plist.
Contains :target, :action, :time, :modality.")

(defvar ewwm-bci-multimodal--confirm-timer nil
  "Timer for two-factor confirmation timeout.")

(defvar ewwm-bci-multimodal--three-factor-state nil
  "State plist for three-factor verification.
Contains :gaze, :p300, :pinch progress flags.")

(defvar ewwm-bci-multimodal--three-factor-callback nil
  "Callback for three-factor verification, or nil.")

(defvar ewwm-bci-multimodal--last-attention-score 0.0
  "Cached attention score for dwell adjustment.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-bci-multimodal-fusion-hook nil
  "Hook run when a fused multi-modal action completes.
Functions receive (FUSED-ACTION MODALITIES) where
MODALITIES is a list of symbols (gaze, mi, p300, pinch).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-bci-multimodal--on-bci-multimodal (msg)
  "Handle :bci-multimodal event MSG.
Routes to appropriate sub-handler based on event subtype."
  (when (and ewwm-bci-multimodal-enabled
             ewwm-bci-multimodal--active)
    (let ((subtype (plist-get msg :subtype)))
      (cond
       ((eq subtype 'attention-update)
        (ewwm-bci-multimodal--handle-attention msg))
       ((eq subtype 'gaze-select)
        (ewwm-bci-multimodal--handle-gaze-select msg))
       ((eq subtype 'mi-confirm)
        (ewwm-bci-multimodal--handle-mi-confirm msg))
       ((eq subtype 'pinch-confirm)
        (ewwm-bci-multimodal--handle-pinch-confirm msg))
       ((eq subtype 'dwell-update)
        (ewwm-bci-multimodal--handle-dwell-update msg))))))

;; ── Adaptive dwell ──────────────────────────────────────────

(defun ewwm-bci-multimodal--handle-attention (msg)
  "Update dwell time based on attention score in MSG."
  (when ewwm-bci-multimodal-adaptive-dwell
    (let ((score (plist-get msg :score)))
      (when score
        (setq ewwm-bci-multimodal--last-attention-score score)
        (let ((new-dwell
               (cond
                ((>= score
                     ewwm-bci-multimodal-focused-threshold)
                 ewwm-bci-multimodal-dwell-focused-ms)
                ((<= score
                     ewwm-bci-multimodal-relaxed-threshold)
                 ewwm-bci-multimodal-dwell-relaxed-ms)
                (t ewwm-bci-multimodal-dwell-default-ms))))
          (unless (equal new-dwell
                         ewwm-bci-multimodal--dwell-override)
            (setq ewwm-bci-multimodal--dwell-override
                  new-dwell)
            ;; Notify compositor of new dwell time
            (when (and (fboundp 'ewwm-ipc-connected-p)
                       (ewwm-ipc-connected-p))
              (ewwm-ipc-send
               `(:type :multimodal-set-dwell
                 :dwell-ms ,new-dwell)))))))))

(defun ewwm-bci-multimodal--handle-dwell-update (msg)
  "Handle dwell time update confirmation from MSG."
  (let ((dwell (plist-get msg :dwell-ms)))
    (when dwell
      (setq ewwm-bci-multimodal--dwell-override dwell))))

;; ── Two-factor: gaze + MI ───────────────────────────────────

(defun ewwm-bci-multimodal--handle-gaze-select (msg)
  "Handle gaze selection in MSG.
If two-factor is enabled, queues for MI confirmation."
  (let ((target (plist-get msg :target))
        (action (plist-get msg :action)))
    (cond
     ;; Two-factor: queue for MI confirmation
     (ewwm-bci-multimodal-two-factor
      (ewwm-bci-multimodal--cancel-pending)
      (setq ewwm-bci-multimodal--pending-confirm
            (list :target target
                  :action action
                  :time (float-time)
                  :modality 'gaze))
      ;; Set timeout
      (setq ewwm-bci-multimodal--confirm-timer
            (run-with-timer
             (/ ewwm-bci-multimodal-two-factor-timeout-ms
                1000.0)
             nil
             #'ewwm-bci-multimodal--confirm-timeout))
      (message "ewwm-bci: gaze selected %s — think to confirm"
               target))
     ;; Single-factor: dispatch immediately
     (t
      (ewwm-bci-multimodal--dispatch-action
       target action '(gaze))))))

(defun ewwm-bci-multimodal--handle-mi-confirm (msg)
  "Handle MI confirmation in MSG for two-factor mode."
  (when ewwm-bci-multimodal--pending-confirm
    (let* ((class (plist-get msg :class))
           (confidence (plist-get msg :confidence))
           (target (plist-get
                    ewwm-bci-multimodal--pending-confirm
                    :target))
           (action (plist-get
                    ewwm-bci-multimodal--pending-confirm
                    :action)))
      ;; Any MI class above threshold confirms
      (when (and class confidence (>= confidence 0.5))
        (ewwm-bci-multimodal--cancel-pending)
        (ewwm-bci-multimodal--dispatch-action
         target action '(gaze mi))))))

(defun ewwm-bci-multimodal--confirm-timeout ()
  "Handle two-factor confirmation timeout."
  (when ewwm-bci-multimodal--pending-confirm
    (message "ewwm-bci: confirmation timed out")
    (setq ewwm-bci-multimodal--pending-confirm nil
          ewwm-bci-multimodal--confirm-timer nil)))

(defun ewwm-bci-multimodal--cancel-pending ()
  "Cancel any pending confirmation."
  (when ewwm-bci-multimodal--confirm-timer
    (cancel-timer ewwm-bci-multimodal--confirm-timer)
    (setq ewwm-bci-multimodal--confirm-timer nil))
  (setq ewwm-bci-multimodal--pending-confirm nil))

;; ── Three-factor: gaze + P300 + pinch ──────────────────────

(defun ewwm-bci-multimodal-three-factor-verify
    (action callback)
  "Start three-factor verification for ACTION.
Requires gaze fixation, P300 confirmation, and pinch gesture.
CALLBACK is called with (ACTION t) on success or
(ACTION nil) on failure/timeout."
  (if (not ewwm-bci-multimodal-three-factor-security)
      ;; Not enabled, pass through
      (funcall callback action t)
    (setq ewwm-bci-multimodal--three-factor-state
          (list :gaze nil :p300 nil :pinch nil)
          ewwm-bci-multimodal--three-factor-callback
          (cons action callback))
    ;; Start P300 confirmation
    (when (fboundp 'ewwm-bci-p300-confirm)
      (ewwm-bci-p300-confirm
       (format "Verify: %s" action)
       '("confirm" "cancel")
       (lambda (target _confidence)
         (if (equal target "confirm")
             (progn
               (plist-put
                ewwm-bci-multimodal--three-factor-state
                :p300 t)
               (ewwm-bci-multimodal--check-three-factor))
           (ewwm-bci-multimodal--three-factor-fail)))))
    ;; Request gaze fixation and pinch via IPC
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       `(:type :multimodal-three-factor-start
         :action ,action)))
    (message "ewwm-bci: three-factor verify — %s" action)))

(defun ewwm-bci-multimodal--handle-pinch-confirm (_msg)
  "Handle pinch confirmation for three-factor in _MSG."
  (when ewwm-bci-multimodal--three-factor-state
    (plist-put ewwm-bci-multimodal--three-factor-state
               :pinch t)
    (ewwm-bci-multimodal--check-three-factor)))

(defun ewwm-bci-multimodal--check-three-factor ()
  "Check if all three factors are satisfied."
  (when ewwm-bci-multimodal--three-factor-state
    (let ((s ewwm-bci-multimodal--three-factor-state))
      (when (and (plist-get s :p300)
                 (plist-get s :pinch))
        ;; P300 + pinch sufficient (gaze implicit from P300)
        (let* ((pair ewwm-bci-multimodal--three-factor-callback)
               (action (car pair))
               (cb (cdr pair)))
          (setq ewwm-bci-multimodal--three-factor-state nil
                ewwm-bci-multimodal--three-factor-callback
                nil)
          (message "ewwm-bci: three-factor verified")
          (when (functionp cb)
            (funcall cb action t)))))))

(defun ewwm-bci-multimodal--three-factor-fail ()
  "Handle three-factor verification failure."
  (let* ((pair ewwm-bci-multimodal--three-factor-callback)
         (action (car pair))
         (cb (cdr pair)))
    (setq ewwm-bci-multimodal--three-factor-state nil
          ewwm-bci-multimodal--three-factor-callback nil)
    (message "ewwm-bci: three-factor verification failed")
    (when (functionp cb)
      (funcall cb action nil))))

;; ── Action dispatch ─────────────────────────────────────────

(defun ewwm-bci-multimodal--dispatch-action
    (target action modalities)
  "Dispatch fused ACTION on TARGET with MODALITIES list."
  (when (functionp action)
    (funcall action target))
  (run-hook-with-args 'ewwm-bci-multimodal-fusion-hook
                      action modalities)
  (message "ewwm-bci: fused action via %s"
           (mapconcat #'symbol-name modalities "+")))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-bci-multimodal-status ()
  "Display multi-modal fusion status."
  (interactive)
  (message
   (concat
    "ewwm-bci-multimodal: active=%s dwell=%sms "
    "attn=%.2f 2fa=%s 3fa=%s")
   (if ewwm-bci-multimodal--active "yes" "no")
   (or ewwm-bci-multimodal--dwell-override "-")
   ewwm-bci-multimodal--last-attention-score
   (if ewwm-bci-multimodal-two-factor "on" "off")
   (if ewwm-bci-multimodal-three-factor-security
       "on" "off")))

(defun ewwm-bci-multimodal-toggle ()
  "Toggle multi-modal fusion on or off."
  (interactive)
  (setq ewwm-bci-multimodal-enabled
        (not ewwm-bci-multimodal-enabled))
  (cond
   (ewwm-bci-multimodal-enabled
    (setq ewwm-bci-multimodal--active t)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send '(:type :multimodal-enable)))
    (message "ewwm-bci-multimodal: enabled"))
   (t
    (ewwm-bci-multimodal--cancel-pending)
    (setq ewwm-bci-multimodal--active nil
          ewwm-bci-multimodal--dwell-override nil)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send '(:type :multimodal-disable)))
    (message "ewwm-bci-multimodal: disabled"))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-bci-multimodal--register-events ()
  "Register multimodal event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:bci-multimodal . ewwm-bci-multimodal--on-bci-multimodal))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-bci-multimodal-init ()
  "Initialize multi-modal fusion."
  (ewwm-bci-multimodal--register-events))

(defun ewwm-bci-multimodal-teardown ()
  "Clean up multi-modal state."
  (ewwm-bci-multimodal--cancel-pending)
  (when ewwm-bci-multimodal--three-factor-state
    (ewwm-bci-multimodal--three-factor-fail))
  (setq ewwm-bci-multimodal--active nil
        ewwm-bci-multimodal--dwell-override nil
        ewwm-bci-multimodal--pending-confirm nil
        ewwm-bci-multimodal--three-factor-state nil
        ewwm-bci-multimodal--three-factor-callback nil
        ewwm-bci-multimodal--last-attention-score 0.0))

(provide 'ewwm-bci-multimodal)
;;; ewwm-bci-multimodal.el ends here
