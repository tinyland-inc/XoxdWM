;;; ewwm-vr-eye.el --- Eye tracking integration  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Eye tracking for ewwm: OpenXR XR_EXT_eye_gaze_interaction, Pupil Labs
;; ZMQ client, unified gaze model, gaze-surface intersection, visualization,
;; calibration, health monitoring, and simulated gaze for development.

;;; Code:

(require 'cl-lib)
(require 'ring)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-eye nil
  "Eye tracking settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-gaze-source 'auto
  "Preferred gaze data source.
`auto': prefer OpenXR, fall back to Bigeye, Pupil Labs, then simulated.
`openxr': force OpenXR eye gaze extension.
`bigeye': Bigscreen Bigeye IR cameras with local pupil detection.
`pupil-labs': force Pupil Labs ZMQ client.
`simulated': use simulated gaze for development.
`none': disable eye tracking."
  :type '(choice (const auto)
                 (const openxr)
                 (const bigeye)
                 (const pupil-labs)
                 (const simulated)
                 (const none))
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-gaze-smoothing 0.3
  "EMA alpha for gaze smoothing.
0 = maximum smooth (high latency), 1 = no smoothing (jittery)."
  :type 'number
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-gaze-visualization 'dot
  "Visualization mode for the gaze indicator.
`dot': small circle at intersection point.
`crosshair': thin crosshair lines.
`spotlight': larger area with gaussian falloff.
`none': no visualization."
  :type '(choice (const dot)
                 (const crosshair)
                 (const spotlight)
                 (const none))
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-gaze-simulate nil
  "Simulated gaze mode for development without eye tracker hardware.
nil to disable simulation.
`mouse': mouse position drives gaze.
`scripted': replay recorded gaze trace.
`random-walk': random saccade-like gaze wandering.
`pattern': cycle through surfaces dwelling 2 seconds each."
  :type '(choice (const nil)
                 (const mouse)
                 (const scripted)
                 (const random-walk)
                 (const pattern))
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-gaze-confidence-min 0.6
  "Minimum gaze confidence to update target.
Samples below this threshold are ignored."
  :type 'number
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-pupil-port 50020
  "Pupil Capture IPC port for ZMQ connection."
  :type 'integer
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-gaze-mode-line t
  "Non-nil to show gaze target in mode-line."
  :type 'boolean
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-enable t
  "Master switch for gaze-based focus."
  :type 'boolean
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-focus-policy 'gaze-primary
  "Gaze focus policy.
`gaze-only': gaze dwell is the sole focus method.
`gaze-primary': gaze dwell switches focus, keyboard/mouse also work.
`gaze-assist': gaze highlights target, requires confirmation to focus.
`disabled': traditional focus only, gaze has no effect."
  :type '(choice (const gaze-only)
                 (const gaze-primary)
                 (const gaze-assist)
                 (const disabled))
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-dwell-ms 200
  "Milliseconds of stable gaze before focus switch."
  :type 'integer
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-cooldown-ms 500
  "Minimum time between gaze-triggered focus changes."
  :type 'integer
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-saccade-threshold 300
  "Angular velocity in deg/s above which gaze is classified as saccade."
  :type 'integer
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-max-jitter-px 50
  "Maximum gaze jitter in pixels during dwell."
  :type 'integer
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-reading-detection t
  "Detect reading patterns to prevent false focus changes."
  :type 'boolean
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-hysteresis t
  "Automatically increase dwell threshold for ping-pong patterns."
  :type 'boolean
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-show-dwell-progress t
  "Show dwell progress in mode-line and VR overlay."
  :type 'boolean
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-focus-exceptions nil
  "Alist of (PREDICATE . POLICY) for per-surface focus overrides.
