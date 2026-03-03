;;; ewwm-vr-gesture.el --- Gesture recognition for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Hand gesture recognition: pinch, grab, point, swipe.
;; Configurable gesture-to-command binding system.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-gesture nil
  "Gesture recognition settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-gesture-enable t
  "Master switch for gesture recognition."
  :type 'boolean
  :group 'ewwm-vr-gesture)

(defcustom ewwm-vr-gesture-pinch-threshold 0.02
  "Distance threshold in meters for pinch detection."
  :type 'number
  :group 'ewwm-vr-gesture)

(defcustom ewwm-vr-gesture-grab-threshold 0.04
  "Distance threshold in meters for grab detection."
  :type 'number
  :group 'ewwm-vr-gesture)

(defcustom ewwm-vr-gesture-swipe-min-velocity 0.5
  "Minimum velocity in m/s for swipe detection."
  :type 'number
  :group 'ewwm-vr-gesture)

(defcustom ewwm-vr-gesture-debounce-ms 200
  "Debounce time in milliseconds between gestures."
  :type 'integer
  :group 'ewwm-vr-gesture)

(defcustom ewwm-vr-gesture-verbose nil
  "Non-nil to log gesture events to *Messages*."
  :type 'boolean
  :group 'ewwm-vr-gesture)

;; ── Bindings ─────────────────────────────────────────────────

(defvar ewwm-vr-gesture--bindings nil
  "Alist of ((HAND . GESTURE) . COMMAND).
HAND is a symbol (left, right).
GESTURE is a symbol (pinch, grab, point,
swipe-left, swipe-right, swipe-up, swipe-down).
COMMAND is a function to call.")

(defun ewwm-vr-gesture-default-bindings ()
  "Return the default gesture bindings alist."
  (list
   (cons '(right . pinch)       #'ewwm-vr-gesture--default-pinch)
   (cons '(right . grab)        #'ewwm-vr-gesture--default-grab)
   (cons '(left  . swipe-left)  #'previous-buffer)
   (cons '(left  . swipe-right) #'next-buffer)
   (cons '(right . point)       #'ewwm-vr-gesture--default-point)))

(defun ewwm-vr-gesture--default-pinch ()
  "Default pinch action: select/click."
  (message "ewwm-vr-gesture: pinch (select)"))

(defun ewwm-vr-gesture--default-grab ()
  "Default grab action: grab/move."
  (message "ewwm-vr-gesture: grab (move)"))

(defun ewwm-vr-gesture--default-point ()
  "Default point action: aim ray."
  (message "ewwm-vr-gesture: point (aim)"))

(defun ewwm-vr-gesture-bind (hand gesture command)
  "Bind COMMAND to GESTURE on HAND.
HAND is a symbol (left, right).
GESTURE is a symbol (pinch, grab, point, swipe-left, etc.).
COMMAND is a function."
  (let ((key (cons hand gesture)))
    (setq ewwm-vr-gesture--bindings
          (cons (cons key command)
                (cl-remove-if (lambda (entry) (equal (car entry) key))
                              ewwm-vr-gesture--bindings)))))

(defun ewwm-vr-gesture-unbind (hand gesture)
  "Remove binding for GESTURE on HAND."
  (let ((key (cons hand gesture)))
    (setq ewwm-vr-gesture--bindings
          (cl-remove-if (lambda (entry) (equal (car entry) key))
                        ewwm-vr-gesture--bindings))))

(defun ewwm-vr-gesture--lookup (hand gesture)
  "Look up binding for GESTURE on HAND.
Returns the bound function or nil."
  (let ((key (cons hand gesture)))
    (cdr (assoc key ewwm-vr-gesture--bindings))))

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-gesture--last-gesture nil
  "Last recognized gesture as a plist.")

(defvar ewwm-vr-gesture--last-time nil
  "Timestamp of last gesture dispatch.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-gesture-hook nil
  "Hook run after a gesture is dispatched.
Functions receive (HAND GESTURE COMMAND).")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-gesture--on-started (msg)
  "Handle :gesture-started event MSG.
Dispatches the bound command for the gesture."
  (when ewwm-vr-gesture-enable
    (let* ((hand (plist-get msg :hand))
           (gesture (plist-get msg :gesture))
           (cmd (ewwm-vr-gesture--lookup hand gesture)))
      (setq ewwm-vr-gesture--last-gesture msg
            ewwm-vr-gesture--last-time (current-time))
      (when ewwm-vr-gesture-verbose
        (message "ewwm-vr-gesture: %s %s -> %s" hand gesture (or cmd "unbound")))
      (when (functionp cmd)
        (funcall cmd)
        (run-hook-with-args 'ewwm-vr-gesture-hook hand gesture cmd)))))

(defun ewwm-vr-gesture--on-swipe (msg)
  "Handle :gesture-swipe event MSG.
Dispatches swipe direction gestures."
  (when ewwm-vr-gesture-enable
    (let* ((hand (plist-get msg :hand))
           (direction (plist-get msg :direction))
           (gesture (intern (format "swipe-%s" direction)))
           (cmd (ewwm-vr-gesture--lookup hand gesture)))
      (setq ewwm-vr-gesture--last-gesture msg
            ewwm-vr-gesture--last-time (current-time))
      (when ewwm-vr-gesture-verbose
        (message "ewwm-vr-gesture: %s %s -> %s" hand gesture (or cmd "unbound")))
      (when (functionp cmd)
        (funcall cmd)
        (run-hook-with-args 'ewwm-vr-gesture-hook hand gesture cmd)))))

(defun ewwm-vr-gesture--on-ended (_msg)
  "Handle :gesture-ended event _MSG."
  nil)

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-gesture-status ()
  "Display gesture recognition status."
  (interactive)
  (let ((count (length ewwm-vr-gesture--bindings)))
    (message "ewwm-vr-gesture: enabled=%s bindings=%d last=%s"
             (if ewwm-vr-gesture-enable "yes" "no")
             count
             (if ewwm-vr-gesture--last-gesture
                 (format "%s/%s"
                         (plist-get ewwm-vr-gesture--last-gesture :hand)
                         (plist-get ewwm-vr-gesture--last-gesture :gesture))
               "none"))))

(defun ewwm-vr-gesture-toggle ()
  "Toggle gesture recognition on or off."
  (interactive)
  (setq ewwm-vr-gesture-enable (not ewwm-vr-gesture-enable))
  (message "ewwm-vr-gesture: %s"
           (if ewwm-vr-gesture-enable "enabled" "disabled")))

(defun ewwm-vr-gesture-list-bindings ()
  "List current gesture bindings."
  (interactive)
  (if (null ewwm-vr-gesture--bindings)
      (message "ewwm-vr-gesture: no bindings configured")
    (let ((lines nil))
      (dolist (entry ewwm-vr-gesture--bindings)
        (let* ((key (car entry))
               (cmd (cdr entry)))
          (push (format "  %s/%s -> %s" (car key) (cdr key) cmd) lines)))
      (message "ewwm-vr-gesture bindings:\n%s"
               (mapconcat #'identity (nreverse lines) "\n")))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-gesture--register-events ()
  "Register gesture event handlers with IPC dispatch.
Idempotent: checks before adding each handler."
  (ewwm-ipc-register-events
   '((:gesture-started . ewwm-vr-gesture--on-started)
     (:gesture-swipe   . ewwm-vr-gesture--on-swipe)
     (:gesture-ended   . ewwm-vr-gesture--on-ended))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-gesture-init ()
  "Initialize gesture recognition.
Populates default bindings and registers IPC events."
  (ewwm-vr-gesture--register-events)
  (unless ewwm-vr-gesture--bindings
    (setq ewwm-vr-gesture--bindings (ewwm-vr-gesture-default-bindings))))

(defun ewwm-vr-gesture-teardown ()
  "Clean up gesture state."
  (setq ewwm-vr-gesture--last-gesture nil
        ewwm-vr-gesture--last-time nil))

(provide 'ewwm-vr-gesture)
;;; ewwm-vr-gesture.el ends here
