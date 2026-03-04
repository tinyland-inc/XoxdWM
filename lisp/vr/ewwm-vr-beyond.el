;;; ewwm-vr-beyond.el --- Bigscreen Beyond 2e headset control  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Controls the Bigscreen Beyond 2e headset via IPC to the ewwm
;; compositor: brightness, fan speed, LED color, display power,
;; and device detection.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-beyond nil
  "Bigscreen Beyond 2e headset settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-beyond-default-brightness 70
  "Default display brightness percentage (0-100)."
  :type 'integer
  :group 'ewwm-vr-beyond)

(defcustom ewwm-vr-beyond-default-fan-speed 60
  "Default fan speed percentage (40-100)."
  :type 'integer
  :group 'ewwm-vr-beyond)

(defcustom ewwm-vr-beyond-led-color '(0 255 128)
  "Default LED color as (R G B), each 0-255."
  :type '(list integer integer integer)
  :group 'ewwm-vr-beyond)

(defcustom ewwm-vr-beyond-auto-power-on t
  "Non-nil to auto power-on the display on session start."
  :type 'boolean
  :group 'ewwm-vr-beyond)

(defcustom ewwm-vr-beyond-mode-line t
  "Non-nil to show Beyond status in the mode line."
  :type 'boolean
  :group 'ewwm-vr-beyond)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-beyond--connected nil
  "Non-nil when a Bigscreen Beyond headset is connected.")

(defvar ewwm-vr-beyond--brightness nil
  "Current brightness percentage, or nil if unknown.")

(defvar ewwm-vr-beyond--fan-speed nil
  "Current fan speed percentage, or nil if unknown.")

(defvar ewwm-vr-beyond--display-powered nil
  "Non-nil when the Beyond display is powered on.")

(defvar ewwm-vr-beyond--serial nil
  "Serial number of the connected Beyond headset, or nil.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-beyond-connected-hook nil
  "Hook run when a Beyond headset is connected.")

(defvar ewwm-vr-beyond-disconnected-hook nil
  "Hook run when a Beyond headset is disconnected.")

;; ── IPC send helper ──────────────────────────────────────────

(defun ewwm-vr-beyond--send (type &rest args)
  "Send a Beyond IPC command of TYPE with ARGS."
  (ewwm-ipc-send (format "(:type \"%s\" %s)" type
                          (mapconcat #'identity args " "))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-beyond--on-status (msg)
  "Handle :beyond-status event MSG.
Updates all internal state from compositor report."
  (let ((brightness (plist-get msg :brightness))
        (fan-speed (plist-get msg :fan-speed))
        (powered (plist-get msg :display-powered))
        (serial (plist-get msg :serial)))
    (when brightness
      (setq ewwm-vr-beyond--brightness brightness))
    (when fan-speed
      (setq ewwm-vr-beyond--fan-speed fan-speed))
    (when powered
      (setq ewwm-vr-beyond--display-powered (eq powered t)))
    (when serial
      (setq ewwm-vr-beyond--serial serial))
    (force-mode-line-update t)))

(defun ewwm-vr-beyond--on-connected (msg)
  "Handle :beyond-connected event MSG."
  (setq ewwm-vr-beyond--connected t
        ewwm-vr-beyond--serial (plist-get msg :serial))
  (message "ewwm-vr-beyond: headset connected%s"
           (if ewwm-vr-beyond--serial
               (format " (S/N: %s)" ewwm-vr-beyond--serial)
             ""))
  (run-hooks 'ewwm-vr-beyond-connected-hook)
  (force-mode-line-update t))

(defun ewwm-vr-beyond--on-disconnected (_msg)
  "Handle :beyond-disconnected event MSG."
  (setq ewwm-vr-beyond--connected nil
        ewwm-vr-beyond--brightness nil
        ewwm-vr-beyond--fan-speed nil
        ewwm-vr-beyond--display-powered nil
        ewwm-vr-beyond--serial nil)
  (message "ewwm-vr-beyond: headset disconnected")
  (run-hooks 'ewwm-vr-beyond-disconnected-hook)
  (force-mode-line-update t))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-beyond-power-on ()
  "Send display power-on sequence to the Beyond headset."
  (interactive)
  (unless ewwm-vr-beyond--connected
    (user-error "No Beyond headset connected"))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send '(:type :beyond-power-on))
    (setq ewwm-vr-beyond--display-powered t)
    (force-mode-line-update t)
    (message "ewwm-vr-beyond: display power-on sent")))

(defun ewwm-vr-beyond-set-brightness (pct)
  "Set Beyond display brightness to PCT (0-100)."
  (interactive "nBrightness (0-100): ")
  (unless (<= 0 pct 100)
    (user-error "Brightness must be 0-100, got %d" pct))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :beyond-set-brightness :value ,pct))
    (setq ewwm-vr-beyond--brightness pct)
    (force-mode-line-update t)
    (message "ewwm-vr-beyond: brightness set to %d%%" pct)))

(defun ewwm-vr-beyond-set-fan-speed (pct)
  "Set Beyond fan speed to PCT (40-100)."
  (interactive "nFan speed (40-100): ")
  (unless (<= 40 pct 100)
    (user-error "Fan speed must be 40-100, got %d" pct))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :beyond-set-fan-speed :value ,pct))
    (setq ewwm-vr-beyond--fan-speed pct)
    (message "ewwm-vr-beyond: fan speed set to %d%%" pct)))

