;;; ewwm-vr-overlay.el --- VR overlay management for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; VR overlay management: HUD, notifications, and status bar overlays.
;; Each overlay is a compositor-side layer that can display a Wayland
;; surface at a fixed position in the user's view.  Overlays are
;; independent of the scene graph and render on top of scene content.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-overlay nil
  "VR overlay settings for EWWM."
  :group 'ewwm-vr)

(defcustom ewwm-vr-overlay-max-count 16
  "Maximum number of concurrent VR overlays.
The compositor enforces this limit; creation requests beyond it
are rejected."
  :type 'integer
  :group 'ewwm-vr-overlay)

(defcustom ewwm-vr-overlay-default-alpha 0.9
  "Default alpha transparency for new overlays (0.0-1.0).
0.0 = fully transparent, 1.0 = fully opaque."
  :type 'number
  :group 'ewwm-vr-overlay)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-overlay--layers nil
  "Alist of active overlay layers.
Each entry is (OVERLAY-ID . PLIST) where PLIST has keys:
:type, :width, :height, :alpha, :visible, :surface-id.")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-overlay--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-overlay--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-overlay: %s" (error-message-string err))
       nil))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-overlay--handle-list (msg)
  "Handle :overlay-list event MSG from compositor.
Replaces the local layer alist with the compositor's full list."
  (let ((layers (plist-get msg :layers)))
    (setq ewwm-vr-overlay--layers
          (cl-loop for entry in layers
                   collect (cons (plist-get entry :id) entry)))))

(defun ewwm-vr-overlay--handle-created (msg)
  "Handle :overlay-created event MSG from compositor.
Adds the new overlay to the local layer alist."
  (let ((id (plist-get msg :id)))
    (when id
      (setq ewwm-vr-overlay--layers
            (cons (cons id msg)
                  (assq-delete-all id ewwm-vr-overlay--layers))))))

