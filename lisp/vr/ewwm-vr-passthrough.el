;;; ewwm-vr-passthrough.el --- VR passthrough/AR mode for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Controls VR passthrough (camera feed) and AR blend modes.
;; Supports opaque, additive, and alpha-blend compositing of
;; the real-world background behind virtual surfaces.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-passthrough nil
  "VR passthrough and AR mode settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-passthrough-blend-mode "opaque"
  "Background blend mode for VR environment.
\"opaque\": fully virtual environment, no camera feed.
\"additive\": camera feed added to virtual content (bright AR).
\"alpha-blend\": camera feed blended with virtual content by opacity."
  :type '(choice (const :tag "Opaque (full VR)" "opaque")
                 (const :tag "Additive" "additive")
                 (const :tag "Alpha blend" "alpha-blend"))
  :group 'ewwm-vr-passthrough)

(defcustom ewwm-vr-passthrough-opacity 1.0
  "Background opacity for alpha-blend mode (0.0-1.0).
0.0 = fully transparent background (full passthrough).
1.0 = fully opaque background (no passthrough).
Only effective when blend mode is \"alpha-blend\"."
  :type 'number
  :group 'ewwm-vr-passthrough)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-passthrough--enabled nil
  "Non-nil when passthrough is currently enabled.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-passthrough-changed-hook nil
  "Hook run when passthrough state changes.
`ewwm-vr-passthrough--enabled' is set before this hook runs.")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-passthrough--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-passthrough--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-passthrough: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-passthrough--on-state-changed (msg)
  "Handle :passthrough-state-changed event MSG."
  (let ((enabled (plist-get msg :enabled))
        (blend (plist-get msg :blend-mode))
        (opacity (plist-get msg :opacity)))
    (setq ewwm-vr-passthrough--enabled (eq enabled t))
    (when blend
      (setq ewwm-vr-passthrough-blend-mode blend))
    (when opacity
      (setq ewwm-vr-passthrough-opacity opacity))
    (run-hooks 'ewwm-vr-passthrough-changed-hook)
    (force-mode-line-update t)))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-passthrough-enable ()
  "Enable VR passthrough (camera feed background)."
  (interactive)
  (setq ewwm-vr-passthrough--enabled t)
  (ewwm-vr-passthrough--send
   `(:type :passthrough-enable
     :blend-mode ,ewwm-vr-passthrough-blend-mode
     :opacity ,ewwm-vr-passthrough-opacity))
  (run-hooks 'ewwm-vr-passthrough-changed-hook)
  (message "ewwm-vr-passthrough: enabled (blend=%s opacity=%.1f)"
           ewwm-vr-passthrough-blend-mode
           ewwm-vr-passthrough-opacity))

(defun ewwm-vr-passthrough-disable ()
  "Disable VR passthrough (return to opaque VR)."
  (interactive)
  (setq ewwm-vr-passthrough--enabled nil)
  (ewwm-vr-passthrough--send '(:type :passthrough-disable))
  (run-hooks 'ewwm-vr-passthrough-changed-hook)
  (message "ewwm-vr-passthrough: disabled"))

(defun ewwm-vr-passthrough-toggle ()
  "Toggle VR passthrough on or off."
  (interactive)
  (if ewwm-vr-passthrough--enabled
      (ewwm-vr-passthrough-disable)
    (ewwm-vr-passthrough-enable)))

(defun ewwm-vr-passthrough-set-blend-mode (mode)
  "Set passthrough blend MODE.
MODE is a string: \"opaque\", \"additive\", or \"alpha-blend\"."
  (interactive
   (list (completing-read "Blend mode: "
                          '("opaque" "additive" "alpha-blend")
                          nil t)))
  (unless (member mode '("opaque" "additive" "alpha-blend"))
    (error "Invalid blend mode: %s" mode))
  (setq ewwm-vr-passthrough-blend-mode mode)
  (ewwm-vr-passthrough--send
   `(:type :passthrough-set-blend-mode :blend-mode ,mode))
  (message "ewwm-vr-passthrough: blend mode set to %s" mode))

(defun ewwm-vr-passthrough-set-opacity (opacity)
  "Set background OPACITY for alpha-blend mode (0.0-1.0)."
  (interactive "nOpacity (0.0=transparent, 1.0=opaque): ")
  (let ((clamped (max 0.0 (min 1.0 opacity))))
    (setq ewwm-vr-passthrough-opacity clamped)
    (ewwm-vr-passthrough--send
     `(:type :passthrough-set-opacity :opacity ,clamped))
    (message "ewwm-vr-passthrough: opacity set to %.2f" clamped)))

(defun ewwm-vr-passthrough-status ()
  "Display current passthrough state."
  (interactive)
  (let ((resp (ewwm-vr-passthrough--send-sync '(:type :passthrough-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((pt (plist-get resp :passthrough)))
          (message "ewwm-vr-passthrough: enabled=%s blend=%s opacity=%.2f"
                   (if (plist-get pt :enabled) "yes" "no")
                   (or (plist-get pt :blend-mode) ewwm-vr-passthrough-blend-mode)
                   (or (plist-get pt :opacity) ewwm-vr-passthrough-opacity)))
      (message "ewwm-vr-passthrough: enabled=%s blend=%s opacity=%.2f (offline)"
               (if ewwm-vr-passthrough--enabled "yes" "no")
               ewwm-vr-passthrough-blend-mode
               ewwm-vr-passthrough-opacity))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-passthrough--register-events ()
  "Register passthrough event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:passthrough-state-changed . ewwm-vr-passthrough--on-state-changed))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-passthrough-init ()
  "Initialize VR passthrough subsystem.
Registers IPC event handlers."
  (ewwm-vr-passthrough--register-events))

(defun ewwm-vr-passthrough-teardown ()
  "Clean up passthrough state."
  (setq ewwm-vr-passthrough--enabled nil))

(provide 'ewwm-vr-passthrough)
;;; ewwm-vr-passthrough.el ends here