(defun ewwm-vr-beyond-set-led-color (r g b)
  "Set Beyond LED color to R G B (each 0-255).
When called interactively, prompts for each channel."
  (interactive "nRed (0-255): \nnGreen (0-255): \nnBlue (0-255): ")
  (unless (and (<= 0 r 255) (<= 0 g 255) (<= 0 b 255))
    (user-error "RGB values must be 0-255, got (%d %d %d)" r g b))
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :beyond-set-led-color :r ,r :g ,g :b ,b))
    (message "ewwm-vr-beyond: LED color set to (%d %d %d)" r g b)))

(defun ewwm-vr-beyond-status ()
  "Display current Beyond headset status in the minibuffer."
  (interactive)
  (if (not ewwm-vr-beyond--connected)
      (message "ewwm-vr-beyond: no headset connected")
    (message "ewwm-vr-beyond: S/N=%s bright=%s%% fan=%s%% power=%s"
             (or ewwm-vr-beyond--serial "?")
             (or ewwm-vr-beyond--brightness "?")
             (or ewwm-vr-beyond--fan-speed "?")
             (if ewwm-vr-beyond--display-powered "ON" "off"))))

(defun ewwm-vr-beyond-detect ()
  "Scan for a connected Bigscreen Beyond headset."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-beyond: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :beyond-detect))))
          (if (eq (plist-get resp :status) :ok)
              (let ((found (plist-get resp :found)))
                (if (eq found t)
                    (progn
                      (setq ewwm-vr-beyond--connected t
                            ewwm-vr-beyond--serial (plist-get resp :serial))
                      (message "ewwm-vr-beyond: headset detected (S/N: %s)"
                               (or ewwm-vr-beyond--serial "unknown")))
                  (setq ewwm-vr-beyond--connected nil)
                  (message "ewwm-vr-beyond: no headset found")))
            (message "ewwm-vr-beyond: detection failed: %s"
                     (plist-get resp :reason))))
      (error (message "ewwm-vr-beyond: %s" (error-message-string err))))))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-beyond-mode-line-string ()
  "Return mode-line string for Beyond status.
Shows \" BSB[70%]\" when powered, \" BSB[70%!]\" when display off.
Returns nil when not connected or mode-line disabled."
  (when (and ewwm-vr-beyond-mode-line
             ewwm-vr-beyond--connected)
    (format " BSB[%s%%%s]"
            (or ewwm-vr-beyond--brightness "?")
            (if ewwm-vr-beyond--display-powered "" "!"))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-beyond--register-events ()
  "Register Beyond event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:beyond-status       . ewwm-vr-beyond--on-status)
     (:beyond-connected    . ewwm-vr-beyond--on-connected)
     (:beyond-disconnected . ewwm-vr-beyond--on-disconnected))))

;; ── Minor mode ───────────────────────────────────────────────

(define-minor-mode ewwm-vr-beyond-mode
  "Minor mode for Bigscreen Beyond 2e headset control.
Registers IPC event handlers, adds mode-line segment, and
optionally powers on the display on enable."
  :lighter " VR-Beyond"
  :group 'ewwm-vr-beyond
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c b s") #'ewwm-vr-beyond-status)
            (define-key map (kbd "C-c b p") #'ewwm-vr-beyond-power-on)
            (define-key map (kbd "C-c b d") #'ewwm-vr-beyond-detect)
            map)
  (if ewwm-vr-beyond-mode
      (progn
        (ewwm-vr-beyond--register-events)
        (when ewwm-vr-beyond-mode-line
          (add-to-list 'global-mode-string
                       '(:eval (ewwm-vr-beyond-mode-line-string)) t))
        (when (and ewwm-vr-beyond-auto-power-on
                   ewwm-vr-beyond--connected
                   (fboundp 'ewwm-ipc-connected-p)
                   (ewwm-ipc-connected-p))
          (ewwm-vr-beyond-power-on)))
    (setq global-mode-string
          (delete '(:eval (ewwm-vr-beyond-mode-line-string))
                  global-mode-string))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-beyond-init ()
  "Initialize Beyond headset integration.
Registers IPC event handlers and applies defaults."
  (ewwm-vr-beyond--register-events)
  (setq ewwm-vr-beyond--brightness ewwm-vr-beyond-default-brightness
        ewwm-vr-beyond--fan-speed ewwm-vr-beyond-default-fan-speed))

(defun ewwm-vr-beyond-teardown ()
  "Clean up Beyond headset state."
  (setq ewwm-vr-beyond--connected nil
        ewwm-vr-beyond--brightness nil
        ewwm-vr-beyond--fan-speed nil
        ewwm-vr-beyond--display-powered nil
        ewwm-vr-beyond--serial nil))

(provide 'ewwm-vr-beyond)
;;; ewwm-vr-beyond.el ends here