Each PREDICATE is a function taking a buffer, returning non-nil if matched.
POLICY overrides `ewwm-vr-eye-focus-policy' for matching surfaces."
  :type '(alist :key-type function :value-type symbol)
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-cross-workspace-focus nil
  "Allow gaze to focus surfaces on other workspaces."
  :type 'boolean
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-fallback 'head-gaze
  "Fallback when eye tracking unavailable.
`head-gaze': use head-gaze ray from VR interaction.
`disabled': no gaze focus without eye tracking."
  :type '(choice (const head-gaze) (const disabled))
  :group 'ewwm-vr-eye)

(defcustom ewwm-vr-eye-analytics-enable t
  "Log gaze focus analytics."
  :type 'boolean
  :group 'ewwm-vr-eye)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-gaze-surface nil
  "Surface ID currently under gaze, or nil.")

(defvar ewwm-vr-gaze-position nil
  "Cons of (x . y) pixel coordinates of gaze on current surface.")

(defvar ewwm-vr-gaze-confidence 0.0
  "Current gaze confidence [0.0, 1.0].")

(defvar ewwm-vr-gaze-source-active nil
  "Symbol for the currently active gaze source, or nil.")

(defvar ewwm-vr-gaze-tracking-p nil
  "Non-nil when eye tracking is active and producing data.")

(defvar ewwm-vr-gaze-calibrated-p nil
  "Non-nil when eye tracker has been calibrated.")

(defvar ewwm-vr-eye--tracking-active nil
  "Non-nil when the eye tracking subsystem is running.")

(defvar ewwm-vr-eye--gaze-position nil
  "Current gaze position as (X . Y) in screen coordinates.")

(defvar ewwm-vr-eye--dwell-surface nil
  "Surface ID currently being dwelled on, or nil.")

(defvar ewwm-vr-eye--dwell-progress 0.0
  "Current dwell progress as fraction 0.0 to 1.0.")

(defvar ewwm-vr-eye--cooldown-remaining 0
  "Remaining cooldown time in ms, or 0.")

(defvar ewwm-vr-eye--in-saccade nil
  "Non-nil when saccade is detected.")

(defvar ewwm-vr-eye--in-reading nil
  "Non-nil when reading mode is active.")

(defvar ewwm-vr-eye--focus-ring (make-ring 10)
  "Ring buffer of last 10 gaze-focused surface IDs.")

(defvar ewwm-last-focus-method nil
  "How focus was last changed: `gaze', `keyboard', `mouse', `controller'.")

