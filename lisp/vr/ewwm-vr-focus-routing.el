;;; ewwm-vr-focus-routing.el --- Gaze-to-focus routing for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Connects gaze tracking to window focus.  Routes gaze dwell events
;; to keyboard/pointer focus changes based on configurable modes.
;; Bridges ewwm-vr-eye gaze data with compositor focus management.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")
(declare-function ewwm--get-buffer "ewwm-core")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-focus-routing nil
  "Gaze-to-focus routing settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-focus-routing-mode "gaze-primary"
  "Focus routing mode controlling how gaze affects window focus.
\"disabled\": gaze has no effect on focus.
\"gaze-only\": gaze dwell is the sole focus method.
\"gaze-primary\": gaze dwell switches focus, keyboard/mouse also work.
\"gaze-assist\": gaze highlights target, requires manual confirmation."
  :type '(choice (const :tag "Disabled" "disabled")
                 (const :tag "Gaze only" "gaze-only")
                 (const :tag "Gaze primary" "gaze-primary")
                 (const :tag "Gaze assist" "gaze-assist"))
  :group 'ewwm-vr-focus-routing)

(defcustom ewwm-vr-focus-routing-dwell-ms 400
  "Dwell time in milliseconds before gaze triggers focus change.
Gaze must remain on a surface for this duration before focus switches."
  :type 'integer
  :group 'ewwm-vr-focus-routing)

(defcustom ewwm-vr-focus-routing-confirm-visual t
  "Non-nil to show visual feedback during dwell countdown.
Displays progress in mode-line or minibuffer."
  :type 'boolean
  :group 'ewwm-vr-focus-routing)

(defcustom ewwm-vr-focus-routing-ignore-transients t
  "Non-nil to skip transient surfaces during gaze focus routing.
Transient surfaces (tooltips, popups) will not receive gaze focus."
  :type 'boolean
  :group 'ewwm-vr-focus-routing)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-focus-routing--current-surface nil
  "Surface ID currently receiving gaze focus, or nil.")

(defvar ewwm-vr-focus-routing--dwell-timer nil
  "Timer for dwell progress feedback, or nil.")

(defvar ewwm-vr-focus-routing--dwell-progress 0.0
  "Current dwell progress as fraction 0.0 to 1.0.")

(defvar ewwm-vr-focus-routing--pending-surface nil
  "Surface ID pending dwell confirmation, or nil.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-focus-routing-changed-hook nil
  "Hook run when gaze focus routing changes the focused surface.
Functions receive (SURFACE-ID PREV-SURFACE-ID).")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-focus-routing--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-focus-routing--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-focus-routing: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-focus-routing--handle-gaze-focus (msg)
  "Handle :gaze-focus event MSG from compositor.
When gaze focus changes to a new surface, route keyboard/pointer
focus according to the current routing mode."
  (let ((surface-id (plist-get msg :surface-id))
        (transient (plist-get msg :transient))
        (prev ewwm-vr-focus-routing--current-surface))
    ;; Skip transient surfaces if configured
    (when (and ewwm-vr-focus-routing-ignore-transients
               (eq transient t))
      (cl-return-from ewwm-vr-focus-routing--handle-gaze-focus nil))
    ;; Skip if same surface
    (when (equal surface-id prev)
      (cl-return-from ewwm-vr-focus-routing--handle-gaze-focus nil))
    (setq ewwm-vr-focus-routing--current-surface surface-id)
    (cond
     ;; Disabled: no action
     ((string= ewwm-vr-focus-routing-mode "disabled")
      nil)
     ;; Gaze-only or gaze-primary: route focus immediately
     ((or (string= ewwm-vr-focus-routing-mode "gaze-only")
          (string= ewwm-vr-focus-routing-mode "gaze-primary"))
      (when surface-id
        (ewwm-vr-focus-routing--route-focus surface-id prev)))
     ;; Gaze-assist: highlight but don't focus
     ((string= ewwm-vr-focus-routing-mode "gaze-assist")
      (setq ewwm-vr-focus-routing--pending-surface surface-id)
      (when ewwm-vr-focus-routing-confirm-visual
        (message "ewwm-vr-focus-routing: gaze on surface %s (confirm to focus)"
                 surface-id))))))

(defun ewwm-vr-focus-routing--route-focus (surface-id prev-surface-id)
  "Route keyboard/pointer focus to SURFACE-ID.
PREV-SURFACE-ID is the previously focused surface."
  (let ((buf (ewwm--get-buffer surface-id)))
    (when (and buf (buffer-live-p buf))
      ;; Send focus command to compositor
      (ewwm-vr-focus-routing--send
       `(:type :focus-surface :surface-id ,surface-id))
      ;; Switch buffer in Emacs
      (unless noninteractive
        (switch-to-buffer buf))
      ;; Run hook
      (run-hook-with-args 'ewwm-vr-focus-routing-changed-hook
                          surface-id prev-surface-id))))

(defun ewwm-vr-focus-routing--handle-dwell-progress (msg)
  "Handle :focus-routing-dwell-progress event MSG from compositor.
Shows mode-line or minibuffer progress feedback."
  (let ((elapsed (plist-get msg :elapsed-ms))
        (threshold (plist-get msg :threshold-ms))
        (surface-id (plist-get msg :surface-id)))
    (setq ewwm-vr-focus-routing--pending-surface surface-id)
    (setq ewwm-vr-focus-routing--dwell-progress
          (if (and elapsed threshold (> threshold 0))
              (min 1.0 (/ (float elapsed) threshold))
            0.0))
    (when ewwm-vr-focus-routing-confirm-visual
      (let* ((pct (round (* ewwm-vr-focus-routing--dwell-progress 100)))
             (filled (round (* ewwm-vr-focus-routing--dwell-progress 10)))
             (empty (- 10 filled))
             (bar (concat (make-string filled ?#)
                          (make-string empty ?-))))
        (message "ewwm-vr-focus-routing: [%s] %d%% surface %s"
                 bar pct surface-id)))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-focus-routing-set-mode (mode)
  "Change focus routing MODE.
MODE is a string: \"disabled\", \"gaze-only\", \"gaze-primary\",
or \"gaze-assist\"."
  (interactive
   (list (completing-read "Focus routing mode: "
                          '("disabled" "gaze-only" "gaze-primary" "gaze-assist")
                          nil t)))
  (unless (member mode '("disabled" "gaze-only" "gaze-primary" "gaze-assist"))
    (error "Invalid focus routing mode: %s" mode))
  (setq ewwm-vr-focus-routing-mode mode)
  (ewwm-vr-focus-routing--send
   `(:type :focus-routing-set-mode :mode ,mode))
  (message "ewwm-vr-focus-routing: mode set to %s" mode))

(defun ewwm-vr-focus-routing-set-dwell (ms)
  "Set dwell threshold to MS milliseconds."
  (interactive "nDwell threshold (ms): ")
  (let ((clamped (max 50 (min 5000 ms))))
    (setq ewwm-vr-focus-routing-dwell-ms clamped)
    (ewwm-vr-focus-routing--send
     `(:type :focus-routing-set-dwell :threshold-ms ,clamped))
    (message "ewwm-vr-focus-routing: dwell threshold set to %dms" clamped)))

(defun ewwm-vr-focus-routing-toggle ()
  "Toggle focus routing between disabled and gaze-primary."
  (interactive)
  (let ((new-mode (if (string= ewwm-vr-focus-routing-mode "disabled")
                      "gaze-primary"
                    "disabled")))
    (ewwm-vr-focus-routing-set-mode new-mode)))

(defun ewwm-vr-focus-routing-status ()
  "Show current focus routing state."
  (interactive)
  (let ((resp (ewwm-vr-focus-routing--send-sync '(:type :focus-routing-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((routing (plist-get resp :routing)))
          (message "ewwm-vr-focus-routing: mode=%s dwell=%dms surface=%s visual=%s transients=%s"
                   (or (plist-get routing :mode) ewwm-vr-focus-routing-mode)
                   (or (plist-get routing :dwell-ms) ewwm-vr-focus-routing-dwell-ms)
                   (or ewwm-vr-focus-routing--current-surface "none")
                   (if ewwm-vr-focus-routing-confirm-visual "on" "off")
                   (if ewwm-vr-focus-routing-ignore-transients "skip" "include")))
      (message "ewwm-vr-focus-routing: mode=%s dwell=%dms surface=%s (offline)"
               ewwm-vr-focus-routing-mode
               ewwm-vr-focus-routing-dwell-ms
               (or ewwm-vr-focus-routing--current-surface "none")))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-focus-routing--register-events ()
  "Register focus routing event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:gaze-focus                    . ewwm-vr-focus-routing--handle-gaze-focus)
     (:focus-routing-dwell-progress  . ewwm-vr-focus-routing--handle-dwell-progress))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-focus-routing-init ()
  "Initialize gaze-to-focus routing.
Registers IPC event handlers and configures the compositor."
  (ewwm-vr-focus-routing--register-events)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-vr-focus-routing--send
     `(:type :focus-routing-configure
       :mode ,ewwm-vr-focus-routing-mode
       :dwell-ms ,ewwm-vr-focus-routing-dwell-ms
       :confirm-visual ,(if ewwm-vr-focus-routing-confirm-visual t :false)
       :ignore-transients ,(if ewwm-vr-focus-routing-ignore-transients t :false)))))

(defun ewwm-vr-focus-routing-teardown ()
  "Clean up focus routing state."
  (when ewwm-vr-focus-routing--dwell-timer
    (cancel-timer ewwm-vr-focus-routing--dwell-timer)
    (setq ewwm-vr-focus-routing--dwell-timer nil))
  (setq ewwm-vr-focus-routing--current-surface nil
        ewwm-vr-focus-routing--dwell-progress 0.0
        ewwm-vr-focus-routing--pending-surface nil))

(provide 'ewwm-vr-focus-routing)
;;; ewwm-vr-focus-routing.el ends here
