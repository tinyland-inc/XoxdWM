;;; ewwm-vr-keyboard.el --- VR virtual keyboard for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Virtual keyboard for VR text input: layout selection, text insertion,
;; auto-show on focus, auto-capitalize, and predictive text stubs.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-keyboard nil
  "VR virtual keyboard settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-keyboard-layout 'qwerty
  "Keyboard layout.
Supported: `qwerty', `dvorak', `colemak'."
  :type '(choice (const qwerty) (const dvorak) (const colemak))
  :group 'ewwm-vr-keyboard)

(defcustom ewwm-vr-keyboard-key-size 0.03
  "Key size in meters for the virtual keyboard."
  :type 'number
  :group 'ewwm-vr-keyboard)

(defcustom ewwm-vr-keyboard-haptic t
  "Non-nil to enable haptic feedback on key press."
  :type 'boolean
  :group 'ewwm-vr-keyboard)

(defcustom ewwm-vr-keyboard-auto-show nil
  "Non-nil to auto-show keyboard when text input gains focus."
  :type 'boolean
  :group 'ewwm-vr-keyboard)

(defcustom ewwm-vr-keyboard-auto-capitalize t
  "Non-nil to auto-capitalize after sentence-ending punctuation."
  :type 'boolean
  :group 'ewwm-vr-keyboard)

(defcustom ewwm-vr-keyboard-prediction nil
  "Non-nil to enable predictive text."
  :type 'boolean
  :group 'ewwm-vr-keyboard)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-keyboard--visible nil
  "Non-nil when the virtual keyboard is visible.")

(defvar ewwm-vr-keyboard--current-layout 'qwerty
  "Currently active layout symbol.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-keyboard-show-hook nil
  "Hook run when the virtual keyboard becomes visible.")

(defvar ewwm-vr-keyboard-hide-hook nil
  "Hook run when the virtual keyboard is hidden.")

;; ── Text insertion ──────────────────────────────────────────

(defun ewwm-vr-keyboard--insert-text (text)
  "Insert TEXT at point in the current buffer."
  (when (and text (stringp text) (> (length text) 0))
    (insert text)))

(defun ewwm-vr-keyboard--handle-special (key)
  "Handle special KEY events.
KEY is a symbol: `backspace', `return', `tab', `escape'."
  (cond
   ((eq key 'backspace)
    (when (> (point) (point-min))
      (delete-char -1)))
   ((eq key 'return)
    (newline))
   ((eq key 'tab)
    (insert "\t"))
   ((eq key 'escape)
    (keyboard-quit))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-keyboard--on-text-input (msg)
  "Handle :keyboard-text-input event MSG.
Inserts the text from the event into the current buffer."
  (let ((text (plist-get msg :text)))
    (ewwm-vr-keyboard--insert-text text)))

(defun ewwm-vr-keyboard--on-special-key (msg)
  "Handle :keyboard-special-key event MSG."
  (let ((key (plist-get msg :key)))
    (when key
      (ewwm-vr-keyboard--handle-special
       (if (stringp key) (intern key) key)))))

(defun ewwm-vr-keyboard--on-visibility-changed (msg)
  "Handle :keyboard-visibility event MSG.
Updates the internal visibility state."
  (let ((visible (plist-get msg :visible)))
    (setq ewwm-vr-keyboard--visible visible)
    (if visible
        (run-hooks 'ewwm-vr-keyboard-show-hook)
      (run-hooks 'ewwm-vr-keyboard-hide-hook))))

(defun ewwm-vr-keyboard--on-layout-changed (msg)
  "Handle :keyboard-layout-changed event MSG."
  (let ((layout (plist-get msg :layout)))
    (when layout
      (setq ewwm-vr-keyboard--current-layout
            (if (stringp layout) (intern layout) layout)))))

;; ── Mode-line ────────────────────────────────────────────────

(defun ewwm-vr-keyboard-mode-line-string ()
  "Return a mode-line string for keyboard state.
Returns \" [KB]\" when visible, nil when hidden."
  (when ewwm-vr-keyboard--visible
    " [KB]"))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-keyboard-show ()
  "Show the virtual keyboard."
  (interactive)
  (setq ewwm-vr-keyboard--visible t)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send '(:type :keyboard-show)))
  (run-hooks 'ewwm-vr-keyboard-show-hook)
  (message "ewwm-vr-keyboard: shown"))

(defun ewwm-vr-keyboard-hide ()
  "Hide the virtual keyboard."
  (interactive)
  (setq ewwm-vr-keyboard--visible nil)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send '(:type :keyboard-hide)))
  (run-hooks 'ewwm-vr-keyboard-hide-hook)
  (message "ewwm-vr-keyboard: hidden"))

(defun ewwm-vr-keyboard-toggle ()
  "Toggle the virtual keyboard."
  (interactive)
  (if ewwm-vr-keyboard--visible
      (ewwm-vr-keyboard-hide)
    (ewwm-vr-keyboard-show)))

(defun ewwm-vr-keyboard-set-layout (layout)
  "Set the keyboard LAYOUT.
LAYOUT is a symbol: `qwerty', `dvorak', or `colemak'."
  (interactive
   (list (intern (completing-read "Layout: "
                                  '("qwerty" "dvorak" "colemak")
                                  nil t))))
  (unless (memq layout '(qwerty dvorak colemak))
    (error "Invalid keyboard layout: %s" layout))
  (setq ewwm-vr-keyboard--current-layout layout
        ewwm-vr-keyboard-layout layout)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :keyboard-layout :layout ,(symbol-name layout))))
  (message "ewwm-vr-keyboard: layout set to %s" layout))

(defun ewwm-vr-keyboard-status ()
  "Display virtual keyboard status."
  (interactive)
  (message "ewwm-vr-keyboard: visible=%s layout=%s haptic=%s auto-show=%s"
           (if ewwm-vr-keyboard--visible "yes" "no")
           ewwm-vr-keyboard--current-layout
           (if ewwm-vr-keyboard-haptic "yes" "no")
           (if ewwm-vr-keyboard-auto-show "yes" "no")))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-keyboard--register-events ()
  "Register keyboard event handlers with IPC dispatch."
  (ewwm-ipc-register-events
   '((:keyboard-text-input      . ewwm-vr-keyboard--on-text-input)
     (:keyboard-special-key     . ewwm-vr-keyboard--on-special-key)
     (:keyboard-visibility      . ewwm-vr-keyboard--on-visibility-changed)
     (:keyboard-layout-changed  . ewwm-vr-keyboard--on-layout-changed))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-keyboard-init ()
  "Initialize virtual keyboard."
  (ewwm-vr-keyboard--register-events)
  (setq ewwm-vr-keyboard--current-layout ewwm-vr-keyboard-layout))

(defun ewwm-vr-keyboard-teardown ()
  "Clean up virtual keyboard state."
  (setq ewwm-vr-keyboard--visible nil))

(provide 'ewwm-vr-keyboard)
;;; ewwm-vr-keyboard.el ends here