(defvar ewwm-vr-eye--analytics nil
  "Plist of gaze focus analytics from compositor.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-gaze-target-change-hook nil
  "Hook run when gaze moves to a different surface.
Functions receive (SURFACE-ID PREV-SURFACE-ID).")

(defvar ewwm-vr-gaze-fixation-hook nil
  "Hook run on detected gaze fixation.
Functions receive (SURFACE-ID X Y DURATION-MS).")

(defvar ewwm-vr-gaze-tracking-lost-hook nil
  "Hook run when eye tracking is lost.
Functions receive (SOURCE DURATION-MS).")

(defvar ewwm-vr-gaze-calibration-drift-hook nil
  "Hook run when calibration drift is detected.
Functions receive (ERROR-DEG).")

(defvar ewwm-vr-gaze-dwell-hook nil
  "Hook run on gaze dwell confirmed.
Functions receive (SURFACE-ID DWELL-MS X Y).")

(defvar ewwm-vr-gaze-focus-hook nil
  "Hook run after gaze-triggered focus switch.
Functions receive (SURFACE-ID METHOD).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-eye--on-gaze-data (msg)
  "Handle :gaze-data event MSG."
  (let ((sid (plist-get msg :surface-id))
        (x (plist-get msg :x))
        (y (plist-get msg :y))
        (conf (plist-get msg :confidence))
        (source (plist-get msg :source)))
    (setq ewwm-vr-gaze-surface sid
          ewwm-vr-gaze-position (when (and x y) (cons x y))
          ewwm-vr-gaze-confidence (or conf 0.0)
          ewwm-vr-gaze-source-active source
          ewwm-vr-gaze-tracking-p t
          ewwm-vr-eye--gaze-position (when (and x y) (cons x y)))))

(defun ewwm-vr-eye--on-gaze-target-changed (msg)
  "Handle :gaze-target-changed event MSG."
  (let ((sid (plist-get msg :surface-id))
        (prev (plist-get msg :prev-surface-id)))
    (setq ewwm-vr-gaze-surface sid)
    (run-hook-with-args 'ewwm-vr-gaze-target-change-hook sid prev)))

(defun ewwm-vr-eye--on-gaze-fixation (msg)
  "Handle :gaze-fixation event MSG."
  (let ((sid (plist-get msg :surface-id))
        (x (plist-get msg :x))
        (y (plist-get msg :y))
        (dur (plist-get msg :duration-ms)))
    (run-hook-with-args 'ewwm-vr-gaze-fixation-hook sid x y dur)))

(defun ewwm-vr-eye--on-gaze-saccade (_msg)
  "Handle :gaze-saccade event MSG (informational).")

(defun ewwm-vr-eye--on-gaze-tracking-lost (msg)
  "Handle :gaze-tracking-lost event MSG."
  (let ((source (plist-get msg :source))
        (dur (plist-get msg :duration-ms)))
    (setq ewwm-vr-gaze-tracking-p nil)
    (run-hook-with-args 'ewwm-vr-gaze-tracking-lost-hook source dur)
    (message "ewwm-vr-eye: tracking lost (%s, %dms)" source (or dur 0))))

(defun ewwm-vr-eye--on-gaze-calibration-drift (msg)
  "Handle :gaze-calibration-drift event MSG."
  (let ((err (plist-get msg :error-deg)))
    (run-hook-with-args 'ewwm-vr-gaze-calibration-drift-hook err)
    (message "ewwm-vr-eye: calibration drift detected (%.1f deg)" (or err 0))))

(defun ewwm-vr-eye--on-gaze-dwell (msg)
  "Handle :gaze-dwell event MSG."
  (let ((sid (plist-get msg :surface-id))
        (dur (plist-get msg :duration-ms))
        (x (plist-get msg :x))
        (y (plist-get msg :y)))
    (setq ewwm-vr-eye--dwell-surface sid)
    (run-hook-with-args 'ewwm-vr-gaze-dwell-hook sid dur x y)
    ;; Process focus request based on policy
    (ewwm-vr-eye--process-focus-request sid dur)))

(defun ewwm-vr-eye--on-gaze-dwell-progress (msg)
  "Handle :gaze-dwell-progress event MSG."
  (let ((elapsed (plist-get msg :elapsed-ms))
        (threshold (plist-get msg :threshold-ms)))
    (setq ewwm-vr-eye--dwell-progress
          (if (and elapsed threshold (> threshold 0))
              (min 1.0 (/ (float elapsed) threshold))
            0.0))
    (setq ewwm-vr-eye--dwell-surface (plist-get msg :surface-id))))

(defun ewwm-vr-eye--on-gaze-focus-request (msg)
  "Handle :gaze-focus-request event MSG from compositor."
  (let ((sid (plist-get msg :surface-id))
        (dwell-ms (plist-get msg :dwell-ms)))
    (ewwm-vr-eye--process-focus-request sid dwell-ms)))

(defun ewwm-vr-eye--on-gaze-cooldown (msg)
  "Handle :gaze-cooldown event MSG."
  (setq ewwm-vr-eye--cooldown-remaining
        (or (plist-get msg :remaining-ms) 0)))

(defun ewwm-vr-eye--on-gaze-saccade-state (msg)
  "Handle :gaze-saccade-state event MSG."
  (setq ewwm-vr-eye--in-saccade (plist-get msg :active)))

(defun ewwm-vr-eye--on-gaze-reading-mode (msg)
  "Handle :gaze-reading-mode event MSG."
  (setq ewwm-vr-eye--in-reading (plist-get msg :active)))

;; ── Focus processing ────────────────────────────────────────

(defun ewwm-vr-eye--process-focus-request (surface-id _dwell-ms)
  "Process a gaze focus request for SURFACE-ID after _DWELL-MS.
Checks policy, exceptions, and workspace before switching focus."
  (when (and ewwm-vr-eye-enable
             (ewwm-vr-eye--should-focus-p surface-id))
    (let ((buf (ewwm--get-buffer surface-id)))
      (when (and buf (buffer-live-p buf))
        ;; Record in focus ring
        (ring-insert ewwm-vr-eye--focus-ring surface-id)
        ;; Switch focus
        (setq ewwm-last-focus-method 'gaze)
        (unless noninteractive
          (switch-to-buffer buf))
        ;; Notify compositor
        (when (and (fboundp 'ewwm-ipc-connected-p)
                   (ewwm-ipc-connected-p))
          (ewwm-ipc-send
           `(:type :surface-focus :surface-id ,surface-id)))
        (run-hook-with-args 'ewwm-vr-gaze-focus-hook surface-id 'gaze)))))

(defun ewwm-vr-eye--should-focus-p (surface-id)
  "Return non-nil if gaze focus should switch to SURFACE-ID.
Checks policy, per-surface exceptions, and workspace constraints."
  (let ((policy ewwm-vr-eye-focus-policy))
    ;; Check per-surface exceptions
    (when-let ((buf (ewwm--get-buffer surface-id)))
      (dolist (exc ewwm-vr-eye-focus-exceptions)
        (when (and (functionp (car exc))
                   (with-current-buffer buf (funcall (car exc) buf)))
          (setq policy (cdr exc)))))
    (cond
     ;; Disabled policy rejects focus
     ((eq policy 'disabled) nil)
     ;; Gaze-assist requires confirmation (not auto-focus)
     ((eq policy 'gaze-assist) nil)
     ;; Workspace check
     ((and (not ewwm-vr-eye-cross-workspace-focus)
           (boundp 'ewwm-workspace-current-index)
           (when-let ((buf (ewwm--get-buffer surface-id)))
             (not (= (buffer-local-value 'ewwm-workspace buf)
                     ewwm-workspace-current-index))))
      nil)
     ;; All checks passed
     (t t))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-calibrate-eyes (&optional points)
  "Start interactive gaze calibration with POINTS targets (default 5)."
  (interactive "P")
  (let ((n (or points 5)))
    (if (not (fboundp 'ewwm-ipc-send))
        (message "ewwm-vr-eye: IPC not available")
      (when (and (fboundp 'ewwm-ipc-connected-p)
                 (ewwm-ipc-connected-p))
        (ewwm-ipc-send
         `(:type :gaze-calibrate-start :points ,n))
        (message "ewwm-vr-eye: calibration started (%d points) — look at target 1" n)))))

(defun ewwm-vr-calibrate-eye-point ()
  "Confirm the current calibration target point."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-eye: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :gaze-calibrate-point))))
          (if (eq (plist-get resp :status) :ok)
              (let ((cal (plist-get resp :calibration)))
                (cond
                 ((eq cal :complete)
                  (setq ewwm-vr-gaze-calibrated-p t)
                  (message "ewwm-vr-eye: calibration complete! RMS error: %.1f degrees"
                           (or (plist-get resp :rms-error) 0)))
                 ((eq cal :point-recorded)
                  (message "ewwm-vr-eye: point recorded, look at target %d"
                           (1+ (or (plist-get resp :next) 0))))))
            (message "ewwm-vr-eye: calibration error: %s"
                     (plist-get resp :reason))))
      (error (message "ewwm-vr-eye: %s" (error-message-string err))))))

(defun ewwm-vr-gaze-health ()
  "Display eye tracking health dashboard."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-eye: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :gaze-health))))
          (if (eq (plist-get resp :status) :ok)
              (let ((h (plist-get resp :health)))
                (message "ewwm-vr-eye: rate=%s/%sHz conf=%.2f lost=%s cal-err=%s"
                         (or (plist-get h :rate) "?")
                         (or (plist-get h :expected-rate) "?")
                         (or (plist-get h :confidence) 0)
                         (if (plist-get h :tracking-lost) "YES" "no")
                         (or (plist-get h :calibration-error) "n/a")))
            (message "ewwm-vr-eye: health query failed")))
      (error (message "ewwm-vr-eye: %s" (error-message-string err))))))

(defun ewwm-vr-set-gaze-source (source)
  "Set gaze SOURCE preference.
SOURCE is a symbol: `auto', `openxr', `pupil-labs', `simulated', or `none'."
  (interactive
   (list (intern (completing-read "Gaze source: "
                                  '("auto" "openxr" "pupil-labs" "simulated" "none")
                                  nil t))))
  (unless (memq source '(auto openxr pupil-labs simulated none))
    (error "Invalid gaze source: %s" source))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :gaze-set-source :source ,(symbol-name source))))
  (message "ewwm-vr-eye: gaze source set to %s" source))

(defun ewwm-vr-set-gaze-visualization (mode)
  "Set gaze visualization MODE.
MODE is a symbol: `dot', `crosshair', `spotlight', or `none'."
  (interactive
   (list (intern (completing-read "Visualization: "
                                  '("dot" "crosshair" "spotlight" "none")
                                  nil t))))
  (unless (memq mode '(dot crosshair spotlight none))
    (error "Invalid visualization mode: %s" mode))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :gaze-set-visualization :mode ,(symbol-name mode))))
  (message "ewwm-vr-eye: visualization set to %s" mode))

(defun ewwm-vr-set-gaze-smoothing (alpha)
  "Set gaze EMA smoothing ALPHA (0.0-1.0)."
  (interactive "nSmoothing alpha (0.0=max smooth, 1.0=none): ")
  (let ((a (max 0.0 (min 1.0 alpha))))
    (setq ewwm-vr-gaze-smoothing a)
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       `(:type :gaze-set-smoothing :alpha ,(round (* a 100)))))
    (message "ewwm-vr-eye: smoothing alpha set to %.2f" a)))

