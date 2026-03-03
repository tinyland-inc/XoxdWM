;;; ewwm-vr.el --- VR subsystem for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; OpenXR VR integration for ewwm.  Tracks session state, HMD info,
;; frame timing, and provides interactive commands for VR control.
;; Communicates with the compositor's VR subsystem via IPC.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr nil
  "VR settings for EWWM."
  :group 'ewwm)

(defcustom ewwm-vr-reference-space 'local
  "Active OpenXR reference space.
`local': seated experience, origin at initial head position.
`stage': room-scale, origin at floor center.
`view': head-locked, moves with user."
  :type '(choice (const local)
                 (const stage)
                 (const view))
  :group 'ewwm-vr)

(defcustom ewwm-vr-mode-line t
  "Non-nil to show VR status in the mode-line."
  :type 'boolean
  :group 'ewwm-vr)

(defcustom ewwm-vr-frame-stats-interval 5
  "Seconds between frame stats IPC events from compositor."
  :type 'integer
  :group 'ewwm-vr)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-session-state nil
  "Current VR session state as a keyword.
Possible values: :idle, :ready, :synchronized, :visible, :focused,
:stopping, :loss-pending, :exiting, :disabled, :headless, or nil.")

(defvar ewwm-vr-hmd-name nil
  "Name of the discovered HMD (string), or nil if none.")

(defvar ewwm-vr-hmd-info nil
  "Plist of HMD information from system discovery.
Keys: :system-name, :max-width, :max-height,
:orientation-tracking, :position-tracking.")

(defvar ewwm-vr-headless nil
  "Non-nil if VR is running in headless mode (no physical HMD).")

(defvar ewwm-vr-frame-stats nil
  "Latest frame timing stats as a plist.
Keys: :fps, :total-p50, :total-p99, :missed-pct, :total-frames,
:missed-frames, :wait-p50, :render-p50, :submit-p50.")

(defvar ewwm-vr-enabled nil
  "Non-nil if VR feature is enabled in the compositor.")

;; ── IPC event handlers ───────────────────────────────────────

(defun ewwm-vr--on-session-state (msg)
  "Handle :vr-session-state event MSG from compositor."
  (let ((state (plist-get msg :state))
        (headless (plist-get msg :headless)))
    (setq ewwm-vr-session-state state
          ewwm-vr-headless (eq headless t))
    (run-hooks 'ewwm-vr-session-state-hook)
    (force-mode-line-update t)))

(defun ewwm-vr--on-system-discovered (msg)
  "Handle :vr-system-discovered event MSG from compositor."
  (let ((name (plist-get msg :system-name))
        (res (plist-get msg :max-resolution)))
    (setq ewwm-vr-hmd-name name
          ewwm-vr-hmd-info
          (list :system-name name
                :max-width (plist-get res :w)
                :max-height (plist-get res :h)
                :orientation-tracking (plist-get msg :orientation-tracking)
                :position-tracking (plist-get msg :position-tracking)))
    (message "ewwm-vr: HMD discovered: %s" name)))

(defun ewwm-vr--on-frame-stats (msg)
  "Handle :vr-frame-stats event MSG from compositor."
  (setq ewwm-vr-frame-stats
        (list :fps (plist-get msg :fps)
              :total-p50 (plist-get msg :total-p50)
              :total-p99 (plist-get msg :total-p99)
              :missed-pct (plist-get msg :missed-pct)
              :total-frames (plist-get msg :total-frames)
              :missed-frames (plist-get msg :missed-frames)
              :wait-p50 (plist-get msg :wait-p50)
              :render-p50 (plist-get msg :render-p50)
              :submit-p50 (plist-get msg :submit-p50))))

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-session-state-hook nil
  "Hook run when VR session state changes.
`ewwm-vr-session-state' is set before this hook runs.")

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-mode-line-string ()
  "Return a mode-line string for VR status."
  (when ewwm-vr-mode-line
    (cond
     ((null ewwm-vr-session-state) "")
     ((eq ewwm-vr-session-state :disabled) "")
     ((eq ewwm-vr-session-state :headless) " [VR:HEADLESS]")
     ((eq ewwm-vr-session-state :focused) " [VR:FOCUSED]")
     ((eq ewwm-vr-session-state :visible) " [VR:VISIBLE]")
     ((eq ewwm-vr-session-state :synchronized) " [VR:SYNC]")
     ((eq ewwm-vr-session-state :ready) " [VR:READY]")
     ((eq ewwm-vr-session-state :idle) " [VR:IDLE]")
     ((eq ewwm-vr-session-state :stopping) " [VR:STOP]")
     ((eq ewwm-vr-session-state :loss-pending) " [VR:LOSS]")
     ((eq ewwm-vr-session-state :exiting) " [VR:EXIT]")
     (t (format " [VR:%s]" ewwm-vr-session-state)))))

