;;; ewwm-vr-wink.el --- Wink-based interaction for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Blink/wink detection integration: configurable wink-to-command mapping,
;; double-wink sequences, calibration wizard, and visual feedback.

;;; Code:

(require 'cl-lib)
(require 'ring)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-wink nil
  "Wink-based interaction settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-wink-enable t
  "Master switch for wink-based interaction."
  :type 'boolean
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-wink-left-action #'previous-buffer
  "Function called on left wink."
  :type 'function
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-wink-right-action #'next-buffer
  "Function called on right wink."
  :type 'function
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-wink-double-left-action #'mode-line-other-buffer
  "Function called on double left wink."
  :type 'function
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-wink-double-right-action #'delete-window
  "Function called on double right wink."
  :type 'function
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-blink-confidence-min 0.7
  "Minimum confidence for blink detection.
Samples below this threshold are ignored."
  :type 'number
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-wink-feedback t
  "Non-nil to show mode-line feedback on wink."
  :type 'boolean
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-wink-sequences nil
  "Alist of (SEQUENCE . COMMAND) for custom multi-wink commands.
SEQUENCE is a list of wink symbols like (:left :right :left).
COMMAND is a function to call when the sequence is matched."
  :type '(alist :key-type (repeat symbol) :value-type function)
  :group 'ewwm-vr-wink)

(defcustom ewwm-vr-wink-sequence-timeout-ms 1500
  "Maximum time in milliseconds between winks in a sequence."
  :type 'integer
  :group 'ewwm-vr-wink)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-wink--last-wink nil
  "Symbol: left, right, or nil.")

(defvar ewwm-vr-wink--last-wink-time nil
  "Timestamp of last wink (from `current-time').")

(defvar ewwm-vr-wink--blink-count 0
  "Recent blink count.")

(defvar ewwm-vr-wink--blink-rate 0.0
  "Blinks per minute.")

(defvar ewwm-vr-wink--sequence-acc nil
  "Accumulated wink sequence (list of keyword symbols).")

(defvar ewwm-vr-wink--sequence-start-time nil
  "Timestamp when current sequence accumulation started.")

(defvar ewwm-vr-wink--calibrating nil
  "Non-nil during calibration.")

(defvar ewwm-vr-wink--calibration-phase nil
  "Current calibration phase: nil, left, right, or blink.")

(defvar ewwm-vr-wink--calibration-trials nil
  "List of recorded trial durations during calibration.")

(defvar ewwm-vr-wink--wink-history (make-ring 20)
  "Ring of recent wink events as plists.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-wink-hook nil
  "Hook run after a wink action is dispatched.
Functions receive (WINK-TYPE ACTION).")

(defvar ewwm-vr-blink-hook nil
  "Hook run on each detected blink.
Functions receive (EYE DURATION-MS CONFIDENCE).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-wink--on-blink (msg)
  "Handle :blink event MSG.
Update blink count and rate, run `ewwm-vr-blink-hook'."
  (let ((eye (plist-get msg :eye))
        (duration-ms (plist-get msg :duration-ms))
        (confidence (plist-get msg :confidence))
        (rate (plist-get msg :rate)))
    (when (and confidence (>= confidence ewwm-vr-blink-confidence-min))
      (cl-incf ewwm-vr-wink--blink-count)
      (when rate
        (setq ewwm-vr-wink--blink-rate rate))
      (run-hook-with-args 'ewwm-vr-blink-hook eye duration-ms confidence))))

(defun ewwm-vr-wink--on-wink (msg)
  "Handle :wink event MSG.
MSG contains :side (left/right) and optionally :double non-nil.
Dispatch the configured action for the wink type."
  (when ewwm-vr-wink-enable
    (let* ((side (plist-get msg :side))
           (double (plist-get msg :double))
           (confidence (plist-get msg :confidence))
           (wink-type (cond
                       ((and (eq side 'left) double) 'double-left)
                       ((and (eq side 'right) double) 'double-right)
                       ((eq side 'left) 'left)
                       ((eq side 'right) 'right)
                       (t nil))))
      (when (and wink-type
                 (or (null confidence)
                     (>= confidence ewwm-vr-blink-confidence-min)))
        ;; Record in history
        (ring-insert ewwm-vr-wink--wink-history
                     (list :type wink-type
                           :time (current-time)
                           :confidence confidence))
        ;; Update last-wink tracking
        (setq ewwm-vr-wink--last-wink wink-type
              ewwm-vr-wink--last-wink-time (current-time))
        ;; Dispatch
        (ewwm-vr-wink--dispatch-action wink-type)))))

(defun ewwm-vr-wink--on-wink-calibration (msg)
  "Handle :wink-calibration-result event MSG during calibration."
  (when ewwm-vr-wink--calibrating
    (let ((phase (plist-get msg :phase))
          (trial-ms (plist-get msg :trial-ms))
          (status (plist-get msg :status)))
      (cond
       ((eq status 'complete)
        (setq ewwm-vr-wink--calibrating nil
              ewwm-vr-wink--calibration-phase nil)
        (message "ewwm-vr-wink: calibration complete (%d trials recorded)"
                 (length ewwm-vr-wink--calibration-trials)))
       ((eq status 'phase-done)
        (setq ewwm-vr-wink--calibration-phase
              (cond
               ((eq phase 'left) 'right)
               ((eq phase 'right) 'blink)
               (t nil)))
        (message "ewwm-vr-wink: phase %s done, next: %s"
                 phase (or ewwm-vr-wink--calibration-phase "finish")))
       (t
        (when trial-ms
          (push trial-ms ewwm-vr-wink--calibration-trials))
        (message "ewwm-vr-wink: calibration trial recorded (%s, %dms)"
                 (or phase "?") (or trial-ms 0)))))))

;; ── Core logic ───────────────────────────────────────────────

(defun ewwm-vr-wink--dispatch-action (wink-type)
  "Look up and call the configured function for WINK-TYPE.
WINK-TYPE is a symbol: left, right, double-left, or double-right.
Also checks custom sequences before dispatching single actions."
  (let ((seq-cmd (ewwm-vr-wink--check-sequence wink-type)))
    (cond
     ;; Custom sequence matched
     (seq-cmd
      (when (functionp seq-cmd)
        (funcall seq-cmd)
        (ewwm-vr-wink--feedback wink-type)
        (run-hook-with-args 'ewwm-vr-wink-hook wink-type seq-cmd)))
     ;; Standard wink actions
     (t
      (let ((action (cond
                     ((eq wink-type 'left) ewwm-vr-wink-left-action)
                     ((eq wink-type 'right) ewwm-vr-wink-right-action)
                     ((eq wink-type 'double-left) ewwm-vr-wink-double-left-action)
                     ((eq wink-type 'double-right) ewwm-vr-wink-double-right-action)
                     (t nil))))
        (when (functionp action)
          (funcall action)
          (ewwm-vr-wink--feedback wink-type)
          (run-hook-with-args 'ewwm-vr-wink-hook wink-type action)))))))

(defun ewwm-vr-wink--check-sequence (wink-type)
  "Accumulate WINK-TYPE into sequence, check against `ewwm-vr-wink-sequences'.
Return matching command or nil.  Reset if timeout exceeded."
  (if (null ewwm-vr-wink-sequences)
      ;; No sequences configured, skip accumulation
      nil
    (let* ((now (current-time))
           (kw (cond
                ((eq wink-type 'left) :left)
                ((eq wink-type 'right) :right)
                ((eq wink-type 'double-left) :double-left)
                ((eq wink-type 'double-right) :double-right)
                (t nil)))
           ;; Check timeout: reset if too much time elapsed
           (timed-out (and ewwm-vr-wink--sequence-start-time
                           (> (* 1000.0
                                 (float-time
                                  (time-subtract now ewwm-vr-wink--sequence-start-time)))
                              ewwm-vr-wink-sequence-timeout-ms))))
      (when (or timed-out (null ewwm-vr-wink--sequence-acc))
        ;; Reset sequence
        (setq ewwm-vr-wink--sequence-acc nil
              ewwm-vr-wink--sequence-start-time now))
      ;; Accumulate
      (when kw
        (setq ewwm-vr-wink--sequence-acc
              (append ewwm-vr-wink--sequence-acc (list kw))))
      ;; Check for match
      (let ((match nil))
        (dolist (entry ewwm-vr-wink-sequences)
          (when (equal (car entry) ewwm-vr-wink--sequence-acc)
            (setq match (cdr entry))))
        (when match
          ;; Reset accumulator on match
          (setq ewwm-vr-wink--sequence-acc nil
                ewwm-vr-wink--sequence-start-time nil))
        match))))

(defun ewwm-vr-wink--feedback (wink-type)
  "Show brief mode-line feedback for WINK-TYPE."
  (when ewwm-vr-wink-feedback
    (let ((label (cond
                  ((eq wink-type 'left) "L")
                  ((eq wink-type 'right) "R")
                  ((eq wink-type 'double-left) "LL")
                  ((eq wink-type 'double-right) "RR")
                  (t "?"))))
      (message "ewwm-vr-wink: %s" label))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-wink-calibrate ()
  "Start wink calibration wizard.
Opens a calibration buffer with instructions and begins calibration
via IPC with 10 trials."
  (interactive)
  (if noninteractive
      (message "ewwm-vr-wink: calibration requires interactive Emacs")
    (setq ewwm-vr-wink--calibrating t
          ewwm-vr-wink--calibration-phase 'left
          ewwm-vr-wink--calibration-trials nil)
    (let ((buf (get-buffer-create "*ewwm-wink-calibration*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "EWWM Wink Calibration Wizard\n")
          (insert "============================\n\n")
          (insert "This wizard calibrates wink detection thresholds.\n\n")
          (insert "Phase 1: LEFT WINKS\n")
          (insert "  Close your LEFT eye firmly 10 times.\n")
          (insert "  Keep your right eye open.\n\n")
          (insert "Phase 2: RIGHT WINKS\n")
          (insert "  Close your RIGHT eye firmly 10 times.\n")
          (insert "  Keep your left eye open.\n\n")
          (insert "Phase 3: BLINKS\n")
          (insert "  Blink both eyes naturally 10 times.\n")
          (insert "  This helps distinguish blinks from winks.\n\n")
          (insert "Starting calibration...\n")
          (insert "\n[Press q to close this buffer]"))
        (special-mode))
      (unless noninteractive
        (display-buffer buf)))
    ;; Send calibration start via IPC
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       '(:type :wink-calibrate-start :trials 10)))
    (message "ewwm-vr-wink: calibration started — phase 1: left winks")))

(defun ewwm-vr-wink-status ()
  "Display wink detection status by querying compositor via IPC."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-wink: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :wink-status))))
          (if (eq (plist-get resp :status) :ok)
              (let ((w (plist-get resp :wink)))
                (message "ewwm-vr-wink: enabled=%s last=%s blinks/min=%.1f calibrated=%s"
                         (if ewwm-vr-wink-enable "yes" "no")
                         (or (plist-get w :last-wink) "none")
                         (or (plist-get w :blink-rate) ewwm-vr-wink--blink-rate)
                         (or (plist-get w :calibrated) "unknown")))
            (message "ewwm-vr-wink: status query failed")))
      (error (message "ewwm-vr-wink: %s" (error-message-string err))))))

(defun ewwm-vr-wink-set-actions ()
  "Interactively configure wink actions using `completing-read'."
  (interactive)
  (let* ((wink-types '("left" "right" "double-left" "double-right"))
         (chosen (completing-read "Configure wink type: " wink-types nil t))
         (cmd-name (read-command (format "Command for %s wink: " chosen))))
    (cond
     ((string= chosen "left")
      (setq ewwm-vr-wink-left-action cmd-name))
     ((string= chosen "right")
      (setq ewwm-vr-wink-right-action cmd-name))
     ((string= chosen "double-left")
      (setq ewwm-vr-wink-double-left-action cmd-name))
     ((string= chosen "double-right")
      (setq ewwm-vr-wink-double-right-action cmd-name)))
    (message "ewwm-vr-wink: %s wink action set to %s" chosen cmd-name)))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-wink-mode-line-string ()
  "Return a mode-line string showing last wink and blink rate.
Returns a string like \" [Wink:L]\" or \" [Wink:RR 12bpm]\", or nil
if no recent wink."
  (when ewwm-vr-wink-feedback
    (let* ((wink ewwm-vr-wink--last-wink)
           (wink-time ewwm-vr-wink--last-wink-time)
           ;; Only show if last wink was within 3 seconds
           (recent (and wink-time
                       (< (* 1000.0
                            (float-time
                             (time-subtract (current-time) wink-time)))
                          3000.0)))
           (label (cond
                   ((eq wink 'left) "L")
                   ((eq wink 'right) "R")
                   ((eq wink 'double-left) "LL")
                   ((eq wink 'double-right) "RR")
                   (t nil))))
      (cond
       ;; Recent wink with blink rate
       ((and recent label (> ewwm-vr-wink--blink-rate 0))
        (format " [Wink:%s %.0fbpm]" label ewwm-vr-wink--blink-rate))
       ;; Recent wink without blink rate
       ((and recent label)
        (format " [Wink:%s]" label))
       ;; No recent wink but blink rate available
       ((> ewwm-vr-wink--blink-rate 0)
        (format " [Wink:%.0fbpm]" ewwm-vr-wink--blink-rate))
       ;; Nothing to show
       (t nil)))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-wink--register-events ()
  "Register wink event handlers with IPC event dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:blink                    . ewwm-vr-wink--on-blink)
     (:wink                     . ewwm-vr-wink--on-wink)
     (:wink-calibration-result  . ewwm-vr-wink--on-wink-calibration))))

;; ── Minor mode ───────────────────────────────────────────────

(define-minor-mode ewwm-vr-wink-mode
  "Minor mode for wink-based interaction."
  :lighter " VR-Wink"
  :group 'ewwm-vr-wink
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c w c") #'ewwm-vr-wink-calibrate)
            (define-key map (kbd "C-c w s") #'ewwm-vr-wink-status)
            map))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-wink-init ()
  "Initialize wink-based interaction.
Register IPC event handlers and activate tracking."
  (ewwm-vr-wink--register-events)
  (setq ewwm-vr-wink-enable t))

(defun ewwm-vr-wink-teardown ()
  "Clear all wink state variables."
  (setq ewwm-vr-wink--last-wink nil
        ewwm-vr-wink--last-wink-time nil
        ewwm-vr-wink--blink-count 0
        ewwm-vr-wink--blink-rate 0.0
        ewwm-vr-wink--sequence-acc nil
        ewwm-vr-wink--sequence-start-time nil
        ewwm-vr-wink--calibrating nil
        ewwm-vr-wink--calibration-phase nil
        ewwm-vr-wink--calibration-trials nil
        ewwm-vr-wink--wink-history (make-ring 20)))

(provide 'ewwm-vr-wink)
;;; ewwm-vr-wink.el ends here