(defun ewwm-vr-gaze-simulate (mode)
  "Set simulated gaze MODE for development.
MODE is nil (off), `mouse', `scripted', `random-walk', or `pattern'."
  (interactive
   (list (let ((choice (completing-read "Simulate mode: "
                                        '("off" "mouse" "scripted" "random-walk" "pattern")
                                        nil t)))
           (if (string= choice "off") nil (intern choice)))))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :gaze-simulate :mode ,(if mode (symbol-name mode) "off"))))
  (message "ewwm-vr-eye: simulation %s" (if mode (symbol-name mode) "off")))

(defun ewwm-vr-gaze-status ()
  "Query and display current gaze tracking state."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-eye: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :gaze-status))))
          (if (eq (plist-get resp :status) :ok)
              (let ((g (plist-get resp :gaze)))
                (message "ewwm-vr-eye: source=%s active=%s conf=%.2f vis=%s smooth=%.2f"
                         (or (plist-get g :source) "?")
                         (or (plist-get g :active) "?")
                         (or (plist-get g :confidence) 0)
                         (or (plist-get g :visualization) "?")
                         (or (plist-get g :smoothing) 0)))
            (message "ewwm-vr-eye: status query failed")))
      (error (message "ewwm-vr-eye: %s" (error-message-string err))))))

(defun ewwm-vr-gaze-at-point-p ()
  "Return non-nil if gaze is on the current buffer's surface."
  (when ewwm-vr-gaze-surface
    (let ((buf (current-buffer)))
      (when (ewwm--surface-buffer-p buf)
        (eq (buffer-local-value 'ewwm-surface-id buf)
            ewwm-vr-gaze-surface)))))

(defun ewwm-vr-eye-focus-back ()
  "Return to the previously gaze-focused surface."
  (interactive)
  (if (ring-empty-p ewwm-vr-eye--focus-ring)
      (message "ewwm-vr-eye: no focus history")
    (let ((prev (ring-ref ewwm-vr-eye--focus-ring 0)))
      (when-let ((buf (ewwm--get-buffer prev)))
        (when (buffer-live-p buf)
          (setq ewwm-last-focus-method 'gaze)
          (unless noninteractive
            (switch-to-buffer buf))
          (message "ewwm-vr-eye: focused back to %d" prev))))))

(defun ewwm-vr-eye-set-focus-policy (policy)
  "Set the gaze focus POLICY.
POLICY is a symbol: `gaze-only', `gaze-primary', `gaze-assist', or `disabled'."
  (interactive
   (list (intern (completing-read "Focus policy: "
                                  '("gaze-only" "gaze-primary" "gaze-assist" "disabled")
                                  nil t))))
  (unless (memq policy '(gaze-only gaze-primary gaze-assist disabled))
    (error "Invalid focus policy: %s" policy))
  (setq ewwm-vr-eye-focus-policy policy)
  (when (and (fboundp 'ewwm-ipc-connected-p) (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :gaze-focus-set-policy :policy ,(symbol-name policy))))
  (message "ewwm-vr-eye: focus policy set to %s" policy))

(defun ewwm-vr-eye-set-dwell-threshold (ms)
  "Set the dwell threshold to MS milliseconds."
  (interactive "nDwell threshold (ms): ")
  (setq ewwm-vr-eye-dwell-ms (max 50 (min 2000 ms)))
  (when (and (fboundp 'ewwm-ipc-connected-p) (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :gaze-focus-set-dwell :threshold-ms ,ewwm-vr-eye-dwell-ms)))
  (message "ewwm-vr-eye: dwell threshold set to %dms" ewwm-vr-eye-dwell-ms))

(defun ewwm-vr-eye-analytics ()
  "Display gaze focus analytics dashboard."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-eye: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :gaze-focus-analytics))))
          (if (eq (plist-get resp :status) :ok)
              (let ((a (plist-get resp :analytics))
                    (buf (get-buffer-create "*ewwm-gaze-analytics*")))
                (setq ewwm-vr-eye--analytics a)
                (with-current-buffer buf
                  (let ((inhibit-read-only t))
                    (erase-buffer)
                    (insert "EWWM Gaze Focus Analytics\n")
                    (insert "=========================\n\n")
                    (insert (format "  Focus switches:       %s\n"
                                    (or (plist-get a :switches) 0)))
                    (insert (format "  False positives:      %s\n"
                                    (or (plist-get a :false-positives) 0)))
                    (insert (format "  Saccade suppressions: %s\n"
                                    (or (plist-get a :saccade-suppressions) 0)))
                    (insert (format "  Cooldown blocks:      %s\n"
                                    (or (plist-get a :cooldown-blocks) 0)))
                    (insert (format "  Reading suppressions: %s\n"
                                    (or (plist-get a :reading-suppressions) 0)))
                    (insert (format "  Switches/min:         %.1f\n"
                                    (or (plist-get a :switches-per-min) 0.0)))
                    (insert "\n[Press q to close]"))
                  (special-mode))
                (display-buffer buf))
            (message "ewwm-vr-eye: analytics query failed")))
      (error (message "ewwm-vr-eye: %s" (error-message-string err))))))

