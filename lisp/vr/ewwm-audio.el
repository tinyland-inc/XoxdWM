;;; ewwm-audio.el --- Audio control for EWWM  -*- lexical-binding: t -*-

;;; Commentary:
;; PipeWire/WirePlumber audio control via wpctl.
;; Provides volume up/down/mute commands and mode-line indicator.

;;; Code:

(require 'cl-lib)

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-audio nil
  "Audio control for EWWM."
  :group 'ewwm)

(defcustom ewwm-audio-step 5
  "Volume change step (percentage) for up/down commands."
  :type 'integer
  :group 'ewwm-audio)

(defcustom ewwm-audio-max-volume 150
  "Maximum allowed volume percentage."
  :type 'integer
  :group 'ewwm-audio)

(defcustom ewwm-audio-wpctl-path "wpctl"
  "Path to the wpctl binary."
  :type 'string
  :group 'ewwm-audio)

(defcustom ewwm-audio-sink-id "@DEFAULT_AUDIO_SINK@"
  "PipeWire sink ID for volume control."
  :type 'string
  :group 'ewwm-audio)

(defcustom ewwm-audio-source-id "@DEFAULT_AUDIO_SOURCE@"
  "PipeWire source ID for microphone control."
  :type 'string
  :group 'ewwm-audio)

(defcustom ewwm-audio-mode-line t
  "Show audio status in the mode line."
  :type 'boolean
  :group 'ewwm-audio)

(defcustom ewwm-audio-poll-interval 5
  "Seconds between mode-line status refreshes."
  :type 'number
  :group 'ewwm-audio)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-audio--volume nil
  "Cached volume percentage (integer).")

(defvar ewwm-audio--muted nil
  "Cached mute state (boolean).")

(defvar ewwm-audio--timer nil
  "Timer for polling audio status.")

(defvar ewwm-audio--mode-line-string ""
  "Current mode-line audio string.")

;; ── wpctl interface ──────────────────────────────────────────

(defun ewwm-audio--wpctl (&rest args)
  "Run wpctl with ARGS synchronously.  Return stdout string."
  (with-temp-buffer
    (apply #'call-process ewwm-audio-wpctl-path nil t nil args)
    (string-trim (buffer-string))))

(defun ewwm-audio--wpctl-async (callback &rest args)
  "Run wpctl with ARGS asynchronously, call CALLBACK with stdout."
  (let ((buf (generate-new-buffer " *ewwm-audio-wpctl*")))
    (set-process-sentinel
     (apply #'start-process "ewwm-audio-wpctl" buf
            ewwm-audio-wpctl-path args)
     (lambda (proc _event)
       (when (eq (process-status proc) 'exit)
         (let ((output (with-current-buffer (process-buffer proc)
                         (string-trim (buffer-string)))))
           (kill-buffer (process-buffer proc))
           (when callback
             (funcall callback output))))))))

(defun ewwm-audio--parse-volume (output)
  "Parse volume and mute state from wpctl get-volume OUTPUT.
Returns (VOLUME . MUTED) where VOLUME is an integer percentage."
  (cond
   ((string-match "Volume: \\([0-9.]+\\)\\(?: \\[MUTED\\]\\)?" output)
    (let ((vol (round (* 100 (string-to-number (match-string 1 output)))))
          (muted (string-match-p "\\[MUTED\\]" output)))
      (cons vol (if muted t nil))))
   (t (cons 0 nil))))

;; ── Commands ────────────────────────────────────────────────

(defun ewwm-audio-volume-up (&optional step)
  "Increase default sink volume by STEP percent (default `ewwm-audio-step')."
  (interactive)
  (let ((s (or step ewwm-audio-step)))
    (ewwm-audio--wpctl "set-volume" ewwm-audio-sink-id
                        (format "%d%%+" s)
                        "--limit" (format "%.2f" (/ (float ewwm-audio-max-volume) 100)))
    (ewwm-audio-refresh)
    (message "Vol: %d%%%s" (or ewwm-audio--volume 0)
             (if ewwm-audio--muted " [MUTED]" ""))))

(defun ewwm-audio-volume-down (&optional step)
  "Decrease default sink volume by STEP percent (default `ewwm-audio-step')."
  (interactive)
  (let ((s (or step ewwm-audio-step)))
    (ewwm-audio--wpctl "set-volume" ewwm-audio-sink-id
                        (format "%d%%-" s))
    (ewwm-audio-refresh)
    (message "Vol: %d%%%s" (or ewwm-audio--volume 0)
             (if ewwm-audio--muted " [MUTED]" ""))))

(defun ewwm-audio-mute-toggle ()
  "Toggle mute on default sink."
  (interactive)
  (ewwm-audio--wpctl "set-mute" ewwm-audio-sink-id "toggle")
  (ewwm-audio-refresh)
  (message "Vol: %d%%%s" (or ewwm-audio--volume 0)
           (if ewwm-audio--muted " [MUTED]" "")))

(defun ewwm-audio-mic-mute-toggle ()
  "Toggle mute on default source (microphone)."
  (interactive)
  (ewwm-audio--wpctl "set-mute" ewwm-audio-source-id "toggle")
  (message "Mic mute toggled"))

(defun ewwm-audio-set-volume (pct)
  "Set default sink volume to PCT percent."
  (interactive "nVolume %%: ")
  (let ((clamped (max 0 (min pct ewwm-audio-max-volume))))
    (ewwm-audio--wpctl "set-volume" ewwm-audio-sink-id
                        (format "%d%%" clamped))
    (ewwm-audio-refresh)
    (message "Vol: %d%%" clamped)))

;; ── Status ──────────────────────────────────────────────────

(defun ewwm-audio-refresh ()
  "Refresh cached volume and mute state."
  (let* ((output (ewwm-audio--wpctl "get-volume" ewwm-audio-sink-id))
         (parsed (ewwm-audio--parse-volume output)))
    (setq ewwm-audio--volume (car parsed)
          ewwm-audio--muted (cdr parsed))
    (ewwm-audio--update-mode-line)))

(defun ewwm-audio-status ()
  "Display current audio status."
  (interactive)
  (ewwm-audio-refresh)
  (message "Audio: %d%%%s  sink=%s"
           (or ewwm-audio--volume 0)
           (if ewwm-audio--muted " [MUTED]" "")
           ewwm-audio-sink-id))

;; ── Mode line ───────────────────────────────────────────────

(defun ewwm-audio--update-mode-line ()
  "Update the mode-line audio string."
  (setq ewwm-audio--mode-line-string
        (if (and ewwm-audio-mode-line ewwm-audio--volume)
            (format " %s%d%%"
                    (if ewwm-audio--muted "M:" "V:")
                    ewwm-audio--volume)
          ""))
  (force-mode-line-update t))

(defun ewwm-audio--poll ()
  "Poll audio status for mode-line updates."
  (ewwm-audio-refresh))

;; ── Lifecycle ───────────────────────────────────────────────

(defun ewwm-audio-enable ()
  "Enable audio control and mode-line indicator."
  (interactive)
  (ewwm-audio-refresh)
  (unless (member '(:eval ewwm-audio--mode-line-string) global-mode-string)
    (push '(:eval ewwm-audio--mode-line-string) global-mode-string))
  (when ewwm-audio--timer
    (cancel-timer ewwm-audio--timer))
  (setq ewwm-audio--timer
        (run-with-timer ewwm-audio-poll-interval
                        ewwm-audio-poll-interval
                        #'ewwm-audio--poll))
  (message "ewwm-audio: enabled"))

(defun ewwm-audio-disable ()
  "Disable audio mode-line indicator."
  (interactive)
  (when ewwm-audio--timer
    (cancel-timer ewwm-audio--timer)
    (setq ewwm-audio--timer nil))
  (setq global-mode-string
        (delete '(:eval ewwm-audio--mode-line-string) global-mode-string))
  (setq ewwm-audio--mode-line-string "")
  (force-mode-line-update t)
  (message "ewwm-audio: disabled"))

(provide 'ewwm-audio)
;;; ewwm-audio.el ends here
