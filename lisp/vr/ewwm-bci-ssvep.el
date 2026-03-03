;;; ewwm-bci-ssvep.el --- SSVEP workspace selection  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Steady-State Visually Evoked Potential (SSVEP) integration.
;; Maps flickering visual stimuli at specific frequencies to
;; workspace selection.  Each workspace has a beacon frequency;
;; the classifier detects which frequency the user is attending.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")
(declare-function ewwm-workspace-switch "ewwm-workspace")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-bci-ssvep nil
  "SSVEP workspace selection settings."
  :group 'ewwm-bci)

(defcustom ewwm-bci-ssvep-enabled nil
  "Non-nil to enable SSVEP classification.
Disabled by default due to photosensitivity concerns.
Users should verify they are not photosensitive before
enabling this feature."
  :type 'boolean
  :group 'ewwm-bci-ssvep)

(defcustom ewwm-bci-ssvep-frequencies
  '((1 . 12.0) (2 . 15.0) (3 . 20.0) (4 . 24.0))
  "Alist mapping workspace IDs to stimulus frequencies.
Each entry is (WORKSPACE-ID . FREQUENCY-HZ).
Frequencies should be > 6Hz and separated by >= 2Hz
to ensure reliable classification."
  :type '(alist :key-type integer :value-type number)
  :group 'ewwm-bci-ssvep)

(defcustom ewwm-bci-ssvep-window-seconds 3.0
  "Analysis window length in seconds for SSVEP FFT.
Longer windows improve frequency resolution but
increase latency."
  :type 'number
  :group 'ewwm-bci-ssvep)

(defcustom ewwm-bci-ssvep-min-confidence 0.7
  "Minimum confidence to accept SSVEP classification.
Values below this threshold are ignored."
  :type 'number
  :group 'ewwm-bci-ssvep)

(defcustom ewwm-bci-ssvep-cooldown-ms 2000
  "Cooldown in ms after a successful classification.
Prevents rapid repeated workspace switches."
  :type 'integer
  :group 'ewwm-bci-ssvep)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-bci-ssvep--active nil
  "Non-nil when SSVEP classification is running.")

(defvar ewwm-bci-ssvep--last-result nil
  "Plist of last SSVEP classification result.
Contains :workspace, :frequency, :confidence.")

(defvar ewwm-bci-ssvep--classifications 0
  "Total successful classifications this session.")

(defvar ewwm-bci-ssvep--last-switch-time nil
  "Float-time of last workspace switch via SSVEP.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-bci-ssvep-select-hook nil
  "Hook run on successful SSVEP workspace selection.
Functions receive (WORKSPACE-ID CONFIDENCE).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-bci-ssvep--on-bci-ssvep (msg)
  "Handle :bci-ssvep event MSG.
Switches workspace on confident classification."
  (when (and ewwm-bci-ssvep-enabled ewwm-bci-ssvep--active)
    (let* ((workspace (plist-get msg :workspace))
           (confidence (plist-get msg :confidence))
           (frequency (plist-get msg :frequency))
           (now (float-time))
           (cooled-down
            (or (null ewwm-bci-ssvep--last-switch-time)
                (>= (* 1000.0
                       (- now
                          ewwm-bci-ssvep--last-switch-time))
                    ewwm-bci-ssvep-cooldown-ms))))
      (setq ewwm-bci-ssvep--last-result
            (list :workspace workspace
                  :frequency frequency
                  :confidence confidence))
      (when (and workspace confidence
                 (>= confidence
                     ewwm-bci-ssvep-min-confidence)
                 cooled-down)
        (cl-incf ewwm-bci-ssvep--classifications)
        (setq ewwm-bci-ssvep--last-switch-time now)
        ;; Switch workspace
        (when (fboundp 'ewwm-workspace-switch)
          (ewwm-workspace-switch workspace))
        (message "ewwm-bci-ssvep: ws%d (%.1fHz, %.0f%%)"
                 workspace
                 (or frequency 0.0)
                 (* 100.0 confidence))
        (run-hook-with-args 'ewwm-bci-ssvep-select-hook
                            workspace confidence)))))

;; ── Minor mode ──────────────────────────────────────────────

(define-minor-mode ewwm-bci-ssvep-mode
  "Minor mode for SSVEP workspace selection.
Starts and stops SSVEP stimulus and classification."
  :lighter " SSVEP"
  :group 'ewwm-bci-ssvep
  (cond
   (ewwm-bci-ssvep-mode
    (setq ewwm-bci-ssvep--active t)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       `(:type :bci-ssvep-start
         :frequencies ,ewwm-bci-ssvep-frequencies
         :window ,ewwm-bci-ssvep-window-seconds
         :min-confidence ,ewwm-bci-ssvep-min-confidence)))
    (message "ewwm-bci-ssvep: started"))
   (t
    (setq ewwm-bci-ssvep--active nil)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send '(:type :bci-ssvep-stop)))
    (message "ewwm-bci-ssvep: stopped"))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-bci-ssvep-status ()
  "Display SSVEP status in the minibuffer."
  (interactive)
  (let ((last-ws (plist-get ewwm-bci-ssvep--last-result
                            :workspace))
        (last-conf (plist-get ewwm-bci-ssvep--last-result
                              :confidence)))
    (message
     "ewwm-bci-ssvep: active=%s cls=%d last=ws%s(%.0f%%)"
     (if ewwm-bci-ssvep--active "yes" "no")
     ewwm-bci-ssvep--classifications
     (or last-ws "-")
     (* 100.0 (or last-conf 0.0)))))

(defun ewwm-bci-ssvep-configure ()
  "Send SSVEP configuration to the compositor."
  (interactive)
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-bci: compositor not connected")
    (ewwm-ipc-send
     `(:type :bci-ssvep-configure
       :frequencies ,ewwm-bci-ssvep-frequencies
       :window ,ewwm-bci-ssvep-window-seconds
       :min-confidence ,ewwm-bci-ssvep-min-confidence
       :cooldown-ms ,ewwm-bci-ssvep-cooldown-ms))
    (message "ewwm-bci-ssvep: configuration sent")))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-bci-ssvep-mode-line-string ()
  "Return mode-line string for SSVEP state."
  (when ewwm-bci-ssvep--active
    (let ((ws (plist-get ewwm-bci-ssvep--last-result
                         :workspace)))
      (if ws
          (format " [SSVEP:ws%d]" ws)
        " [SSVEP:--]"))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-bci-ssvep--register-events ()
  "Register SSVEP event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:bci-ssvep . ewwm-bci-ssvep--on-bci-ssvep))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-bci-ssvep-init ()
  "Initialize SSVEP integration."
  (ewwm-bci-ssvep--register-events))

(defun ewwm-bci-ssvep-teardown ()
  "Clean up SSVEP state."
  (when ewwm-bci-ssvep--active
    (ewwm-bci-ssvep-mode -1))
  (setq ewwm-bci-ssvep--active nil
        ewwm-bci-ssvep--last-result nil
        ewwm-bci-ssvep--classifications 0
        ewwm-bci-ssvep--last-switch-time nil))

(provide 'ewwm-bci-ssvep)
;;; ewwm-bci-ssvep.el ends here
