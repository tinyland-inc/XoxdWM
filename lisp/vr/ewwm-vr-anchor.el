;;; ewwm-vr-anchor.el --- Spatial anchors for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Spatial anchors pin Wayland surfaces to physical world positions.
;; Anchors persist across VR sessions via a JSON file, allowing
;; window arrangements to survive restarts.  Each anchor binds a
;; surface to a named 6-DOF pose (position + rotation quaternion).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-anchor nil
  "Spatial anchor settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-anchor-persist-file
  (expand-file-name "anchors.json" "~/.config/exwm-vr/")
  "File path for persisting spatial anchors across sessions.
Anchors are stored as JSON."
  :type 'file
  :group 'ewwm-vr-anchor)

(defcustom ewwm-vr-anchor-auto-restore t
  "Non-nil to automatically restore anchors on VR session start.
When enabled, `ewwm-vr-anchor-restore' runs during init if the
persist file exists."
  :type 'boolean
  :group 'ewwm-vr-anchor)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-anchor--anchors nil
  "Alist of spatial anchors.
Each entry is (NAME . PLIST) where PLIST has keys:
:surface-id, :position (X Y Z), :rotation (X Y Z W).")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-anchor--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-anchor--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-anchor: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-anchor--handle-anchor-created (msg)
  "Handle :anchor-created event MSG from compositor.
Adds or updates the anchor in the local alist."
  (let ((name (plist-get msg :name)))
    (when name
      (setq ewwm-vr-anchor--anchors
            (cons (cons name msg)
                  (cl-remove name ewwm-vr-anchor--anchors
                             :key #'car :test #'equal))))))

(defun ewwm-vr-anchor--handle-anchor-removed (msg)
  "Handle :anchor-removed event MSG from compositor.
Removes the anchor from the local alist."
  (let ((name (plist-get msg :name)))
    (when name
      (setq ewwm-vr-anchor--anchors
            (cl-remove name ewwm-vr-anchor--anchors
                       :key #'car :test #'equal)))))

(defun ewwm-vr-anchor--handle-anchor-list (msg)
  "Handle :anchor-list event MSG from compositor.
Replaces the local alist with the compositor's full anchor set."
  (let ((anchors (plist-get msg :anchors)))
    (setq ewwm-vr-anchor--anchors
          (cl-loop for entry in anchors
                   collect (cons (plist-get entry :name) entry)))))

;; ── Persistence ─────────────────────────────────────────────

(defun ewwm-vr-anchor--anchors-to-json ()
  "Serialize `ewwm-vr-anchor--anchors' to a JSON string."
  (json-encode
   (cl-loop for (name . props) in ewwm-vr-anchor--anchors
            collect `((name . ,name)
                      (surface-id . ,(plist-get props :surface-id))
                      (position . ,(plist-get props :position))
                      (rotation . ,(plist-get props :rotation))))))

(defun ewwm-vr-anchor--json-to-anchors (json-str)
  "Deserialize JSON-STR into an anchor alist."
  (let ((entries (json-read-from-string json-str)))
    (cl-loop for entry across entries
             collect (let-alist entry
                       (cons .name
                             (list :name .name
                                   :surface-id .surface-id
                                   :position .position
                                   :rotation .rotation))))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-anchor-create (name surface-id)
  "Create a spatial anchor NAME for SURFACE-ID at its current position.
The compositor records the surface's current 6-DOF pose."
  (interactive
   (list (read-string "Anchor name: ")
         (read-number "Surface ID: ")))
  (when (string-empty-p name)
    (error "Anchor name cannot be empty"))
  (ewwm-vr-anchor--send
   `(:type :anchor-create
     :name ,name
     :surface-id ,surface-id))
  (message "ewwm-vr-anchor: creating anchor \"%s\" for surface %d"
           name surface-id))

(defun ewwm-vr-anchor-remove (name)
  "Remove the spatial anchor named NAME."
  (interactive
   (list (let ((names (mapcar #'car ewwm-vr-anchor--anchors)))
           (if names
               (completing-read "Remove anchor: " names nil t)
             (error "No anchors defined")))))
  (ewwm-vr-anchor--send
   `(:type :anchor-remove :name ,name))
  (message "ewwm-vr-anchor: removing anchor \"%s\"" name))

(defun ewwm-vr-anchor-list ()
  "List all spatial anchors in a temporary buffer."
  (interactive)
  (ewwm-vr-anchor--send '(:type :anchor-list))
  (with-current-buffer (get-buffer-create "*ewwm-vr-anchors*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Spatial Anchors (%d)\n"
                      (length ewwm-vr-anchor--anchors)))
      (insert (make-string 50 ?─) "\n")
      (if (null ewwm-vr-anchor--anchors)
          (insert "(no anchors)\n")
        (dolist (entry ewwm-vr-anchor--anchors)
          (let ((name (car entry))
                (props (cdr entry)))
            (let ((pos (plist-get props :position))
                  (rot (plist-get props :rotation)))
              (insert (format "  %-20s  surface=%-4s  pos=(%s)  rot=(%s)\n"
                              name
                              (or (plist-get props :surface-id) "-")
                              (if pos
                                  (mapconcat (lambda (v) (format "%.2f" v))
                                             (append pos nil) ", ")
                                "-, -, -")
                              (if rot
                                  (mapconcat (lambda (v) (format "%.2f" v))
                                             (append rot nil) ", ")
                                "-, -, -, -"))))))))
    (special-mode)
    (goto-char (point-min))
    (display-buffer (current-buffer))))

(defun ewwm-vr-anchor-save ()
  "Save current anchors to `ewwm-vr-anchor-persist-file'."
  (interactive)
  (let ((dir (file-name-directory ewwm-vr-anchor-persist-file)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (with-temp-file ewwm-vr-anchor-persist-file
      (insert (ewwm-vr-anchor--anchors-to-json)))
    (message "ewwm-vr-anchor: saved %d anchors to %s"
             (length ewwm-vr-anchor--anchors)
             ewwm-vr-anchor-persist-file)))

(defun ewwm-vr-anchor-restore ()
  "Restore anchors from `ewwm-vr-anchor-persist-file'.
Sends each restored anchor to the compositor."
  (interactive)
  (if (not (file-exists-p ewwm-vr-anchor-persist-file))
      (message "ewwm-vr-anchor: no persist file at %s"
               ewwm-vr-anchor-persist-file)
    (condition-case err
        (let* ((json-str (with-temp-buffer
                           (insert-file-contents ewwm-vr-anchor-persist-file)
                           (buffer-string)))
               (anchors (ewwm-vr-anchor--json-to-anchors json-str)))
          (setq ewwm-vr-anchor--anchors anchors)
          (dolist (entry anchors)
            (let ((props (cdr entry)))
              (ewwm-vr-anchor--send
               `(:type :anchor-restore
                 :name ,(plist-get props :name)
                 :surface-id ,(plist-get props :surface-id)
                 :position ,(plist-get props :position)
                 :rotation ,(plist-get props :rotation)))))
          (message "ewwm-vr-anchor: restored %d anchors" (length anchors)))
      (error
       (message "ewwm-vr-anchor: restore failed: %s"
                (error-message-string err))))))

(defun ewwm-vr-anchor-goto (name)
  "Move the user's view to face the anchor named NAME."
  (interactive
   (list (let ((names (mapcar #'car ewwm-vr-anchor--anchors)))
           (if names
               (completing-read "Go to anchor: " names nil t)
             (error "No anchors defined")))))
  (ewwm-vr-anchor--send
   `(:type :anchor-goto :name ,name))
  (message "ewwm-vr-anchor: moving view to \"%s\"" name))

(defun ewwm-vr-anchor-status ()
  "Display spatial anchor count."
  (interactive)
  (let ((resp (ewwm-vr-anchor--send-sync '(:type :anchor-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (message "ewwm-vr-anchor: %d anchors (compositor)"
                 (or (plist-get resp :count) (length ewwm-vr-anchor--anchors)))
      (message "ewwm-vr-anchor: %d anchors (offline)"
               (length ewwm-vr-anchor--anchors)))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-anchor--register-events ()
  "Register anchor event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:anchor-created . ewwm-vr-anchor--handle-anchor-created)
     (:anchor-removed . ewwm-vr-anchor--handle-anchor-removed)
     (:anchor-list    . ewwm-vr-anchor--handle-anchor-list))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-anchor-init ()
  "Initialize spatial anchor subsystem.
Registers IPC events and optionally restores saved anchors."
  (ewwm-vr-anchor--register-events)
  (when (and ewwm-vr-anchor-auto-restore
             (file-exists-p ewwm-vr-anchor-persist-file)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-vr-anchor-restore)))

(defun ewwm-vr-anchor-teardown ()
  "Clean up spatial anchor state."
  (setq ewwm-vr-anchor--anchors nil))

(provide 'ewwm-vr-anchor)
;;; ewwm-vr-anchor.el ends here
