;;; ewwm-vr-transient.el --- 3D transient chain management for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Manages transient (popup) window chains in 3D VR space.
;; When a surface spawns a transient child (dialog, menu, tooltip),
;; the compositor positions it at a configurable depth offset in front
;; of the parent.  Chains can nest up to a configurable maximum depth.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-transient nil
  "VR transient chain settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-transient-z-offset 0.1
  "Depth offset per transient level in meters.
Each nested transient is placed this distance closer to the user
than its parent."
  :type 'number
  :group 'ewwm-vr-transient)

(defcustom ewwm-vr-transient-max-depth 5
  "Maximum transient chain depth.
Transient requests beyond this depth are rejected by the compositor."
  :type 'integer
  :group 'ewwm-vr-transient)

(defcustom ewwm-vr-transient-placement "auto"
  "Default placement strategy for transient surfaces.
\"auto\": compositor chooses based on available space.
\"front\": always in front of the parent.
\"above\": above the parent surface.
\"below\": below the parent surface."
  :type '(choice (const :tag "Auto" "auto")
                 (const :tag "Front" "front")
                 (const :tag "Above" "above")
                 (const :tag "Below" "below"))
  :group 'ewwm-vr-transient)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-transient--chains nil
  "Alist of transient parent-child relationships.
Each entry is (PARENT-ID . CHILDREN-PLIST) where CHILDREN-PLIST
has keys: :children (list of surface IDs), :depth (integer).")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-transient--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-transient--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-transient: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-transient--handle-transient-added (msg)
  "Handle :transient-added event MSG from compositor.
Adds the child surface to its parent's chain."
  (let ((parent-id (plist-get msg :parent-id))
        (child-id (plist-get msg :child-id))
        (depth (plist-get msg :depth)))
    (when (and parent-id child-id)
      (let ((entry (assq parent-id ewwm-vr-transient--chains)))
        (if entry
            (let ((children (plist-get (cdr entry) :children)))
              (unless (memq child-id children)
                (setcdr entry (plist-put (cdr entry) :children
                                         (cons child-id children)))
                (when depth
                  (setcdr entry (plist-put (cdr entry) :depth depth)))))
          (push (cons parent-id (list :children (list child-id)
                                      :depth (or depth 1)))
                ewwm-vr-transient--chains))))))

(defun ewwm-vr-transient--handle-transient-removed (msg)
  "Handle :transient-removed event MSG from compositor.
Removes the child surface from its parent's chain."
  (let ((parent-id (plist-get msg :parent-id))
        (child-id (plist-get msg :child-id)))
    (when (and parent-id child-id)
      (let ((entry (assq parent-id ewwm-vr-transient--chains)))
        (when entry
          (let ((children (cl-remove child-id
                                     (plist-get (cdr entry) :children))))
            (if children
                (setcdr entry (plist-put (cdr entry) :children children))
              (setq ewwm-vr-transient--chains
                    (assq-delete-all parent-id
                                     ewwm-vr-transient--chains)))))))))

(defun ewwm-vr-transient--handle-transient-list (msg)
  "Handle :transient-list event MSG from compositor.
Replaces the local chain alist with the compositor's state."
  (let ((chains (plist-get msg :chains)))
    (setq ewwm-vr-transient--chains
          (cl-loop for chain in chains
                   collect (cons (plist-get chain :parent-id)
                                 (list :children (plist-get chain :children)
                                       :depth (plist-get chain :depth)))))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-transient-list ()
  "List all transient chains in a temporary buffer."
  (interactive)
  (ewwm-vr-transient--send '(:type :transient-list))
  (with-current-buffer (get-buffer-create "*ewwm-vr-transients*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Transient Chains (%d)\n"
                      (length ewwm-vr-transient--chains)))
      (insert (make-string 50 ?─) "\n")
      (if (null ewwm-vr-transient--chains)
          (insert "(no transient chains)\n")
        (dolist (entry ewwm-vr-transient--chains)
          (let ((parent (car entry))
                (props (cdr entry)))
            (insert (format "  Parent %-6d  depth=%d  children=%s\n"
                            parent
                            (or (plist-get props :depth) 0)
                            (mapconcat #'number-to-string
                                       (plist-get props :children)
                                       ", ")))))))
    (special-mode)
    (goto-char (point-min))
    (display-buffer (current-buffer))))

(defun ewwm-vr-transient-set-placement (placement)
  "Set default transient PLACEMENT strategy.
PLACEMENT is a string: \"auto\", \"front\", \"above\", or \"below\"."
  (interactive
   (list (completing-read "Transient placement: "
                          '("auto" "front" "above" "below")
                          nil t)))
  (unless (member placement '("auto" "front" "above" "below"))
    (error "Invalid placement: %s" placement))
  (setq ewwm-vr-transient-placement placement)
  (ewwm-vr-transient--send
   `(:type :transient-set-placement :placement ,placement))
  (message "ewwm-vr-transient: placement set to %s" placement))

(defun ewwm-vr-transient-set-offset (offset)
  "Set transient Z OFFSET in meters."
  (interactive "nZ offset (meters): ")
  (let ((clamped (max 0.01 (min 1.0 offset))))
    (setq ewwm-vr-transient-z-offset clamped)
    (ewwm-vr-transient--send
     `(:type :transient-set-offset :z-offset ,clamped))
    (message "ewwm-vr-transient: z-offset set to %.3fm" clamped)))

(defun ewwm-vr-transient-status ()
  "Display transient chain count and configuration."
  (interactive)
  (let ((resp (ewwm-vr-transient--send-sync '(:type :transient-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((info (plist-get resp :transients)))
          (message "ewwm-vr-transient: %d chains, max-depth=%d z-offset=%.3fm placement=%s"
                   (or (plist-get info :chain-count)
                       (length ewwm-vr-transient--chains))
                   ewwm-vr-transient-max-depth
                   ewwm-vr-transient-z-offset
                   ewwm-vr-transient-placement))
      (message "ewwm-vr-transient: %d chains, max-depth=%d z-offset=%.3fm placement=%s (offline)"
               (length ewwm-vr-transient--chains)
               ewwm-vr-transient-max-depth
               ewwm-vr-transient-z-offset
               ewwm-vr-transient-placement))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-transient--register-events ()
  "Register transient chain event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:transient-added   . ewwm-vr-transient--handle-transient-added)
     (:transient-removed . ewwm-vr-transient--handle-transient-removed)
     (:transient-list    . ewwm-vr-transient--handle-transient-list))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-transient-init ()
  "Initialize VR transient chain management.
Registers IPC event handlers and sends initial configuration."
  (ewwm-vr-transient--register-events)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-vr-transient--send
     `(:type :transient-configure
       :z-offset ,ewwm-vr-transient-z-offset
       :max-depth ,ewwm-vr-transient-max-depth
       :placement ,ewwm-vr-transient-placement))))

(defun ewwm-vr-transient-teardown ()
  "Clean up transient chain state."
  (setq ewwm-vr-transient--chains nil))

(provide 'ewwm-vr-transient)
;;; ewwm-vr-transient.el ends here
