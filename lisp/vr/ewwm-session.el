;;; ewwm-session.el --- Session management for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Session management commands for ewwm: lock, logout, shutdown, reboot,
;; suspend, and idle daemon management.  Uses systemctl for power actions
;; and configurable lock/idle commands.

;;; Code:

(require 'cl-lib)

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-session nil
  "EWWM session management."
  :group 'ewwm)

(defcustom ewwm-session-lock-command "swaylock"
  "Command to lock the screen."
  :type 'string
  :group 'ewwm-session)

(defcustom ewwm-session-lock-args nil
  "Arguments passed to the lock command."
  :type '(repeat string)
  :group 'ewwm-session)

(defcustom ewwm-session-idle-command "swayidle"
  "Command for the idle management daemon."
  :type 'string
  :group 'ewwm-session)

(defcustom ewwm-session-idle-args
  '("-w"
    "timeout" "300" "swaylock"
    "timeout" "600" "swaymsg output * dpms off"
    "resume" "swaymsg output * dpms on"
    "before-sleep" "swaylock")
  "Arguments passed to the idle command.
Default: lock after 5 min, DPMS off after 10 min, lock before sleep."
  :type '(repeat string)
  :group 'ewwm-session)

(defcustom ewwm-session-shutdown-command "systemctl poweroff"
  "Command to shut down the system."
  :type 'string
  :group 'ewwm-session)

(defcustom ewwm-session-reboot-command "systemctl reboot"
  "Command to reboot the system."
  :type 'string
  :group 'ewwm-session)

(defcustom ewwm-session-suspend-command "systemctl suspend"
  "Command to suspend the system."
  :type 'string
  :group 'ewwm-session)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-session-idle-process nil
  "Process object for the idle daemon.")

(defvar ewwm-session-lock-process nil
  "Process object for the lock screen.")

;; ── Lock ─────────────────────────────────────────────────────

(defun ewwm-session-lock ()
  "Lock the session by starting the lock command."
  (interactive)
  (if (and ewwm-session-lock-process
           (process-live-p ewwm-session-lock-process))
      (message "ewwm-session: screen already locked")
    (let ((proc (if (fboundp 'ewwm-launch)
                    (ewwm-launch
                     (mapconcat #'identity
                                (cons ewwm-session-lock-command
                                      ewwm-session-lock-args)
                                " "))
                  (apply #'start-process
                         "ewwm-lock" " *ewwm-lock*"
                         ewwm-session-lock-command
                         ewwm-session-lock-args))))
      (setq ewwm-session-lock-process proc)
      (set-process-sentinel proc #'ewwm-session--lock-sentinel)
      (message "ewwm-session: locked"))))

(defun ewwm-session--lock-sentinel (proc _event)
  "Clean up when lock PROC exits."
  (when (memq (process-status proc) '(exit signal))
    (setq ewwm-session-lock-process nil)))

;; ── Logout ───────────────────────────────────────────────────

(defun ewwm-session-logout ()
  "Gracefully end the ewwm session.
Sends exit command to the compositor via IPC, or calls `ewwm-exit'."
  (interactive)
  (when (yes-or-no-p "Log out of EWWM session? ")
    (cond
     ;; Try IPC shutdown first
     ((and (fboundp 'ewwm-ipc-connected-p)
           (funcall 'ewwm-ipc-connected-p)
           (fboundp 'ewwm-ipc-send))
      (funcall 'ewwm-ipc-send '(:type :compositor-exit))
      (message "ewwm-session: sent exit to compositor"))
     ;; Fall back to ewwm-exit
     ((fboundp 'ewwm-exit)
      (funcall 'ewwm-exit))
     (t
      (message "ewwm-session: no compositor connection, nothing to do")))))

;; ── Power management ─────────────────────────────────────────

(defun ewwm-session-shutdown ()
  "Shut down the system.  Prompts for confirmation."
  (interactive)
  (when (yes-or-no-p "Shut down the system? ")
    (start-process-shell-command
     "ewwm-shutdown" nil ewwm-session-shutdown-command)))

(defun ewwm-session-reboot ()
  "Reboot the system.  Prompts for confirmation."
  (interactive)
  (when (yes-or-no-p "Reboot the system? ")
    (start-process-shell-command
     "ewwm-reboot" nil ewwm-session-reboot-command)))

(defun ewwm-session-suspend ()
  "Lock the screen and then suspend the system."
  (interactive)
  (ewwm-session-lock)
  ;; Small delay so the lock screen has time to activate
  (run-with-timer 1 nil
                  (lambda ()
                    (start-process-shell-command
                     "ewwm-suspend" nil ewwm-session-suspend-command)))
  (message "ewwm-session: suspending"))

;; ── Idle daemon ──────────────────────────────────────────────

(defun ewwm-session-start-idle ()
  "Start the idle management daemon."
  (interactive)
  (if (and ewwm-session-idle-process
           (process-live-p ewwm-session-idle-process))
      (message "ewwm-session: idle daemon already running")
    (let ((proc (if (fboundp 'ewwm-launch)
                    (ewwm-launch
                     (mapconcat #'identity
                                (cons ewwm-session-idle-command
                                      ewwm-session-idle-args)
                                " "))
                  (apply #'start-process
                         "ewwm-idle" " *ewwm-idle*"
                         ewwm-session-idle-command
                         ewwm-session-idle-args))))
      (setq ewwm-session-idle-process proc)
      (set-process-sentinel proc #'ewwm-session--idle-sentinel)
      (message "ewwm-session: idle daemon started"))))

(defun ewwm-session-stop-idle ()
  "Stop the idle management daemon."
  (interactive)
  (when (and ewwm-session-idle-process
             (process-live-p ewwm-session-idle-process))
    (kill-process ewwm-session-idle-process))
  (setq ewwm-session-idle-process nil)
  (message "ewwm-session: idle daemon stopped"))

(defun ewwm-session--idle-sentinel (proc _event)
  "Clean up when idle daemon PROC exits."
  (when (memq (process-status proc) '(exit signal))
    (setq ewwm-session-idle-process nil)
    (message "ewwm-session: idle daemon exited")))

;; ── Status ───────────────────────────────────────────────────

(defun ewwm-session-status ()
  "Display session status in the minibuffer."
  (interactive)
  (message "ewwm-session: idle=%s lock=%s"
           (if (and ewwm-session-idle-process
                    (process-live-p ewwm-session-idle-process))
               "running" "stopped")
           (if (and ewwm-session-lock-process
                    (process-live-p ewwm-session-lock-process))
               "active" "inactive")))

(provide 'ewwm-session)
;;; ewwm-session.el ends here