(defun ewwm-vr-overlay--handle-removed (msg)
  "Handle :overlay-removed event MSG from compositor.
Removes the overlay from the local layer alist."
  (let ((id (plist-get msg :id)))
    (when id
      (setq ewwm-vr-overlay--layers
            (assq-delete-all id ewwm-vr-overlay--layers)))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-overlay-create (type width height alpha)
  "Create a new VR overlay of TYPE with dimensions WIDTH x HEIGHT.
ALPHA is the overlay transparency (0.0-1.0).
TYPE is a string: \"hud\", \"notification\", or \"status-bar\"."
  (interactive
   (list (completing-read "Overlay type: "
                          '("hud" "notification" "status-bar")
                          nil t)
         (read-number "Width (px): " 800)
         (read-number "Height (px): " 400)
         (read-number "Alpha (0.0-1.0): " ewwm-vr-overlay-default-alpha)))
  (when (>= (length ewwm-vr-overlay--layers) ewwm-vr-overlay-max-count)
    (error "Overlay limit reached (%d)" ewwm-vr-overlay-max-count))
  (let ((clamped-alpha (max 0.0 (min 1.0 alpha))))
    (ewwm-vr-overlay--send
     `(:type :overlay-create
       :overlay-type ,type
       :width ,width
       :height ,height
       :alpha ,clamped-alpha))
    (message "ewwm-vr-overlay: creating %s overlay (%dx%d alpha=%.2f)"
             type width height clamped-alpha)))

(defun ewwm-vr-overlay-remove (overlay-id)
  "Remove the overlay identified by OVERLAY-ID."
  (interactive
   (list (let ((ids (mapcar (lambda (entry)
                              (number-to-string (car entry)))
                            ewwm-vr-overlay--layers)))
           (if ids
               (string-to-number
                (completing-read "Remove overlay ID: " ids nil t))
             (error "No overlays active")))))
  (ewwm-vr-overlay--send
   `(:type :overlay-remove :id ,overlay-id))
  (message "ewwm-vr-overlay: removing overlay %d" overlay-id))

(defun ewwm-vr-overlay-list ()
  "List all active VR overlays in a temporary buffer."
  (interactive)
  (ewwm-vr-overlay--send '(:type :overlay-list))
  (with-current-buffer (get-buffer-create "*ewwm-vr-overlays*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "VR Overlays (%d/%d)\n"
                      (length ewwm-vr-overlay--layers)
                      ewwm-vr-overlay-max-count))
      (insert (make-string 40 ?─) "\n")
      (if (null ewwm-vr-overlay--layers)
          (insert "(no overlays)\n")
        (dolist (entry ewwm-vr-overlay--layers)
          (let ((id (car entry))
                (props (cdr entry)))
            (insert (format "  ID %-4d  type=%-14s  %dx%d  alpha=%.2f  visible=%s\n"
                            id
                            (or (plist-get props :overlay-type) "unknown")
                            (or (plist-get props :width) 0)
                            (or (plist-get props :height) 0)
                            (or (plist-get props :alpha) 0.0)
                            (if (plist-get props :visible) "yes" "no")))))))
    (special-mode)
    (goto-char (point-min))
    (display-buffer (current-buffer))))

(defun ewwm-vr-overlay-set-alpha (overlay-id alpha)
  "Set OVERLAY-ID transparency to ALPHA (0.0-1.0)."
  (interactive
   (list (let ((ids (mapcar (lambda (e) (number-to-string (car e)))
                            ewwm-vr-overlay--layers)))
           (if ids
               (string-to-number
                (completing-read "Overlay ID: " ids nil t))
             (error "No overlays active")))
         (read-number "Alpha (0.0-1.0): " ewwm-vr-overlay-default-alpha)))
  (let ((clamped (max 0.0 (min 1.0 alpha))))
    (ewwm-vr-overlay--send
     `(:type :overlay-set-alpha :id ,overlay-id :alpha ,clamped))
    (message "ewwm-vr-overlay: overlay %d alpha set to %.2f"
             overlay-id clamped)))

(defun ewwm-vr-overlay-set-visible (overlay-id visible)
  "Set OVERLAY-ID visibility to VISIBLE (t or nil)."
  (interactive
   (list (let ((ids (mapcar (lambda (e) (number-to-string (car e)))
                            ewwm-vr-overlay--layers)))
           (if ids
               (string-to-number
                (completing-read "Overlay ID: " ids nil t))
             (error "No overlays active")))
         (y-or-n-p "Visible? ")))
  (ewwm-vr-overlay--send
   `(:type :overlay-set-visible
     :id ,overlay-id
     :visible ,(if visible t :false)))
  (message "ewwm-vr-overlay: overlay %d %s"
           overlay-id (if visible "shown" "hidden")))

(defun ewwm-vr-overlay-link-surface (overlay-id surface-id)
  "Link Wayland SURFACE-ID to OVERLAY-ID.
The surface content will be rendered onto the overlay layer."
  (interactive
   (list (let ((ids (mapcar (lambda (e) (number-to-string (car e)))
                            ewwm-vr-overlay--layers)))
           (if ids
               (string-to-number
                (completing-read "Overlay ID: " ids nil t))
             (error "No overlays active")))
         (read-number "Surface ID: ")))
  (ewwm-vr-overlay--send
   `(:type :overlay-link-surface
     :id ,overlay-id
     :surface-id ,surface-id))
  (message "ewwm-vr-overlay: linked surface %d to overlay %d"
           surface-id overlay-id))

(defun ewwm-vr-overlay-status ()
  "Display overlay count and state summary."
  (interactive)
  (let ((resp (ewwm-vr-overlay--send-sync '(:type :overlay-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((info (plist-get resp :overlays)))
          (message "ewwm-vr-overlay: %d/%d overlays, %d visible"
                   (or (plist-get info :count) (length ewwm-vr-overlay--layers))
                   ewwm-vr-overlay-max-count
                   (or (plist-get info :visible-count) 0)))
      (message "ewwm-vr-overlay: %d/%d overlays (offline)"
               (length ewwm-vr-overlay--layers)
               ewwm-vr-overlay-max-count))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-overlay--register-events ()
  "Register overlay event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:overlay-list    . ewwm-vr-overlay--handle-list)
     (:overlay-created . ewwm-vr-overlay--handle-created)
     (:overlay-removed . ewwm-vr-overlay--handle-removed))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-overlay-init ()
  "Initialize VR overlay subsystem.
Registers IPC event handlers and requests the current overlay list."
  (ewwm-vr-overlay--register-events)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-vr-overlay--send '(:type :overlay-list))))

(defun ewwm-vr-overlay-teardown ()
  "Clean up VR overlay state."
  (setq ewwm-vr-overlay--layers nil))

(provide 'ewwm-vr-overlay)
;;; ewwm-vr-overlay.el ends here
