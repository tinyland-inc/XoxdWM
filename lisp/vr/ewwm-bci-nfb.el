;;; ewwm-bci-nfb.el --- Neurofeedback training mode  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Neurofeedback (NFB) training integration for ewwm.
;; Provides real-time EEG band power display in a dedicated
;; buffer, multiple training protocols (alpha, beta, MI),
;; session logging, and data export.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-bci-nfb nil
  "Neurofeedback training settings."
  :group 'ewwm-bci)

(defcustom ewwm-bci-nfb-session-dir
  "~/.local/share/exwm-vr/neurofeedback/"
  "Directory for neurofeedback session data files."
  :type 'directory
  :group 'ewwm-bci-nfb)

(defcustom ewwm-bci-nfb-log-interval 1.0
  "Interval in seconds between data log entries."
  :type 'number
  :group 'ewwm-bci-nfb)

(defcustom ewwm-bci-nfb-display-channels 8
  "Number of EEG channels to display in the NFB buffer."
  :type 'integer
  :group 'ewwm-bci-nfb)

(defcustom ewwm-bci-nfb-bar-width 40
  "Width in characters for band power bar display."
  :type 'integer
  :group 'ewwm-bci-nfb)

(defcustom ewwm-bci-nfb-auto-export t
  "Non-nil to auto-export session data on stop."
  :type 'boolean
  :group 'ewwm-bci-nfb)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-bci-nfb--active nil
  "Non-nil when a neurofeedback session is running.")

(defvar ewwm-bci-nfb--session-id nil
  "Current session identifier string, or nil.")

(defvar ewwm-bci-nfb--session-start nil
  "Session start time as float-time, or nil.")

(defvar ewwm-bci-nfb--data-buffer nil
  "List of session data frames (plists).
Each frame contains band powers and timestamp.")

(defvar ewwm-bci-nfb--timer nil
  "Display update timer, or nil.")

(defvar ewwm-bci-nfb--protocol nil
  "Current training protocol symbol.
One of: alpha-trainer, beta-trainer, mi-trainer.")

(defvar ewwm-bci-nfb--latest-frame nil
  "Most recent NFB data frame plist.")

(defvar ewwm-bci-nfb--frame-count 0
  "Number of frames received this session.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-bci-nfb-start-hook nil
  "Hook run when a neurofeedback session starts.
Functions receive (PROTOCOL SESSION-ID).")

(defvar ewwm-bci-nfb-stop-hook nil
  "Hook run when a neurofeedback session stops.
Functions receive (SESSION-ID FRAME-COUNT).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-bci-nfb--on-bci-nfb-frame (msg)
  "Handle :bci-nfb-frame event MSG.
Updates the display buffer with band power data."
  (when ewwm-bci-nfb--active
    (let ((bands (plist-get msg :bands))
          (channels (plist-get msg :channels))
          (score (plist-get msg :score)))
      (setq ewwm-bci-nfb--latest-frame msg)
      (cl-incf ewwm-bci-nfb--frame-count)
      ;; Record data
      (push (list :time (float-time)
                  :bands bands
                  :channels channels
                  :score score)
            ewwm-bci-nfb--data-buffer)
      ;; Update display buffer
      (ewwm-bci-nfb--update-display bands channels score))))

;; ── Display buffer ──────────────────────────────────────────

(defun ewwm-bci-nfb--update-display (bands channels score)
  "Update the *ewwm-bci-neurofeedback* buffer.
BANDS is a plist of band powers, CHANNELS is per-channel
data, SCORE is the training score."
  (let ((buf (get-buffer "*ewwm-bci-neurofeedback*")))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (pt (point)))
          (erase-buffer)
          (insert (format "EWWM Neurofeedback — %s\n"
                          (or ewwm-bci-nfb--protocol
                              "unknown")))
          (insert (make-string 50 ?=) "\n\n")
          ;; Session info
          (let ((dur (if ewwm-bci-nfb--session-start
                         (/ (- (float-time)
                               ewwm-bci-nfb--session-start)
                            60.0)
                       0.0)))
            (insert (format "Session: %s  Duration: %.1fm  "
                            (or ewwm-bci-nfb--session-id "-")
                            dur))
            (insert (format "Frames: %d\n\n"
                            ewwm-bci-nfb--frame-count)))
          ;; Training score
          (when score
            (insert (format "Score: %.1f%%\n"
                            (* 100.0 score)))
            (insert (ewwm-bci-nfb--bar score) "\n\n"))
          ;; Band powers
          (when bands
            (insert "Band Powers:\n")
            (dolist (band '(:delta :theta :alpha :beta :gamma))
              (let ((val (plist-get bands band)))
                (when val
                  (insert (format "  %-8s %6.1f uV^2  %s\n"
                                  (substring
                                   (symbol-name band) 1)
                                  val
                                  (ewwm-bci-nfb--bar
                                   (min 1.0
                                        (/ val 100.0))))))))
            (insert "\n"))
          ;; Per-channel data
          (when channels
            (insert "Channels:\n")
            (let ((i 0))
              (while (and (< i ewwm-bci-nfb-display-channels)
                          (< i (length channels)))
                (let ((ch (nth i channels)))
                  (insert (format "  ch%d: %.1f uV\n"
                                  (1+ i) (or ch 0.0))))
                (cl-incf i)))
            (insert "\n"))
          ;; Restore point if possible
          (goto-char (min pt (point-max))))))))

(defun ewwm-bci-nfb--bar (fraction)
  "Return an ASCII bar for FRACTION in [0.0, 1.0]."
  (let* ((filled (round (* fraction ewwm-bci-nfb-bar-width)))
         (empty (- ewwm-bci-nfb-bar-width filled)))
    (concat "[" (make-string filled ?#)
            (make-string empty ?-) "]")))

(defun ewwm-bci-nfb--create-buffer ()
  "Create or reset the neurofeedback display buffer."
  (let ((buf (get-buffer-create "*ewwm-bci-neurofeedback*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "EWWM Neurofeedback\n")
        (insert "Waiting for data...\n"))
      (special-mode))
    (unless noninteractive
      (display-buffer buf))
    buf))

;; ── Training protocols ──────────────────────────────────────

(defun ewwm-bci-nfb--protocol-params (protocol)
  "Return IPC parameters plist for PROTOCOL symbol."
  (cond
   ((eq protocol 'alpha-trainer)
    '(:target-band :alpha :threshold 0.5
      :reward-band :alpha :inhibit-band :theta))
   ((eq protocol 'beta-trainer)
    '(:target-band :beta :threshold 0.4
      :reward-band :beta :inhibit-band :theta))
   ((eq protocol 'mi-trainer)
    '(:target-band :mu :threshold 0.3
      :reward-band :mu :inhibit-band :beta))
   (t
    '(:target-band :alpha :threshold 0.5
      :reward-band :alpha :inhibit-band :theta))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-bci-nfb-start (protocol)
  "Start a neurofeedback session with PROTOCOL.
PROTOCOL is a symbol: alpha-trainer, beta-trainer,
or mi-trainer.  Interactively, prompts for selection."
  (interactive
   (list (intern
          (completing-read
           "NFB protocol: "
           '("alpha-trainer" "beta-trainer" "mi-trainer")
           nil t))))
  (when ewwm-bci-nfb--active
    (ewwm-bci-nfb-stop))
  (let ((session-id (format-time-string "%Y%m%d-%H%M%S")))
    (setq ewwm-bci-nfb--active t
          ewwm-bci-nfb--protocol protocol
          ewwm-bci-nfb--session-id session-id
          ewwm-bci-nfb--session-start (float-time)
          ewwm-bci-nfb--data-buffer nil
          ewwm-bci-nfb--frame-count 0
          ewwm-bci-nfb--latest-frame nil)
    (ewwm-bci-nfb--create-buffer)
    ;; Send to compositor
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (let ((params (ewwm-bci-nfb--protocol-params protocol)))
        (ewwm-ipc-send
         (append `(:type :bci-nfb-start
                   :protocol ,(symbol-name protocol)
                   :session-id ,session-id
                   :log-interval ,ewwm-bci-nfb-log-interval)
                 params))))
    (run-hook-with-args 'ewwm-bci-nfb-start-hook
                        protocol session-id)
    (message "ewwm-bci-nfb: %s started (id=%s)"
             protocol session-id)))

(defun ewwm-bci-nfb-stop ()
  "Stop the active neurofeedback session."
  (interactive)
  (if (not ewwm-bci-nfb--active)
      (message "ewwm-bci-nfb: no active session")
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send '(:type :bci-nfb-stop)))
    (when ewwm-bci-nfb--timer
      (cancel-timer ewwm-bci-nfb--timer)
      (setq ewwm-bci-nfb--timer nil))
    (let ((sid ewwm-bci-nfb--session-id)
          (fc ewwm-bci-nfb--frame-count))
      ;; Auto-export
      (when ewwm-bci-nfb-auto-export
        (ewwm-bci-nfb--export-session-data))
      (setq ewwm-bci-nfb--active nil)
      (run-hook-with-args 'ewwm-bci-nfb-stop-hook sid fc)
      (message "ewwm-bci-nfb: stopped (frames=%d)" fc))))

(defun ewwm-bci-nfb-status ()
  "Display neurofeedback session status."
  (interactive)
  (if (not ewwm-bci-nfb--active)
      (message "ewwm-bci-nfb: no active session")
    (let ((dur (/ (- (float-time)
                     ewwm-bci-nfb--session-start)
                  60.0)))
      (message
       "ewwm-bci-nfb: %s id=%s dur=%.1fm frames=%d"
       ewwm-bci-nfb--protocol
       ewwm-bci-nfb--session-id
       dur
       ewwm-bci-nfb--frame-count))))

(defun ewwm-bci-nfb-export-session ()
  "Export the current session data to a CSV file."
  (interactive)
  (if (null ewwm-bci-nfb--data-buffer)
      (message "ewwm-bci-nfb: no session data to export")
    (ewwm-bci-nfb--export-session-data)
    (message "ewwm-bci-nfb: session exported")))

;; ── Data export ─────────────────────────────────────────────

(defun ewwm-bci-nfb--export-session-data ()
  "Export session data buffer to a CSV file."
  (when ewwm-bci-nfb--data-buffer
    (let* ((dir (expand-file-name ewwm-bci-nfb-session-dir))
           (filename (format "%s-%s.csv"
                             (or ewwm-bci-nfb--session-id
                                 "unknown")
                             (or ewwm-bci-nfb--protocol
                                 "unknown")))
           (file (expand-file-name filename dir)))
      ;; Ensure directory
      (unless (file-directory-p dir)
        (make-directory dir t))
      ;; Write header
      (write-region
       "timestamp,delta,theta,alpha,beta,gamma,score\n"
       nil file nil 'silent)
      ;; Write data rows (newest first, reverse for chronological)
      (dolist (frame (reverse ewwm-bci-nfb--data-buffer))
        (let* ((ts (plist-get frame :time))
               (bands (plist-get frame :bands))
               (score (plist-get frame :score))
               (line (format "%.3f,%.1f,%.1f,%.1f,%.1f,%.1f,%.4f\n"
                             (or ts 0)
                             (or (plist-get bands :delta) 0)
                             (or (plist-get bands :theta) 0)
                             (or (plist-get bands :alpha) 0)
                             (or (plist-get bands :beta) 0)
                             (or (plist-get bands :gamma) 0)
                             (or score 0))))
          (write-region line nil file t 'silent)))
      (message "ewwm-bci-nfb: exported %d frames to %s"
               (length ewwm-bci-nfb--data-buffer) file))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-bci-nfb--register-events ()
  "Register NFB event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:bci-nfb-frame . ewwm-bci-nfb--on-bci-nfb-frame))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-bci-nfb-init ()
  "Initialize neurofeedback training."
  (ewwm-bci-nfb--register-events))

(defun ewwm-bci-nfb-teardown ()
  "Clean up NFB state."
  (when ewwm-bci-nfb--active
    (ewwm-bci-nfb-stop))
  (when ewwm-bci-nfb--timer
    (cancel-timer ewwm-bci-nfb--timer)
    (setq ewwm-bci-nfb--timer nil))
  (setq ewwm-bci-nfb--active nil
        ewwm-bci-nfb--session-id nil
        ewwm-bci-nfb--session-start nil
        ewwm-bci-nfb--data-buffer nil
        ewwm-bci-nfb--protocol nil
        ewwm-bci-nfb--latest-frame nil
        ewwm-bci-nfb--frame-count 0))

(provide 'ewwm-bci-nfb)
;;; ewwm-bci-nfb.el ends here
