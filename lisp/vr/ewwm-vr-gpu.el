;;; ewwm-vr-gpu.el --- GPU power management for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Controls GPU performance profiles during VR sessions.
;; Supports auto-boost (switch to high performance on VR start,
;; restore on exit) and manual profile selection.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-gpu nil
  "GPU power management settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-gpu-auto-boost t
  "Non-nil to auto-switch GPU to high performance during VR sessions.
When a VR session starts the compositor switches the GPU power profile
to \"high\" and restores the previous profile on session end."
  :type 'boolean
  :group 'ewwm-vr-gpu)

(defcustom ewwm-vr-gpu-default-profile "auto"
  "Default GPU power profile.
One of: \"auto\", \"low\", \"normal\", \"high\"."
  :type '(choice (const :tag "Auto (system managed)" "auto")
                 (const :tag "Low power" "low")
                 (const :tag "Normal" "normal")
                 (const :tag "High performance" "high"))
  :group 'ewwm-vr-gpu)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-gpu--current-profile "auto"
  "Current GPU power profile as reported by the compositor.")

(defvar ewwm-vr-gpu--card-path nil
  "DRM card sysfs path, or nil if not detected.")

(defvar ewwm-vr-gpu--controllable nil
  "Non-nil when the GPU power profile is writable.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-gpu-changed-hook nil
  "Hook run when GPU power state changes.
`ewwm-vr-gpu--current-profile' is set before this hook runs.")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-gpu--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-gpu--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-gpu: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-gpu--on-state-changed (msg)
  "Handle :gpu-power-state-changed event MSG."
  (let ((profile (plist-get msg :profile))
        (card (plist-get msg :card))
        (controllable (plist-get msg :controllable)))
    (when profile
      (setq ewwm-vr-gpu--current-profile profile))
    (when card
      (setq ewwm-vr-gpu--card-path card))
    (setq ewwm-vr-gpu--controllable (eq controllable t))
    (run-hooks 'ewwm-vr-gpu-changed-hook)
    (force-mode-line-update t)))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-gpu-set-profile (profile)
  "Set GPU power PROFILE.
PROFILE is a string: \"auto\", \"low\", \"normal\", or \"high\"."
  (interactive
   (list (completing-read "GPU power profile: "
                          '("auto" "low" "normal" "high")
                          nil t)))
  (unless (member profile '("auto" "low" "normal" "high"))
    (error "Invalid GPU power profile: %s" profile))
  (setq ewwm-vr-gpu--current-profile profile)
  (ewwm-vr-gpu--send
   `(:type :gpu-power-set-profile :profile ,profile))
  (run-hooks 'ewwm-vr-gpu-changed-hook)
  (message "ewwm-vr-gpu: profile set to %s" profile))

(defun ewwm-vr-gpu-detect ()
  "Trigger GPU detection on the compositor."
  (interactive)
  (ewwm-vr-gpu--send '(:type :gpu-power-detect))
  (message "ewwm-vr-gpu: detection requested"))

(defun ewwm-vr-gpu-status ()
  "Display current GPU power state."
  (interactive)
  (let ((resp (ewwm-vr-gpu--send-sync '(:type :gpu-power-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((gpu (plist-get resp :gpu-power)))
          (message "ewwm-vr-gpu: profile=%s card=%s controllable=%s boost=%s"
                   (or (plist-get gpu :profile) ewwm-vr-gpu--current-profile)
                   (or (plist-get gpu :card) "none")
                   (if (plist-get gpu :controllable) "yes" "no")
                   (if (plist-get gpu :auto-vr-boost) "yes" "no")))
      (message "ewwm-vr-gpu: profile=%s card=%s controllable=%s (offline)"
               ewwm-vr-gpu--current-profile
               (or ewwm-vr-gpu--card-path "none")
               (if ewwm-vr-gpu--controllable "yes" "no")))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-gpu--register-events ()
  "Register GPU power event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:gpu-power-state-changed . ewwm-vr-gpu--on-state-changed))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-gpu-init ()
  "Initialize GPU power management subsystem.
Registers IPC event handlers."
  (ewwm-vr-gpu--register-events))

(defun ewwm-vr-gpu-teardown ()
  "Clean up GPU power state."
  (setq ewwm-vr-gpu--current-profile "auto"
        ewwm-vr-gpu--card-path nil
        ewwm-vr-gpu--controllable nil))

(provide 'ewwm-vr-gpu)
;;; ewwm-vr-gpu.el ends here
