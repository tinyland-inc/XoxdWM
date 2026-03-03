;;; ewwm-vr-gaze-zone.el --- Gaze zone modifier system  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; 9-region gaze zone system: dwell in corner/edge zones to inject
;; Emacs modifiers (C-x, M-x, C-, M-) hands-free via eye tracking.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-gaze-zone nil
  "Gaze zone modifier settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-gaze-zone-enable t
  "Master switch for gaze zone modifiers."
  :type 'boolean
  :group 'ewwm-vr-gaze-zone)

(defcustom ewwm-vr-gaze-zone-dwell-ms 200
  "Dwell time in milliseconds to activate a zone."
  :type 'integer
  :group 'ewwm-vr-gaze-zone)

(defcustom ewwm-vr-gaze-zone-layout 'default
  "Layout preset for zone-to-modifier mapping.
`default': standard Emacs modifier zones.
`vim-like': Vim-oriented zone bindings.
`spacemacs': Spacemacs-style leader zones.
`custom': use `ewwm-vr-gaze-zone-custom-map'."
  :type '(choice (const default)
                 (const vim-like)
                 (const spacemacs)
                 (const custom))
  :group 'ewwm-vr-gaze-zone)

(defcustom ewwm-vr-gaze-zone-custom-map nil
  "Custom alist of (ZONE-SYMBOL . MODIFIER-STRING) for custom layout.
Zone symbols: top-left, top-right, bottom-left, bottom-right,
top-edge, bottom-edge, left-edge, right-edge, center."
  :type '(alist :key-type symbol :value-type string)
  :group 'ewwm-vr-gaze-zone)

(defcustom ewwm-vr-gaze-zone-overlay-alpha 0.15
  "Overlay opacity for zone visualization (0.0-1.0)."
  :type 'number
  :group 'ewwm-vr-gaze-zone)

;; ── Layout presets ─────────────────────────────────────────────

(defun ewwm-vr-gaze-zone--get-layout ()
  "Return an alist mapping zone symbols to modifier strings.
The mapping is determined by `ewwm-vr-gaze-zone-layout'."
  (cond
   ((eq ewwm-vr-gaze-zone-layout 'default)
    '((top-left     . "C-x")
      (top-right    . "M-x")
      (bottom-left  . "C-")
      (bottom-right . "M-")
      (top-edge     . "scroll-up")
      (bottom-edge  . "scroll-down")
      (left-edge    . "C-b")
      (right-edge   . "C-f")
      (center       . "")))
   ((eq ewwm-vr-gaze-zone-layout 'vim-like)
    '((top-left     . "ESC")
      (top-right    . ":")
      (bottom-left  . "C-w")
      (bottom-right . "C-d")
      (top-edge     . "scroll-up")
      (bottom-edge  . "scroll-down")
      (left-edge    . "C-b")
      (right-edge   . "C-f")
      (center       . "")))
   ((eq ewwm-vr-gaze-zone-layout 'spacemacs)
    '((top-left     . "SPC")
      (top-right    . "M-x")
      (bottom-left  . "C-")
      (bottom-right . "M-")
      (top-edge     . "scroll-up")
      (bottom-edge  . "scroll-down")
      (left-edge    . "C-b")
      (right-edge   . "C-f")
      (center       . "")))
   ((eq ewwm-vr-gaze-zone-layout 'custom)
    (or ewwm-vr-gaze-zone-custom-map
        '((center . ""))))
   (t
    '((center . "")))))

;; ── Internal state ─────────────────────────────────────────────

(defvar ewwm-vr-gaze-zone--active nil
  "Currently active (confirmed) zone symbol, or nil.")

(defvar ewwm-vr-gaze-zone--current nil
  "Zone symbol gaze is currently in, or nil.")

(defvar ewwm-vr-gaze-zone--dwell-progress 0.0
  "Current dwell progress as fraction 0.0 to 1.0.")

(defvar ewwm-vr-gaze-zone--transient-modifier nil
  "Pending modifier string for next keypress, or nil.
Set when a transient modifier zone (\"C-\" or \"M-\") is activated.")

(defvar ewwm-vr-gaze-zone--last-activation-time nil
  "Float-time of last zone activation, for lock timing.")

;; ── Hooks ──────────────────────────────────────────────────────

(defvar ewwm-vr-gaze-zone-activate-hook nil
  "Hook run on zone activation.
Functions receive (ZONE MODIFIER SURFACE-ID).")

;; ── IPC event handlers ────────────────────────────────────────

(defun ewwm-vr-gaze-zone--on-zone-entered (msg)
  "Handle :gaze-zone-entered event MSG.
Updates the current zone being gazed at."
  (when ewwm-vr-gaze-zone-enable
    (let ((zone (plist-get msg :zone)))
      (setq ewwm-vr-gaze-zone--current
            (when zone (intern zone))))))

(defun ewwm-vr-gaze-zone--on-zone-activated (msg)
  "Handle :gaze-zone-activated event MSG.
This is the main handler that injects modifiers or commands."
  (when ewwm-vr-gaze-zone-enable
    (let* ((zone-name (plist-get msg :zone))
           (zone (when zone-name (intern zone-name)))
           (modifier (or (plist-get msg :modifier)
                         (alist-get zone (ewwm-vr-gaze-zone--get-layout))))
           (surface-id (plist-get msg :surface-id)))
      (setq ewwm-vr-gaze-zone--active zone
            ewwm-vr-gaze-zone--last-activation-time (float-time))
      (when modifier
        (cond
         ;; C-x prefix: push into unread-command-events
         ((string= modifier "C-x")
          (push ?\C-x unread-command-events))
         ;; M-x: invoke execute-extended-command
         ((string= modifier "M-x")
          (unless noninteractive
            (call-interactively #'execute-extended-command)))
         ;; Transient C- modifier for next keypress
         ((string= modifier "C-")
          (setq ewwm-vr-gaze-zone--transient-modifier "C-"))
         ;; Transient M- modifier for next keypress
         ((string= modifier "M-")
          (setq ewwm-vr-gaze-zone--transient-modifier "M-"))
         ;; Scroll up
         ((string= modifier "scroll-up")
          (unless noninteractive
            (scroll-down)))
         ;; Scroll down
         ((string= modifier "scroll-down")
          (unless noninteractive
            (scroll-up)))
         ;; Backward char
         ((string= modifier "C-b")
          (unless noninteractive
            (backward-char)))
         ;; Forward char
         ((string= modifier "C-f")
          (unless noninteractive
            (forward-char)))
         ;; ESC: push escape
         ((string= modifier "ESC")
          (push ?\e unread-command-events))
         ;; Colon for vim command mode
         ((string= modifier ":")
          (push ?: unread-command-events))
         ;; C-w
         ((string= modifier "C-w")
          (push ?\C-w unread-command-events))
         ;; C-d
         ((string= modifier "C-d")
          (push ?\C-d unread-command-events))
         ;; SPC for spacemacs leader
         ((string= modifier "SPC")
          (push ?\s unread-command-events))
         ;; Anything else (empty string, unrecognized): no action
         (t nil)))
      ;; Run activation hook
      (run-hook-with-args 'ewwm-vr-gaze-zone-activate-hook
                          zone modifier surface-id))))

(defun ewwm-vr-gaze-zone--on-zone-deactivated (_msg)
  "Handle :gaze-zone-deactivated event _MSG.
Clears the active zone."
  (setq ewwm-vr-gaze-zone--active nil
        ewwm-vr-gaze-zone--dwell-progress 0.0))

(defun ewwm-vr-gaze-zone--on-zone-dwell-progress (msg)
  "Handle :gaze-zone-dwell-progress event MSG.
Updates dwell progress for the current zone."
  (let ((elapsed (plist-get msg :elapsed-ms))
        (threshold (plist-get msg :threshold-ms)))
    (setq ewwm-vr-gaze-zone--dwell-progress
          (if (and elapsed threshold (> threshold 0))
              (min 1.0 (/ (float elapsed) threshold))
            0.0))))

;; ── Interactive commands ──────────────────────────────────────

(defun ewwm-vr-gaze-zone-set-layout (layout)
  "Set the gaze zone LAYOUT preset interactively.
LAYOUT is a symbol: `default', `vim-like', `spacemacs', or `custom'."
  (interactive
   (list (intern (completing-read "Zone layout: "
                                  '("default" "vim-like" "spacemacs" "custom")
                                  nil t))))
  (unless (memq layout '(default vim-like spacemacs custom))
    (error "Invalid zone layout: %s" layout))
  (setq ewwm-vr-gaze-zone-layout layout)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :gaze-zone-set-layout
       :layout ,(symbol-name layout)
       :zones ,(ewwm-vr-gaze-zone--get-layout))))
  (message "ewwm-vr-gaze-zone: layout set to %s" layout))

(defun ewwm-vr-gaze-zone-status ()
  "Display current gaze zone state."
  (interactive)
  (let ((layout (ewwm-vr-gaze-zone--get-layout)))
    (message "ewwm-vr-gaze-zone: layout=%s current=%s active=%s dwell=%.0f%% modifier=%s"
             ewwm-vr-gaze-zone-layout
             (or ewwm-vr-gaze-zone--current "none")
             (or ewwm-vr-gaze-zone--active "none")
             (* ewwm-vr-gaze-zone--dwell-progress 100)
             (or (alist-get ewwm-vr-gaze-zone--active layout)
                 (or ewwm-vr-gaze-zone--transient-modifier "none")))))

;; ── Mode-line ──────────────────────────────────────────────────

(defun ewwm-vr-gaze-zone-mode-line-string ()
  "Return a mode-line string for gaze zone state.
Returns \" [Zone:TL C-x]\" when active, or nil."
  (when (and ewwm-vr-gaze-zone-enable ewwm-vr-gaze-zone--active)
    (let* ((layout (ewwm-vr-gaze-zone--get-layout))
           (modifier (or (alist-get ewwm-vr-gaze-zone--active layout) ""))
           (abbrev (cond
                    ((eq ewwm-vr-gaze-zone--active 'top-left)     "TL")
                    ((eq ewwm-vr-gaze-zone--active 'top-right)    "TR")
                    ((eq ewwm-vr-gaze-zone--active 'bottom-left)  "BL")
                    ((eq ewwm-vr-gaze-zone--active 'bottom-right) "BR")
                    ((eq ewwm-vr-gaze-zone--active 'top-edge)     "TE")
                    ((eq ewwm-vr-gaze-zone--active 'bottom-edge)  "BE")
                    ((eq ewwm-vr-gaze-zone--active 'left-edge)    "LE")
                    ((eq ewwm-vr-gaze-zone--active 'right-edge)   "RE")
                    ((eq ewwm-vr-gaze-zone--active 'center)       "CT")
                    (t "??"))))
      (if (string= modifier "")
          nil
        (format " [Zone:%s %s]" abbrev modifier)))))

;; ── Event registration ────────────────────────────────────────

(defun ewwm-vr-gaze-zone--register-events ()
  "Register gaze zone event handlers with IPC event dispatch.
Idempotent: will not duplicate handlers."
  (ewwm-ipc-register-events
   '((:gaze-zone-entered        . ewwm-vr-gaze-zone--on-zone-entered)
     (:gaze-zone-activated       . ewwm-vr-gaze-zone--on-zone-activated)
     (:gaze-zone-deactivated     . ewwm-vr-gaze-zone--on-zone-deactivated)
     (:gaze-zone-dwell-progress  . ewwm-vr-gaze-zone--on-zone-dwell-progress))))

;; ── Minor mode ─────────────────────────────────────────────────

(define-minor-mode ewwm-vr-gaze-zone-mode
  "Minor mode for gaze zone modifiers."
  :lighter " VR-Zone"
  :group 'ewwm-vr-gaze-zone
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c z l") #'ewwm-vr-gaze-zone-set-layout)
            (define-key map (kbd "C-c z s") #'ewwm-vr-gaze-zone-status)
            map))

;; ── Init / teardown ────────────────────────────────────────────

(defun ewwm-vr-gaze-zone-init ()
  "Initialize gaze zone modifier system."
  (ewwm-vr-gaze-zone--register-events))

(defun ewwm-vr-gaze-zone-teardown ()
  "Clean up gaze zone state."
  (setq ewwm-vr-gaze-zone--active nil
        ewwm-vr-gaze-zone--current nil
        ewwm-vr-gaze-zone--dwell-progress 0.0
        ewwm-vr-gaze-zone--transient-modifier nil
        ewwm-vr-gaze-zone--last-activation-time nil))

(provide 'ewwm-vr-gaze-zone)
;;; ewwm-vr-gaze-zone.el ends here