(defun ewwm-vr-eye-focus-config ()
  "Display current gaze focus configuration."
  (interactive)
  (message "ewwm-vr-eye: policy=%s dwell=%dms cooldown=%dms saccade=%d jitter=%dpx read=%s hyst=%s"
           ewwm-vr-eye-focus-policy
           ewwm-vr-eye-dwell-ms
           ewwm-vr-eye-cooldown-ms
           ewwm-vr-eye-saccade-threshold
           ewwm-vr-eye-max-jitter-px
           (if ewwm-vr-eye-reading-detection "on" "off")
           (if ewwm-vr-eye-hysteresis "on" "off")))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-eye-mode-line-string ()
  "Return a mode-line string for gaze focus state."
  (when ewwm-vr-gaze-mode-line
    (cond
     ;; Saccade in progress
     (ewwm-vr-eye--in-saccade " [Eye:>>>]")
     ;; Cooldown active
     ((> ewwm-vr-eye--cooldown-remaining 0)
      (format " [Eye:COOL %dms]" ewwm-vr-eye--cooldown-remaining))
     ;; Tracking lost
     ((not ewwm-vr-gaze-tracking-p) nil)
     ;; Reading mode
     (ewwm-vr-eye--in-reading
      (format " [Eye:READ %s]"
              (if ewwm-vr-gaze-surface
                  (number-to-string ewwm-vr-gaze-surface)
                "---")))
     ;; Dwell in progress
     ((and ewwm-vr-eye-show-dwell-progress
           ewwm-vr-eye--dwell-surface
           (> ewwm-vr-eye--dwell-progress 0.0))
      (let* ((filled (round (* ewwm-vr-eye--dwell-progress 5)))
             (empty (- 5 filled))
             (bar (concat (make-string filled ?=)
                          (make-string empty ?_))))
        (format " [Eye:%s %d]" bar ewwm-vr-eye--dwell-surface)))
     ;; Normal tracking
     (ewwm-vr-gaze-surface
      (format " [Eye:%d]" ewwm-vr-gaze-surface))
     ;; Tracking but no target
     (ewwm-vr-gaze-tracking-p " [Eye:---]"))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-eye--register-events ()
  "Register eye tracking event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:gaze-data             . ewwm-vr-eye--on-gaze-data)
     (:gaze-target-changed   . ewwm-vr-eye--on-gaze-target-changed)
     (:gaze-fixation         . ewwm-vr-eye--on-gaze-fixation)
     (:gaze-saccade          . ewwm-vr-eye--on-gaze-saccade)
     (:gaze-tracking-lost    . ewwm-vr-eye--on-gaze-tracking-lost)
     (:gaze-calibration-drift . ewwm-vr-eye--on-gaze-calibration-drift)
     (:gaze-dwell            . ewwm-vr-eye--on-gaze-dwell)
     (:gaze-dwell-progress   . ewwm-vr-eye--on-gaze-dwell-progress)
     (:gaze-focus-request    . ewwm-vr-eye--on-gaze-focus-request)
     (:gaze-cooldown         . ewwm-vr-eye--on-gaze-cooldown)
     (:gaze-saccade-state    . ewwm-vr-eye--on-gaze-saccade-state)
     (:gaze-reading-mode     . ewwm-vr-eye--on-gaze-reading-mode))))

