;;; ewwm-vr-fatigue.el --- Eye fatigue monitoring  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Monitors eye fatigue metrics: blink rate, saccade jitter, PERCLOS.
;; Provides alerts and logging for user safety during extended VR sessions.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-fatigue nil
  "Eye fatigue monitoring settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-fatigue-enable t
  "Master switch for fatigue monitoring."
  :type 'boolean
  :group 'ewwm-vr-fatigue)

(defcustom ewwm-vr-fatigue-alert-threshold 25
  "Blink rate (blinks/min) threshold for significant fatigue alert."
  :type 'integer
  :group 'ewwm-vr-fatigue)

(defcustom ewwm-vr-fatigue-perclos-threshold 0.15
  "PERCLOS threshold for fatigue detection.
PERCLOS is the proportion of time eyes are closed over a period.
Values above this threshold indicate significant fatigue."
  :type 'number
  :group 'ewwm-vr-fatigue)

(defcustom ewwm-vr-fatigue-log-enabled t
  "Non-nil to log fatigue metrics to a CSV file."
  :type 'boolean
  :group 'ewwm-vr-fatigue)

(defcustom ewwm-vr-fatigue-log-file "~/.local/share/exwm-vr/fatigue-log.csv"
  "Path to the fatigue metrics CSV log file."
  :type 'file
  :group 'ewwm-vr-fatigue)

(defcustom ewwm-vr-fatigue-check-interval 60
  "Seconds between fatigue metric checks."
  :type 'integer
  :group 'ewwm-vr-fatigue)

;; ── Internal state ─────────────────────────────────────────────

(defvar ewwm-vr-fatigue--level 'normal
  "Current fatigue level symbol: normal, mild, significant, critical.")

(defvar ewwm-vr-fatigue--blink-rate 0.0
  "Current blink rate in blinks per minute.")

(defvar ewwm-vr-fatigue--saccade-jitter 0.0
  "Current saccade jitter in degrees per second.")

(defvar ewwm-vr-fatigue--perclos 0.0
  "Current PERCLOS value (0.0-1.0).")

(defvar ewwm-vr-fatigue--session-start nil
  "Session start time as float-time, or nil if no session.")

(defvar ewwm-vr-fatigue--last-alert-level nil
  "Last fatigue alert level shown to the user.")

;; ── Hooks ──────────────────────────────────────────────────────

(defvar ewwm-vr-fatigue-alert-hook nil
  "Hook run on fatigue alert.
Functions receive (LEVEL METRICS-PLIST).")

;; ── IPC event handlers ────────────────────────────────────────

(defun ewwm-vr-fatigue--on-fatigue-alert (msg)
  "Handle :fatigue-alert event MSG.
Updates internal state, displays warnings, runs hooks, and logs."
  (when ewwm-vr-fatigue-enable
    (let ((level (plist-get msg :level))
          (blink (plist-get msg :blink-rate))
          (jitter (plist-get msg :saccade-jitter))
          (perclos (plist-get msg :perclos)))
      ;; Update state from alert
      (when blink (setq ewwm-vr-fatigue--blink-rate blink))
      (when jitter (setq ewwm-vr-fatigue--saccade-jitter jitter))
      (when perclos (setq ewwm-vr-fatigue--perclos perclos))
      (let ((lvl (cond
                  ((stringp level) (intern level))
                  ((symbolp level) level)
                  (t 'normal))))
        (setq ewwm-vr-fatigue--level lvl
              ewwm-vr-fatigue--last-alert-level lvl)
        ;; Display appropriate message
        (cond
         ((eq lvl 'mild)
          (message "ewwm-vr-fatigue: Elevated blink rate detected. Consider a break."))
         ((eq lvl 'significant)
          (unless noninteractive
            (display-warning 'ewwm-vr-fatigue
                             (format "Significant fatigue detected (blink=%.0f/min PERCLOS=%.2f). Take a break."
                                     (or ewwm-vr-fatigue--blink-rate 0)
                                     (or ewwm-vr-fatigue--perclos 0))
                             :warning)))
         ((eq lvl 'critical)
          (unless noninteractive
            (display-warning 'ewwm-vr-fatigue
                             (format "CRITICAL fatigue level (blink=%.0f/min PERCLOS=%.2f). Stop and rest immediately!"
                                     (or ewwm-vr-fatigue--blink-rate 0)
                                     (or ewwm-vr-fatigue--perclos 0))
                             :error))))
        ;; Run hook
        (run-hook-with-args 'ewwm-vr-fatigue-alert-hook lvl
                            (list :blink-rate ewwm-vr-fatigue--blink-rate
                                  :saccade-jitter ewwm-vr-fatigue--saccade-jitter
                                  :perclos ewwm-vr-fatigue--perclos
                                  :session-start ewwm-vr-fatigue--session-start))
        ;; Log to CSV
        (when ewwm-vr-fatigue-log-enabled
          (ewwm-vr-fatigue--log-entry lvl))))))

(defun ewwm-vr-fatigue--on-fatigue-metrics (msg)
  "Handle :fatigue-metrics event MSG.
Periodic metrics update from compositor."
  (when ewwm-vr-fatigue-enable
    (let ((blink (plist-get msg :blink-rate))
          (jitter (plist-get msg :saccade-jitter))
          (perclos (plist-get msg :perclos))
          (level (plist-get msg :level)))
      (when blink (setq ewwm-vr-fatigue--blink-rate blink))
      (when jitter (setq ewwm-vr-fatigue--saccade-jitter jitter))
      (when perclos (setq ewwm-vr-fatigue--perclos perclos))
      (when level
        (setq ewwm-vr-fatigue--level
              (cond
               ((stringp level) (intern level))
               ((symbolp level) level)
               (t ewwm-vr-fatigue--level)))))))

;; ── CSV logging ───────────────────────────────────────────────

(defun ewwm-vr-fatigue--log-entry (level)
  "Append a CSV entry for fatigue LEVEL to the log file.
Creates the directory and CSV header if the file does not exist."
  (let ((file (expand-file-name ewwm-vr-fatigue-log-file)))
    ;; Ensure directory exists
    (let ((dir (file-name-directory file)))
      (unless (file-directory-p dir)
        (make-directory dir t)))
    ;; Write header if file is new
    (unless (file-exists-p file)
      (write-region "timestamp,blink_rate,saccade_jitter,perclos,session_duration_min,level\n"
                    nil file nil 'silent))
    ;; Append data row
    (let* ((now (float-time))
           (duration-min (if ewwm-vr-fatigue--session-start
                             (/ (- now ewwm-vr-fatigue--session-start) 60.0)
                           0.0))
           (line (format "%s,%.1f,%.2f,%.4f,%.1f,%s\n"
                         (format-time-string "%Y-%m-%dT%H:%M:%S%z" (current-time))
                         (or ewwm-vr-fatigue--blink-rate 0.0)
                         (or ewwm-vr-fatigue--saccade-jitter 0.0)
                         (or ewwm-vr-fatigue--perclos 0.0)
                         duration-min
                         (symbol-name level))))
      (write-region line nil file t 'silent))))

;; ── Interactive commands ──────────────────────────────────────

(defun ewwm-vr-fatigue-status ()
  "Display current fatigue metrics."
  (interactive)
  (let ((duration-min (if ewwm-vr-fatigue--session-start
                          (/ (- (float-time) ewwm-vr-fatigue--session-start) 60.0)
                        0.0)))
    (message "ewwm-vr-fatigue: level=%s blink=%.0f/min jitter=%.1fdeg/s PERCLOS=%.3f session=%.0fmin"
             ewwm-vr-fatigue--level
             ewwm-vr-fatigue--blink-rate
             ewwm-vr-fatigue--saccade-jitter
             ewwm-vr-fatigue--perclos
             duration-min)))

(defun ewwm-vr-fatigue-reset ()
  "Reset session fatigue metrics."
  (interactive)
  (setq ewwm-vr-fatigue--level 'normal
        ewwm-vr-fatigue--blink-rate 0.0
        ewwm-vr-fatigue--saccade-jitter 0.0
        ewwm-vr-fatigue--perclos 0.0
        ewwm-vr-fatigue--session-start (float-time)
        ewwm-vr-fatigue--last-alert-level nil)
  (message "ewwm-vr-fatigue: session metrics reset"))

;; ── Mode-line ──────────────────────────────────────────────────

(defun ewwm-vr-fatigue-mode-line-string ()
  "Return a mode-line string for fatigue state.
Returns nil when disabled or level is normal."
  (when ewwm-vr-fatigue-enable
    (cond
     ((eq ewwm-vr-fatigue--level 'mild)        " [Fat:MILD]")
     ((eq ewwm-vr-fatigue--level 'significant)  " [Fat:HIGH]")
     ((eq ewwm-vr-fatigue--level 'critical)     " [Fat:CRIT]")
     ((eq ewwm-vr-fatigue--level 'normal)       nil)
     (t nil))))

;; ── Event registration ────────────────────────────────────────

(defun ewwm-vr-fatigue--register-events ()
  "Register fatigue event handlers with IPC event dispatch.
Idempotent: will not duplicate handlers."
  (ewwm-ipc-register-events
   '((:fatigue-alert   . ewwm-vr-fatigue--on-fatigue-alert)
     (:fatigue-metrics  . ewwm-vr-fatigue--on-fatigue-metrics))))

;; ── Minor mode ─────────────────────────────────────────────────

(define-minor-mode ewwm-vr-fatigue-mode
  "Minor mode for fatigue monitoring."
  :lighter " VR-Fat"
  :group 'ewwm-vr-fatigue
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c f s") #'ewwm-vr-fatigue-status)
            (define-key map (kbd "C-c f r") #'ewwm-vr-fatigue-reset)
            map))

;; ── Init / teardown ────────────────────────────────────────────

(defun ewwm-vr-fatigue-init ()
  "Initialize fatigue monitoring."
  (ewwm-vr-fatigue--register-events)
  (setq ewwm-vr-fatigue--session-start (float-time)))

(defun ewwm-vr-fatigue-teardown ()
  "Clean up fatigue monitoring state."
  (setq ewwm-vr-fatigue--level 'normal
        ewwm-vr-fatigue--blink-rate 0.0
        ewwm-vr-fatigue--saccade-jitter 0.0
        ewwm-vr-fatigue--perclos 0.0
        ewwm-vr-fatigue--session-start nil
        ewwm-vr-fatigue--last-alert-level nil))

(provide 'ewwm-vr-fatigue)
;;; ewwm-vr-fatigue.el ends here
