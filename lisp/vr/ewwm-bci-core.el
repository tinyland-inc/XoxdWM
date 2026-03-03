;;; ewwm-bci-core.el --- BCI lifecycle and daemon management  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Core BCI (Brain-Computer Interface) integration for ewwm.
;; Manages BrainFlow daemon lifecycle, board connection,
;; signal quality monitoring, and IPC event dispatch.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-bci nil
  "Brain-Computer Interface settings."
  :group 'ewwm-vr)

(defcustom ewwm-bci-board-id 0
  "BrainFlow board ID for the connected EEG device.
See BrainFlow docs for board ID constants.
Common values: 0=synthetic, 1=Cyton, 2=Ganglion,
22=CytonDaisy, 38=BrainBit, 45=Muse2."
  :type 'integer
  :group 'ewwm-bci)

(defcustom ewwm-bci-serial-port "/dev/openbci"
  "Serial port for EEG board connection.
Typically /dev/ttyUSBx on Linux."
  :type 'string
  :group 'ewwm-bci)

(defcustom ewwm-bci-sample-rate 250
  "Sample rate in Hz for EEG acquisition.
Must match the connected board's capability.
Common rates: 125, 250, 500, 1000."
  :type 'integer
  :group 'ewwm-bci)

(defcustom ewwm-bci-notch-frequency 60
  "Power line notch filter frequency in Hz.
Use 60 for North America, 50 for Europe/Asia."
  :type '(choice (const 50) (const 60))
  :group 'ewwm-bci)

(defcustom ewwm-bci-artifact-rejection t
  "Non-nil to enable automatic artifact rejection.
Filters eye blinks, muscle artifacts, and
electrode noise from the EEG signal."
  :type 'boolean
  :group 'ewwm-bci)

(defcustom ewwm-bci-data-retention-days 90
  "Number of days to retain BCI session data.
Set to 0 to disable automatic cleanup."
  :type 'integer
  :group 'ewwm-bci)

(defcustom ewwm-bci-daemon-path "exwm-vr-brainflow-daemon"
  "Path to the BrainFlow daemon executable.
The daemon bridges BrainFlow C++ library to the
compositor via shared memory or socket."
  :type 'string
  :group 'ewwm-bci)

(defcustom ewwm-bci-daemon-args nil
  "Extra arguments passed to the BrainFlow daemon.
List of strings appended to the daemon command line."
  :type '(repeat string)
  :group 'ewwm-bci)

(defcustom ewwm-bci-auto-reconnect t
  "Non-nil to auto-reconnect on connection loss."
  :type 'boolean
  :group 'ewwm-bci)

(defcustom ewwm-bci-reconnect-delay 5
  "Delay in seconds before auto-reconnect attempt."
  :type 'integer
  :group 'ewwm-bci)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-bci--connection-state 'disconnected
  "BCI connection state symbol.
One of: disconnected, connecting, connected, error.")

(defvar ewwm-bci--streaming nil
  "Non-nil when EEG data streaming is active.")

(defvar ewwm-bci--channel-quality nil
  "Plist of per-channel signal quality.
Keys are channel numbers, values are quality symbols:
good, fair, poor, disconnected.")

(defvar ewwm-bci--frames-received 0
  "Total number of EEG frames received this session.")

(defvar ewwm-bci--daemon-process nil
  "Process object for the BrainFlow daemon, or nil.")

(defvar ewwm-bci--last-error nil
  "Last BCI error message string, or nil.")

(defvar ewwm-bci--session-start nil
  "Session start time as float-time, or nil.")

(defvar ewwm-bci--reconnect-timer nil
  "Timer for auto-reconnect, or nil.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-bci-connected-hook nil
  "Hook run when BCI board connects successfully.
Functions receive no arguments.")

(defvar ewwm-bci-disconnected-hook nil
  "Hook run when BCI board disconnects.
Functions receive (REASON) where REASON is a string.")

(defvar ewwm-bci-quality-change-hook nil
  "Hook run when signal quality changes.
Functions receive (CHANNEL-QUALITY) as a plist.")

(defvar ewwm-bci-error-hook nil
  "Hook run on BCI errors.
Functions receive (ERROR-MSG) as a string.")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-bci--on-bci-connected (msg)
  "Handle :bci-connected event MSG.
Updates state and runs connected hook."
  (let ((board (plist-get msg :board-id))
        (rate (plist-get msg :sample-rate)))
    (setq ewwm-bci--connection-state 'connected
          ewwm-bci--streaming t
          ewwm-bci--session-start (float-time)
          ewwm-bci--last-error nil)
    (when ewwm-bci--reconnect-timer
      (cancel-timer ewwm-bci--reconnect-timer)
      (setq ewwm-bci--reconnect-timer nil))
    (message "ewwm-bci: connected (board=%s rate=%sHz)"
             (or board ewwm-bci-board-id)
             (or rate ewwm-bci-sample-rate))
    (run-hooks 'ewwm-bci-connected-hook)))

(defun ewwm-bci--on-bci-disconnected (msg)
  "Handle :bci-disconnected event MSG.
Updates state, runs hook, and schedules reconnect."
  (let ((reason (or (plist-get msg :reason) "unknown")))
    (setq ewwm-bci--connection-state 'disconnected
          ewwm-bci--streaming nil)
    (message "ewwm-bci: disconnected (%s)" reason)
    (run-hook-with-args 'ewwm-bci-disconnected-hook reason)
    (when (and ewwm-bci-auto-reconnect
               (not ewwm-bci--reconnect-timer))
      (setq ewwm-bci--reconnect-timer
            (run-with-timer ewwm-bci-reconnect-delay
                            nil #'ewwm-bci--try-reconnect)))))

(defun ewwm-bci--on-bci-quality (msg)
  "Handle :bci-quality event MSG.
Updates per-channel quality and fires hook."
  (let ((quality (plist-get msg :channels)))
    (when quality
      (setq ewwm-bci--channel-quality quality)
      (run-hook-with-args 'ewwm-bci-quality-change-hook
                          quality))))

(defun ewwm-bci--on-bci-error (msg)
  "Handle :bci-error event MSG.
Records error, updates state, fires hook."
  (let ((error-msg (or (plist-get msg :message) "unknown error")))
    (setq ewwm-bci--last-error error-msg
          ewwm-bci--connection-state 'error)
    (message "ewwm-bci: error - %s" error-msg)
    (run-hook-with-args 'ewwm-bci-error-hook error-msg)))

(defun ewwm-bci--on-bci-frame (_msg)
  "Handle :bci-frame event _MSG.
Increment frame counter for throughput tracking."
  (cl-incf ewwm-bci--frames-received))

;; ── Daemon management ───────────────────────────────────────

(defun ewwm-bci--start-daemon ()
  "Start the BrainFlow daemon as a subprocess.
Returns the process object or nil on failure."
  (when (and ewwm-bci--daemon-process
             (process-live-p ewwm-bci--daemon-process))
    (message "ewwm-bci: daemon already running")
    (cl-return-from ewwm-bci--start-daemon
                    ewwm-bci--daemon-process))
  (let* ((args (append (list "--board-id"
                             (number-to-string ewwm-bci-board-id)
                             "--serial-port" ewwm-bci-serial-port
                             "--sample-rate"
                             (number-to-string ewwm-bci-sample-rate)
                             "--notch"
                             (number-to-string
                              ewwm-bci-notch-frequency))
                       (when ewwm-bci-artifact-rejection
                         (list "--artifact-rejection"))
                       ewwm-bci-daemon-args))
         (proc (condition-case err
                   (apply #'start-process
                          "ewwm-bci-daemon"
                          " *ewwm-bci-daemon*"
                          ewwm-bci-daemon-path
                          args)
                 (error
                  (message "ewwm-bci: failed to start daemon: %s"
                           (error-message-string err))
                  nil))))
    (when proc
      (set-process-sentinel proc #'ewwm-bci--daemon-sentinel)
      (setq ewwm-bci--daemon-process proc
            ewwm-bci--connection-state 'connecting)
      (message "ewwm-bci: daemon starting..."))
    proc))

(defun ewwm-bci--daemon-sentinel (_proc event)
  "Process sentinel for BrainFlow daemon _PROC.
EVENT describes the process state change."
  (let ((clean-event (string-trim event)))
    (cond
     ((string-match "finished" clean-event)
      (setq ewwm-bci--daemon-process nil
            ewwm-bci--connection-state 'disconnected
            ewwm-bci--streaming nil)
      (message "ewwm-bci: daemon exited normally"))
     ((string-match "\\(exited\\|signal\\)" clean-event)
      (setq ewwm-bci--daemon-process nil
            ewwm-bci--connection-state 'error
            ewwm-bci--streaming nil)
      (message "ewwm-bci: daemon died: %s" clean-event)))))

(defun ewwm-bci--stop-daemon ()
  "Stop the BrainFlow daemon if running."
  (when (and ewwm-bci--daemon-process
             (process-live-p ewwm-bci--daemon-process))
    (delete-process ewwm-bci--daemon-process)
    (setq ewwm-bci--daemon-process nil))
  (setq ewwm-bci--streaming nil))

(defun ewwm-bci--try-reconnect ()
  "Attempt to reconnect to the BCI board."
  (setq ewwm-bci--reconnect-timer nil)
  (when (eq ewwm-bci--connection-state 'disconnected)
    (message "ewwm-bci: attempting reconnect...")
    (ewwm-bci-start)))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-bci-start ()
  "Start BCI acquisition.
Launches the daemon and sends start command to compositor."
  (interactive)
  (ewwm-bci--start-daemon)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :bci-start
       :board-id ,ewwm-bci-board-id
       :serial-port ,ewwm-bci-serial-port
       :sample-rate ,ewwm-bci-sample-rate
       :notch ,ewwm-bci-notch-frequency
       :artifact-rejection ,ewwm-bci-artifact-rejection))))

(defun ewwm-bci-stop ()
  "Stop BCI acquisition and daemon."
  (interactive)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send '(:type :bci-stop)))
  (ewwm-bci--stop-daemon)
  (setq ewwm-bci--connection-state 'disconnected
        ewwm-bci--streaming nil)
  (message "ewwm-bci: stopped"))

(defun ewwm-bci-restart ()
  "Restart BCI acquisition."
  (interactive)
  (ewwm-bci-stop)
  (run-with-timer 1 nil #'ewwm-bci-start)
  (message "ewwm-bci: restarting..."))

(defun ewwm-bci-status ()
  "Display BCI status in the minibuffer."
  (interactive)
  (let ((dur (if ewwm-bci--session-start
                 (/ (- (float-time)
                       ewwm-bci--session-start)
                    60.0)
               0.0)))
    (message
     "ewwm-bci: state=%s stream=%s frames=%d dur=%.0fm err=%s"
     ewwm-bci--connection-state
     (if ewwm-bci--streaming "on" "off")
     ewwm-bci--frames-received
     dur
     (or ewwm-bci--last-error "none"))))

(defun ewwm-bci-signal-quality ()
  "Display per-channel signal quality."
  (interactive)
  (if (null ewwm-bci--channel-quality)
      (message "ewwm-bci: no signal quality data")
    (let ((lines nil)
          (q ewwm-bci--channel-quality))
      (while q
        (let ((ch (pop q))
              (val (pop q)))
          (push (format "  ch%s: %s" ch val) lines)))
      (message "ewwm-bci signal quality:\n%s"
               (mapconcat #'identity
                          (nreverse lines) "\n")))))

(defun ewwm-bci-hardware-check ()
  "Run hardware diagnostics via IPC."
  (interactive)
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-bci: compositor not connected")
    (ewwm-ipc-send '(:type :bci-hardware-check))
    (message "ewwm-bci: hardware check requested")))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-bci-mode-line-string ()
  "Return a mode-line string for BCI state.
Shows connection state and streaming indicator."
  (cond
   ((eq ewwm-bci--connection-state 'connected)
    (if ewwm-bci--streaming " [BCI:ON]" " [BCI:IDLE]"))
   ((eq ewwm-bci--connection-state 'connecting)
    " [BCI:...]")
   ((eq ewwm-bci--connection-state 'error)
    " [BCI:ERR]")
   (t nil)))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-bci--register-events ()
  "Register BCI event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:bci-connected    . ewwm-bci--on-bci-connected)
     (:bci-disconnected . ewwm-bci--on-bci-disconnected)
     (:bci-quality      . ewwm-bci--on-bci-quality)
     (:bci-error        . ewwm-bci--on-bci-error)
     (:bci-frame        . ewwm-bci--on-bci-frame))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-bci-init ()
  "Initialize BCI core integration.
Registers IPC event handlers."
  (ewwm-bci--register-events))

(defun ewwm-bci-teardown ()
  "Clean up BCI state and stop daemon."
  (ewwm-bci--stop-daemon)
  (when ewwm-bci--reconnect-timer
    (cancel-timer ewwm-bci--reconnect-timer)
    (setq ewwm-bci--reconnect-timer nil))
  (setq ewwm-bci--connection-state 'disconnected
        ewwm-bci--streaming nil
        ewwm-bci--channel-quality nil
        ewwm-bci--frames-received 0
        ewwm-bci--last-error nil
        ewwm-bci--session-start nil
        ewwm-bci--daemon-process nil))

(provide 'ewwm-bci-core)
;;; ewwm-bci-core.el ends here
