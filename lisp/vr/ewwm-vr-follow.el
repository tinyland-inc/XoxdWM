;;; ewwm-vr-follow.el --- VR follow mode for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; VR follow mode: surfaces track head position based on configurable
;; policies.  Supports threshold-based repositioning, grab-all mode,
;; recentering, and reading suppression.  Communicates with the
;; compositor's follow subsystem via IPC.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-follow nil
  "VR follow mode settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-follow-policy "threshold-only"
  "Follow mode policy controlling how surfaces track head movement.
\"disabled\": surfaces remain at fixed world positions.
\"focused-only\": only the focused surface follows the head.
\"grab-all\": all surfaces move with the head at all times.
\"threshold-only\": surfaces reposition when head exceeds FOV threshold."
  :type '(choice (const :tag "Disabled" "disabled")
                 (const :tag "Focused only" "focused-only")
                 (const :tag "Grab all" "grab-all")
                 (const :tag "Threshold only" "threshold-only"))
  :group 'ewwm-vr-follow)

(defcustom ewwm-vr-follow-h-fov 80.0
  "Horizontal FOV threshold in degrees.
When head rotation exceeds this angle from a surface, the surface
repositions to face the user."
  :type 'number
  :group 'ewwm-vr-follow)

(defcustom ewwm-vr-follow-v-fov 60.0
  "Vertical FOV threshold in degrees.
When head pitch exceeds this angle from a surface, the surface
repositions vertically."
  :type 'number
  :group 'ewwm-vr-follow)

(defcustom ewwm-vr-follow-speed 0.15
  "Follow speed as a lerp factor (0.0-1.0).
Lower values produce smoother but slower repositioning.
Higher values are more responsive but may feel jarring."
  :type 'number
  :group 'ewwm-vr-follow)

(defcustom ewwm-vr-follow-distance 1.5
  "Default follow distance in meters.
Surfaces reposition to this distance from the user's head."
  :type 'number
  :group 'ewwm-vr-follow)

(defcustom ewwm-vr-follow-suppress-reading t
  "Non-nil to suppress follow repositioning during reading.
When the eye tracker detects a reading pattern, surfaces stay
fixed to avoid disrupting the reading flow."
  :type 'boolean
  :group 'ewwm-vr-follow)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-follow--active-surfaces nil
  "List of surface IDs currently being followed.")

(defvar ewwm-vr-follow--following-p nil
  "Non-nil when follow mode is actively repositioning surfaces.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-follow-policy-hook nil
  "Hook run when follow policy changes.
`ewwm-vr-follow-policy' is set before this hook runs.")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-follow--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-follow--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-follow: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-follow--handle-status (msg)
  "Handle :follow-status event MSG from compositor.
Updates local follow state from compositor report."
  (let ((policy (plist-get msg :policy))
        (surfaces (plist-get msg :surfaces)))
    (when policy
      (setq ewwm-vr-follow-policy policy))
    (when surfaces
      (setq ewwm-vr-follow--active-surfaces surfaces))))

(defun ewwm-vr-follow--handle-following (msg)
  "Handle :follow-following event MSG from compositor.
Tracks whether surfaces are actively being repositioned."
  (let ((active (plist-get msg :active))
        (surfaces (plist-get msg :surfaces)))
    (setq ewwm-vr-follow--following-p (eq active t))
    (when surfaces
      (setq ewwm-vr-follow--active-surfaces surfaces))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-follow-set-policy (policy)
  "Set follow mode POLICY.
POLICY is a string: \"disabled\", \"focused-only\", \"grab-all\",
or \"threshold-only\"."
  (interactive
   (list (completing-read "Follow policy: "
                          '("disabled" "focused-only" "grab-all" "threshold-only")
                          nil t)))
  (unless (member policy '("disabled" "focused-only" "grab-all" "threshold-only"))
    (error "Invalid follow policy: %s" policy))
  (setq ewwm-vr-follow-policy policy)
  (ewwm-vr-follow--send
   `(:type :follow-set-policy :policy ,policy))
  (run-hooks 'ewwm-vr-follow-policy-hook)
  (message "ewwm-vr-follow: policy set to %s" policy))

(defun ewwm-vr-follow-recenter ()
  "Recenter all surfaces to the current head position.
Surfaces snap to their default positions relative to the user."
  (interactive)
  (ewwm-vr-follow--send '(:type :follow-recenter))
  (message "ewwm-vr-follow: recentering all surfaces"))

(defun ewwm-vr-follow-grab-all ()
  "Move all surfaces with the head (grab-all mode).
Equivalent to setting policy to \"grab-all\"."
  (interactive)
  (ewwm-vr-follow-set-policy "grab-all"))

(defun ewwm-vr-follow-toggle ()
  "Toggle follow mode between disabled and threshold-only."
  (interactive)
  (let ((new-policy (if (string= ewwm-vr-follow-policy "disabled")
                        "threshold-only"
                      "disabled")))
    (ewwm-vr-follow-set-policy new-policy)))

(defun ewwm-vr-follow-configure ()
  "Send all follow parameters to the compositor.
Configures FOV thresholds, speed, distance, and reading suppression."
  (interactive)
  (ewwm-vr-follow--send
   `(:type :follow-configure
     :policy ,ewwm-vr-follow-policy
     :h-fov ,ewwm-vr-follow-h-fov
     :v-fov ,ewwm-vr-follow-v-fov
     :speed ,ewwm-vr-follow-speed
     :distance ,ewwm-vr-follow-distance
     :suppress-reading ,(if ewwm-vr-follow-suppress-reading t :false)))
  (message "ewwm-vr-follow: configuration sent (policy=%s h-fov=%.0f v-fov=%.0f speed=%.2f dist=%.1fm)"
           ewwm-vr-follow-policy
           ewwm-vr-follow-h-fov
           ewwm-vr-follow-v-fov
           ewwm-vr-follow-speed
           ewwm-vr-follow-distance))

(defun ewwm-vr-follow-status ()
  "Display current follow mode state."
  (interactive)
  (let ((resp (ewwm-vr-follow--send-sync '(:type :follow-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((follow (plist-get resp :follow)))
          (message "ewwm-vr-follow: policy=%s active=%s surfaces=%s h-fov=%.0f v-fov=%.0f speed=%.2f dist=%.1fm"
                   (or (plist-get follow :policy) ewwm-vr-follow-policy)
                   (if ewwm-vr-follow--following-p "yes" "no")
                   (or (plist-get follow :surface-count) (length ewwm-vr-follow--active-surfaces))
                   ewwm-vr-follow-h-fov
                   ewwm-vr-follow-v-fov
                   ewwm-vr-follow-speed
                   ewwm-vr-follow-distance))
      (message "ewwm-vr-follow: policy=%s active=%s surfaces=%d (offline)"
               ewwm-vr-follow-policy
               (if ewwm-vr-follow--following-p "yes" "no")
               (length ewwm-vr-follow--active-surfaces)))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-follow--register-events ()
  "Register follow mode event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:follow-status    . ewwm-vr-follow--handle-status)
     (:follow-following . ewwm-vr-follow--handle-following))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-follow-init ()
  "Initialize VR follow mode.
Registers IPC event handlers and sends initial configuration."
  (ewwm-vr-follow--register-events)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-vr-follow-configure)))

(defun ewwm-vr-follow-teardown ()
  "Clean up VR follow mode state."
  (setq ewwm-vr-follow--active-surfaces nil
        ewwm-vr-follow--following-p nil))

(provide 'ewwm-vr-follow)
;;; ewwm-vr-follow.el ends here