;; ── Minor mode ───────────────────────────────────────────────

(define-minor-mode ewwm-vr-eye-mode
  "Minor mode for eye tracking integration."
  :lighter " VR-Eye"
  :group 'ewwm-vr-eye
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c e c") #'ewwm-vr-calibrate-eyes)
            (define-key map (kbd "C-c e h") #'ewwm-vr-gaze-health)
            (define-key map (kbd "C-c e s") #'ewwm-vr-gaze-status)
            (define-key map (kbd "C-c e b") #'ewwm-vr-eye-focus-back)
            (define-key map (kbd "C-c e p") #'ewwm-vr-eye-set-focus-policy)
            (define-key map (kbd "C-c e d") #'ewwm-vr-eye-set-dwell-threshold)
            (define-key map (kbd "C-c e a") #'ewwm-vr-eye-analytics)
            (define-key map (kbd "C-c e C") #'ewwm-vr-eye-focus-config)
            map))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-eye-init ()
  "Initialize eye tracking."
  (ewwm-vr-eye--register-events)
  (setq ewwm-vr-eye--tracking-active t))

(defun ewwm-vr-eye-teardown ()
  "Clean up eye tracking state."
  (setq ewwm-vr-gaze-surface nil
        ewwm-vr-gaze-position nil
        ewwm-vr-gaze-confidence 0.0
        ewwm-vr-gaze-source-active nil
        ewwm-vr-gaze-tracking-p nil
        ewwm-vr-gaze-calibrated-p nil
        ewwm-vr-eye--tracking-active nil
        ewwm-vr-eye--gaze-position nil
        ewwm-vr-eye--dwell-surface nil
        ewwm-vr-eye--dwell-progress 0.0
        ewwm-vr-eye--cooldown-remaining 0
        ewwm-vr-eye--in-saccade nil
        ewwm-vr-eye--in-reading nil
        ewwm-last-focus-method nil
        ewwm-vr-eye--analytics nil))

(provide 'ewwm-vr-eye)
;;; ewwm-vr-eye.el ends here