;; ── Interactive commands ─────────────────────────────────────

(defun ewwm-vr-status ()
  "Display VR subsystem status in the minibuffer.
Queries the compositor for live VR state."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr: IPC not available (ewwm-ipc not loaded)")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :vr-status))))
          (if (eq (plist-get resp :status) :ok)
              (let ((session (plist-get resp :session))
                    (hmd (plist-get resp :hmd))
                    (headless (plist-get resp :headless))
                    (stats (plist-get resp :frame-stats)))
                (setq ewwm-vr-session-state session)
                (setq ewwm-vr-headless (eq headless t))
                (when hmd (setq ewwm-vr-hmd-name hmd))
                (message "ewwm-vr: session=%s hmd=%s headless=%s %s"
                         session
                         (or hmd "none")
                         (if (eq headless t) "yes" "no")
                         (if stats (format "fps=%s" (plist-get stats :fps)) "")))
            (message "ewwm-vr: status query failed: %s"
                     (plist-get resp :reason))))
      (error (message "ewwm-vr: %s" (error-message-string err))))))

(defun ewwm-vr-set-reference-space (space)
  "Set the VR reference space to SPACE.
SPACE is a symbol: `local', `stage', or `view'."
  (interactive
   (list (intern (completing-read "Reference space: "
                                  '("local" "stage" "view")
                                  nil t))))
  (unless (memq space '(local stage view))
    (error "Invalid reference space: %s (use local, stage, or view)" space))
  (setq ewwm-vr-reference-space space)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :vr-set-reference-space :space-type ,(symbol-name space))))
  (message "ewwm-vr: reference space set to %s" space))

(defun ewwm-vr-restart ()
  "Restart the VR subsystem in the compositor."
  (interactive)
  (when (fboundp 'ewwm-ipc-send)
    (ewwm-ipc-send '(:type :vr-restart))
    (setq ewwm-vr-session-state :idle)
    (force-mode-line-update t)
    (message "ewwm-vr: restart requested")))

(defun ewwm-vr-frame-timing ()
  "Query and display VR frame timing in a dedicated buffer."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :vr-get-frame-timing))))
          (if (eq (plist-get resp :status) :ok)
              (let ((timing (plist-get resp :timing))
                    (buf (get-buffer-create "*ewwm-vr-timing*")))
                (with-current-buffer buf
                  (let ((inhibit-read-only t))
                    (erase-buffer)
                    (insert "EWWM VR Frame Timing\n")
                    (insert "====================\n\n")
                    (if timing
                        (progn
                          (insert (format "  Wait   p50: %.1f ms\n"
                                          (or (plist-get timing :wait-p50) 0)))
                          (insert (format "  Render p50: %.1f ms\n"
                                          (or (plist-get timing :render-p50) 0)))
                          (insert (format "  Submit p50: %.1f ms\n"
                                          (or (plist-get timing :submit-p50) 0)))
                          (insert (format "  Total  p50: %.1f ms\n"
                                          (or (plist-get timing :total-p50) 0)))
                          (insert (format "  Total  p99: %.1f ms\n"
                                          (or (plist-get timing :total-p99) 0)))
                          (insert (format "\n  FPS:         %.0f\n"
                                          (or (plist-get timing :fps) 0)))
                          (insert (format "  Missed:      %.1f%%\n"
                                          (or (plist-get timing :missed-pct) 0)))
                          (insert (format "  Frames:      %d\n"
                                          (or (plist-get timing :total-frames) 0)))
                          (insert (format "  Missed:      %d\n"
                                          (or (plist-get timing :missed-frames) 0))))
                      (insert "  No timing data available.\n"))
                    (insert "\n[Press q to close]"))
                  (special-mode))
                (display-buffer buf))
            (message "ewwm-vr: frame timing query failed")))
      (error (message "ewwm-vr: %s" (error-message-string err))))))

;; ── Initialization ───────────────────────────────────────────

(defun ewwm-vr--register-events ()
  "Register VR event handlers with the IPC event dispatch."
  (ewwm-ipc-register-events
   '((:vr-session-state    . ewwm-vr--on-session-state)
     (:vr-system-discovered . ewwm-vr--on-system-discovered)
     (:vr-frame-stats       . ewwm-vr--on-frame-stats))))

(defun ewwm-vr-init ()
  "Initialize the VR subsystem in Emacs.
Registers IPC event handlers and queries initial VR status."
  (ewwm-vr--register-events)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-vr-status)))

(defun ewwm-vr-teardown ()
  "Clean up VR state."
  (setq ewwm-vr-session-state nil
        ewwm-vr-hmd-name nil
        ewwm-vr-hmd-info nil
        ewwm-vr-headless nil
        ewwm-vr-frame-stats nil
        ewwm-vr-enabled nil))

(provide 'ewwm-vr)
;;; ewwm-vr.el ends here
