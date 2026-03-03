;;; ewwm-vr-input.el --- VR input handling  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; VR interaction for ewwm: head-gaze ray targeting, pointer events,
;; click/scroll/grab, depth adjustment, follow mode, and calibration.
;; Implements the Xray pattern from the KWin VR MR.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-input nil
  "VR input and interaction settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-gaze-ray-offset '(0.15 -0.10 -0.05)
  "Head-gaze ray origin offset (x y z) in meters from head pose.
Default is right-handed.  For left-handed use (-0.15 -0.10 -0.05)."
  :type '(list number number number)
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-head-scroll-enable t
  "Non-nil to enable head-tilt scrolling."
  :type 'boolean
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-head-scroll-deadzone 5.0
  "Degrees of head tilt before scroll begins."
  :type 'number
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-head-scroll-speed 3.0
  "Scroll speed multiplier."
  :type 'number
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-depth-step 0.2
  "Distance in meters per depth adjustment step."
  :type 'number
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-snap-grid nil
  "Grid spacing for surface placement in meters.
nil to disable snap-to-grid."
  :type '(choice (const nil) number)
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-cursor-scale 3.0
  "Scale factor for cursor in VR."
  :type 'number
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-show-ray t
  "Non-nil to show VR gaze ray line."
  :type 'boolean
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-show-hit-point t
  "Non-nil to show intersection point indicator."
  :type 'boolean
  :group 'ewwm-vr-input)

(defcustom ewwm-vr-emacs-follow-mode 'lazy
  "Follow mode for the primary Emacs surface.
`none': surface stays at fixed position.
`lazy': re-enters FOV after 2 seconds out of view.
`sticky': always within FOV.
`locked': HUD-like, locked to head pose."
  :type '(choice (const none)
                 (const lazy)
                 (const sticky)
                 (const locked))
  :group 'ewwm-vr-input)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-pointer-surface nil
  "Surface ID currently under VR ray, or nil.")

(defvar ewwm-vr-pointer-position nil
  "Cons of (x . y) pixel coordinates on current surface, or nil.")

(defvar ewwm-vr-pointer-distance nil
  "Distance in meters to the surface under the ray, or nil.")

(defvar ewwm-vr-ray-state nil
  "Current ray color state symbol: idle, hovering, grabbing, no-target.")

(defvar ewwm-vr-grab-active nil
  "Non-nil when a surface grab is active.")

(defvar ewwm-vr-input--controllers nil
  "List of active VR controllers.")

