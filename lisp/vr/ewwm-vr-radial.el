;;; ewwm-vr-radial.el --- VR radial menu for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Gesture-triggered radial (pie) menu for VR.  The menu appears at the
;; user's hand position and presents a configurable ring of actions.
;; Pointer movement highlights slices; confirmation triggers the
;; associated Emacs command.  Communicates with the compositor's
;; radial_menu subsystem via IPC.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-radial nil
  "VR radial menu settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-radial-items
  '(("workspace-1" . "Workspace 1")
    ("workspace-2" . "Workspace 2")
    ("workspace-3" . "Workspace 3")
    ("workspace-4" . "Workspace 4")
    ("mute-toggle" . "Mute Toggle")
    ("lock"        . "Lock Screen")
    ("screenshot"  . "Screenshot"))
  "Alist of (ID . LABEL) pairs for radial menu items.
Each ID is a string that identifies the action to invoke when the
item is confirmed.  Labels are displayed in the menu ring."
  :type '(alist :key-type string :value-type string)
  :group 'ewwm-vr-radial)

(defcustom ewwm-vr-radial-radius 0.3
  "Radial menu outer radius in meters."
  :type 'number
  :group 'ewwm-vr-radial)

(defcustom ewwm-vr-radial-inner-radius 0.05
  "Radial menu inner dead-zone radius in meters.
Pointer movements within this radius from center are ignored."
  :type 'number
  :group 'ewwm-vr-radial)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-radial--state "hidden"
  "Current radial menu state: hidden, opening, open, closing.")

(defvar ewwm-vr-radial--selected nil
  "Index of the currently highlighted radial menu item, or nil.")

;; ── Action dispatch ──────────────────────────────────────────

(defvar ewwm-vr-radial-action-alist
  '(("workspace-1" . (lambda () (ewwm-workspace-switch 1)))
    ("workspace-2" . (lambda () (ewwm-workspace-switch 2)))
    ("workspace-3" . (lambda () (ewwm-workspace-switch 3)))
    ("workspace-4" . (lambda () (ewwm-workspace-switch 4)))
    ("mute-toggle" . ewwm-vr-radial--action-mute-toggle)
    ("lock"        . lock-screen)
    ("screenshot"  . ewwm-vr-radial--action-screenshot))
  "Alist mapping radial item IDs to functions.
When an item is confirmed in the radial menu, the corresponding
function is called with no arguments.")

(defun ewwm-vr-radial--dispatch-action (item-id)
  "Dispatch the action for ITEM-ID.
Looks up ITEM-ID in `ewwm-vr-radial-action-alist' and calls the
associated function."
  (let ((action (cdr (assoc item-id ewwm-vr-radial-action-alist))))
    (cond
     ((functionp action)
      (funcall action))
     ((and (consp action) (eq (car action) 'lambda))
      (funcall (eval action t)))
     (t
      (message "ewwm-vr-radial: no action for item \"%s\"" item-id)))))

(defun ewwm-vr-radial--action-mute-toggle ()
  "Toggle mute (placeholder)."
  (message "ewwm-vr-radial: mute toggled"))

(defun ewwm-vr-radial--action-screenshot ()
  "Take screenshot (placeholder)."
  (message "ewwm-vr-radial: screenshot taken"))

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-radial--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-radial--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-radial: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-radial--handle-state (msg)
  "Handle :radial-state event MSG from compositor."
  (let ((state (plist-get msg :state))
        (selected (plist-get msg :selected)))
    (when state
      (setq ewwm-vr-radial--state state))
    (setq ewwm-vr-radial--selected selected)))

(defun ewwm-vr-radial--handle-confirmed (msg)
  "Handle :radial-confirmed event MSG from compositor.
Dispatches the action for the confirmed item."
  (let ((item-id (plist-get msg :item-id)))
    (when item-id
      (ewwm-vr-radial--dispatch-action item-id))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-radial-open ()
  "Open the VR radial menu at the current hand position."
  (interactive)
  (ewwm-vr-radial--send '(:type :vr-radial-open))
  (setq ewwm-vr-radial--state "opening")
  (message "ewwm-vr-radial: opening"))

(defun ewwm-vr-radial-close ()
  "Close the VR radial menu."
  (interactive)
  (ewwm-vr-radial--send '(:type :vr-radial-close))
  (setq ewwm-vr-radial--state "closing")
  (message "ewwm-vr-radial: closing"))

(defun ewwm-vr-radial-toggle ()
  "Toggle the VR radial menu open/closed."
  (interactive)
  (ewwm-vr-radial--send '(:type :vr-radial-toggle))
  (message "ewwm-vr-radial: toggled"))

(defun ewwm-vr-radial-configure ()
  "Send radial menu configuration to the compositor.
Pushes the current `ewwm-vr-radial-items', radius, and
inner-radius to the compositor."
  (interactive)
  (let ((items-sexp (mapcar (lambda (pair)
                              (list :id (car pair) :label (cdr pair)))
                            ewwm-vr-radial-items)))
    (ewwm-vr-radial--send
     `(:type :vr-radial-configure
       :items ,items-sexp
       :radius ,ewwm-vr-radial-radius
       :inner-radius ,ewwm-vr-radial-inner-radius)))
  (message "ewwm-vr-radial: configuration sent (%d items, radius=%.2fm)"
           (length ewwm-vr-radial-items)
           ewwm-vr-radial-radius))

(defun ewwm-vr-radial-add-item (id label)
  "Add an item with ID and LABEL to the radial menu."
  (interactive "sItem ID: \nsLabel: ")
  (push (cons id label) ewwm-vr-radial-items)
  (ewwm-vr-radial-configure)
  (message "ewwm-vr-radial: added item \"%s\"" id))

(defun ewwm-vr-radial-remove-item (id)
  "Remove the item with ID from the radial menu."
  (interactive
   (list (completing-read "Remove item: "
                          (mapcar #'car ewwm-vr-radial-items)
                          nil t)))
  (setq ewwm-vr-radial-items
        (cl-remove-if (lambda (pair) (string= (car pair) id))
                      ewwm-vr-radial-items))
  (ewwm-vr-radial-configure)
  (message "ewwm-vr-radial: removed item \"%s\"" id))

(defun ewwm-vr-radial-status ()
  "Display current radial menu state."
  (interactive)
  (let ((resp (ewwm-vr-radial--send-sync '(:type :vr-radial-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((menu (plist-get resp :radial)))
          (message "ewwm-vr-radial: state=%s selected=%s items=%s"
                   (or (plist-get menu :state) ewwm-vr-radial--state)
                   (or (plist-get menu :selected) "none")
                   (or (plist-get menu :item-count) (length ewwm-vr-radial-items))))
      (message "ewwm-vr-radial: state=%s items=%d (offline)"
               ewwm-vr-radial--state
               (length ewwm-vr-radial-items)))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-radial--register-events ()
  "Register radial menu event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:radial-state     . ewwm-vr-radial--handle-state)
     (:radial-confirmed . ewwm-vr-radial--handle-confirmed))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-radial-init ()
  "Initialize VR radial menu.
Registers IPC event handlers and sends initial configuration."
  (ewwm-vr-radial--register-events)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-vr-radial-configure)))

(defun ewwm-vr-radial-teardown ()
  "Clean up VR radial menu state."
  (setq ewwm-vr-radial--state "hidden"
        ewwm-vr-radial--selected nil))

(provide 'ewwm-vr-radial)
;;; ewwm-vr-radial.el ends here