(defvar ewwm-vr-input--hand-tracking nil
  "Non-nil when hand tracking is available.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-focus-change-hook nil
  "Hook run when VR ray moves to a different surface.
Functions receive (SURFACE-ID PREV-SURFACE-ID).")

(defvar ewwm-vr-click-hook nil
  "Hook run on VR click.
Functions receive (BUTTON SURFACE-ID X Y).")

(defvar ewwm-vr-grab-start-hook nil
  "Hook run when a surface grab starts.
Functions receive SURFACE-ID.")

(defvar ewwm-vr-grab-end-hook nil
  "Hook run when a surface grab ends.
Functions receive (SURFACE-ID POSITION).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-input--on-pointer (msg)
  "Handle :vr-pointer event MSG."
  (let ((sid (plist-get msg :surface-id))
        (x (plist-get msg :x))
        (y (plist-get msg :y))
        (dist (plist-get msg :distance))
        (ray (plist-get msg :ray)))
    (setq ewwm-vr-pointer-surface sid
          ewwm-vr-pointer-position (when (and x y) (cons x y))
          ewwm-vr-pointer-distance dist
          ewwm-vr-ray-state ray)))

(defun ewwm-vr-input--on-focus-changed (msg)
  "Handle :vr-focus-changed event MSG."
  (let ((sid (plist-get msg :surface-id))
        (prev (plist-get msg :prev-surface-id)))
    (setq ewwm-vr-pointer-surface sid)
    (run-hook-with-args 'ewwm-vr-focus-change-hook sid prev)))

(defun ewwm-vr-input--on-click (msg)
  "Handle :vr-click event MSG."
  (let ((button (plist-get msg :button))
        (sid (plist-get msg :surface-id))
        (x (plist-get msg :x))
        (y (plist-get msg :y)))
    (run-hook-with-args 'ewwm-vr-click-hook button sid x y)))

(defun ewwm-vr-input--on-grab-started (msg)
  "Handle :vr-grab-started event MSG."
  (let ((sid (plist-get msg :surface-id)))
    (setq ewwm-vr-grab-active t)
    (run-hook-with-args 'ewwm-vr-grab-start-hook sid)))

(defun ewwm-vr-input--on-grab-ended (msg)
  "Handle :vr-grab-ended event MSG."
  (let ((sid (plist-get msg :surface-id))
        (pos (plist-get msg :position)))
    (setq ewwm-vr-grab-active nil)
    (run-hook-with-args 'ewwm-vr-grab-end-hook sid pos)))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-click (&optional button)
  "Send a VR click with BUTTON (default `left')."
  (interactive)
  (let ((btn (or button 'left)))
    (when (and (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       `(:type :vr-click :button ,(symbol-name btn))))))

(defun ewwm-vr-right-click ()
  "Send a VR right-click."
  (interactive)
  (ewwm-vr-click 'right))

(defun ewwm-vr-grab ()
  "Start grabbing the surface under the VR ray."
  (interactive)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send '(:type :vr-grab))))

(defun ewwm-vr-grab-release ()
  "Release the currently grabbed surface."
  (interactive)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send '(:type :vr-grab-release))))

(defun ewwm-vr-pull-closer (&optional distance)
  "Pull the targeted surface DISTANCE meters closer (default `ewwm-vr-depth-step')."
  (interactive)
  (let ((delta (round (* (or distance ewwm-vr-depth-step) 100))))
    (when (and ewwm-vr-pointer-surface
               (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       `(:type :vr-adjust-depth
         :surface-id ,ewwm-vr-pointer-surface
         :delta ,delta)))))

(defun ewwm-vr-push-away (&optional distance)
  "Push the targeted surface DISTANCE meters away (default `ewwm-vr-depth-step')."
  (interactive)
  (let ((delta (- (round (* (or distance ewwm-vr-depth-step) 100)))))
    (when (and ewwm-vr-pointer-surface
               (fboundp 'ewwm-ipc-connected-p)
               (ewwm-ipc-connected-p))
      (ewwm-ipc-send
       `(:type :vr-adjust-depth
         :surface-id ,ewwm-vr-pointer-surface
         :delta ,delta)))))

(defun ewwm-vr-set-follow (surface-id mode)
  "Set follow MODE for SURFACE-ID.
MODE is a symbol: `none', `lazy', `sticky', or `locked'."
  (interactive
   (list (read-number "Surface ID: ")
         (intern (completing-read "Follow mode: "
                                  '("none" "lazy" "sticky" "locked")
                                  nil t))))
  (unless (memq mode '(none lazy sticky locked))
    (error "Invalid follow mode: %s" mode))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :vr-set-follow
       :surface-id ,surface-id
       :mode ,(symbol-name mode))))
  (message "ewwm-vr: follow mode for surface %d set to %s" surface-id mode))

(defun ewwm-vr-set-gaze-offset (x y z)
  "Set the gaze ray offset to X Y Z (centimeters)."
  (interactive "nX (cm): \nnY (cm): \nnZ (cm): ")
  (setq ewwm-vr-gaze-ray-offset (list (/ x 100.0) (/ y 100.0) (/ z 100.0)))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :vr-set-gaze-offset :x ,x :y ,y :z ,z)))
  (message "ewwm-vr: gaze offset set to (%.2f, %.2f, %.2f)m"
           (/ x 100.0) (/ y 100.0) (/ z 100.0)))

(defun ewwm-vr-calibrate-gaze ()
  "Start interactive 5-point gaze calibration."
  (interactive)
  (message "ewwm-vr: gaze calibration — look at target 1 of 5, press RET to confirm")
  ;; Calibration proceeds by user pressing RET at each target
  ;; The compositor tracks head pose at each confirmation
  )

(defun ewwm-vr-calibrate-confirm ()
  "Confirm the current calibration point."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :vr-calibrate-confirm))))
          (if (eq (plist-get resp :status) :ok)
              (let ((cal (plist-get resp :calibration)))
                (cond
                 ((eq cal :complete)
                  (message "ewwm-vr: calibration complete! RMS error: %.1f degrees"
                           (or (plist-get resp :rms-error) 0)))
                 ((eq cal :point-recorded)
                  (message "ewwm-vr: point recorded, look at target %d"
                           (1+ (or (plist-get resp :next) 0))))))
            (message "ewwm-vr: calibration error: %s"
                     (plist-get resp :reason))))
      (error (message "ewwm-vr: %s" (error-message-string err))))))

(defun ewwm-vr-pointer-state ()
  "Query and display current VR pointer state."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :vr-pointer-state))))
          (if (eq (plist-get resp :status) :ok)
              (let ((ptr (plist-get resp :pointer)))
                (message "ewwm-vr: surface=%s pos=(%s,%s) dist=%s ray=%s"
                         (or (plist-get ptr :surface-id) "none")
                         (or (plist-get ptr :x) "?")
                         (or (plist-get ptr :y) "?")
                         (or (plist-get ptr :distance) "?")
                         (or (plist-get ptr :ray) "?")))
            (message "ewwm-vr: pointer query failed")))
      (error (message "ewwm-vr: %s" (error-message-string err))))))

(defun ewwm-vr-input-controllers ()
  "Return the list of active controllers."
  ewwm-vr-input--controllers)

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-input-mode-line-string ()
  "Return a mode-line string for VR pointer state."
  (when ewwm-vr-pointer-surface
    (format " [VR:%d]" ewwm-vr-pointer-surface)))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-input--register-events ()
  "Register VR input event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:vr-pointer          . ewwm-vr-input--on-pointer)
     (:vr-focus-changed    . ewwm-vr-input--on-focus-changed)
     (:vr-click            . ewwm-vr-input--on-click)
     (:vr-grab-started     . ewwm-vr-input--on-grab-started)
     (:vr-grab-ended       . ewwm-vr-input--on-grab-ended))))

;; ── Minor mode ───────────────────────────────────────────────

(define-minor-mode ewwm-vr-input-mode
  "Minor mode for VR interaction controls."
  :lighter " VR-Input"
  :group 'ewwm-vr-input
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "RET") #'ewwm-vr-click)
            (define-key map (kbd "S-RET") #'ewwm-vr-right-click)
            map))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-input-init ()
  "Initialize VR input handling."
  (ewwm-vr-input--register-events))

(defun ewwm-vr-input-teardown ()
  "Clean up VR input state."
  (setq ewwm-vr-pointer-surface nil
        ewwm-vr-pointer-position nil
        ewwm-vr-pointer-distance nil
        ewwm-vr-ray-state nil
        ewwm-vr-grab-active nil
        ewwm-vr-input--controllers nil
        ewwm-vr-input--hand-tracking nil))

(provide 'ewwm-vr-input)
;;; ewwm-vr-input.el ends here
