;;; ewwm-output.el --- Output/display management for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Manages compositor outputs (monitors/displays): listing, enabling,
;; disabling, scaling, positioning, and resolution configuration.
;; Communicates with the compositor's output management handler via IPC.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-output nil
  "Output/display management for EWWM."
  :group 'ewwm
  :prefix "ewwm-output-")

(defcustom ewwm-output-default-scale 1.0
  "Default scale factor for new outputs."
  :type 'float
  :group 'ewwm-output)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-output--configurations nil
  "Alist of output configurations from the compositor.
Each element is (NAME . PLIST) where PLIST contains
:enabled, :width, :height, :x, :y, :scale, :refresh,
:make, :model, :modes.")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-output--handle-list (msg)
  "Handle :output-list-response event MSG.
Populates `ewwm-output--configurations' from the response."
  (let ((outputs (plist-get msg :outputs)))
    (setq ewwm-output--configurations nil)
    (dolist (out outputs)
      (let ((name (plist-get out :name)))
        (when name
          (push (cons name out) ewwm-output--configurations))))
    (setq ewwm-output--configurations
          (nreverse ewwm-output--configurations))))

(defun ewwm-output--handle-configured (msg)
  "Handle :output-configured event MSG.
Updates the matching entry in `ewwm-output--configurations'."
  (let ((name (plist-get msg :name)))
    (when name
      ;; Replace existing entry or add new
      (setf (alist-get name ewwm-output--configurations nil nil #'string=)
            msg)
      (message "ewwm-output: %s configured" name))))

;; ── Interactive commands ─────────────────────────────────────

(defun ewwm-output-list ()
  "Request output list from compositor and display in a buffer."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-output: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :output-list))))
          (if (eq (plist-get resp :status) :ok)
              (progn
                (ewwm-output--handle-list resp)
                (ewwm-output--display-buffer))
            (message "ewwm-output: query failed: %s"
                     (plist-get resp :reason))))
      (error (message "ewwm-output: %s" (error-message-string err))))))

(defun ewwm-output--display-buffer ()
  "Format output info nicely in *ewwm-outputs* buffer."
  (let ((buf (get-buffer-create "*ewwm-outputs*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "EWWM Output Configuration\n")
        (insert (make-string 40 ?=) "\n\n")
        (if (null ewwm-output--configurations)
            (insert "  No outputs detected.\n")
          (dolist (entry ewwm-output--configurations)
            (let* ((name (car entry))
                   (cfg (cdr entry))
                   (enabled (plist-get cfg :enabled))
                   (width (plist-get cfg :width))
                   (height (plist-get cfg :height))
                   (x (plist-get cfg :x))
                   (y (plist-get cfg :y))
                   (scale (plist-get cfg :scale))
                   (refresh (plist-get cfg :refresh))
                   (make (plist-get cfg :make))
                   (model (plist-get cfg :model)))
              (insert (format "  %s%s\n"
                              name
                              (if (eq enabled nil) " [disabled]" "")))
              (when (or make model)
                (insert (format "    Make/Model: %s %s\n"
                                (or make "?") (or model ""))))
              (when (and width height)
                (insert (format "    Resolution: %dx%d" width height))
                (when refresh
                  (insert (format " @ %.2fHz" (if (numberp refresh) refresh 0.0))))
                (insert "\n"))
              (when (and x y)
                (insert (format "    Position:   %d,%d\n" x y)))
              (when scale
                (insert (format "    Scale:      %.2f\n" (if (numberp scale) scale 1.0))))
              (insert "\n"))))
        (insert "[Press q to close]\n"))
      (goto-char (point-min))
      (special-mode))
    (display-buffer buf)))

(defun ewwm-output--read-output-name (prompt)
  "Read an output name with completion using PROMPT.
Falls back to manual input if no outputs are cached."
  (if ewwm-output--configurations
      (completing-read prompt
                       (mapcar #'car ewwm-output--configurations)
                       nil t)
    (read-string prompt)))

(defun ewwm-output-configure (name &optional width height scale x y)
  "Configure output NAME with optional WIDTH, HEIGHT, SCALE, X, Y.
Prompts interactively for the output name and parameters."
  (interactive
   (let* ((name (ewwm-output--read-output-name "Output name: "))
          (width (read-number "Width (0 to skip): " 0))
          (height (read-number "Height (0 to skip): " 0))
          (scale (read-number "Scale (0 to skip): " 0))
          (x (read-number "X position (0 to skip): " 0))
          (y (read-number "Y position (0 to skip): " 0)))
     (list name
           (if (> width 0) width nil)
           (if (> height 0) height nil)
           (if (> scale 0) scale nil)
           (if (/= x 0) x nil)
           (if (/= y 0) y nil))))
  (let ((cmd `(:type :output-configure :name ,name)))
    (when width  (setq cmd (plist-put cmd :width width)))
    (when height (setq cmd (plist-put cmd :height height)))
    (when scale  (setq cmd (plist-put cmd :scale scale)))
    (when x      (setq cmd (plist-put cmd :x x)))
    (when y      (setq cmd (plist-put cmd :y y)))
    (if (not (and (fboundp 'ewwm-ipc-connected-p)
                  (ewwm-ipc-connected-p)))
        (message "ewwm-output: IPC not connected")
      (ewwm-ipc-send cmd)
      (message "ewwm-output: configure sent for %s" name))))

(defun ewwm-output-enable (name)
  "Enable the output named NAME."
  (interactive (list (ewwm-output--read-output-name "Enable output: ")))
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-output: IPC not connected")
    (ewwm-ipc-send `(:type :output-configure :name ,name :enabled t))
    (message "ewwm-output: enabling %s" name)))

(defun ewwm-output-disable (name)
  "Disable the output named NAME."
  (interactive (list (ewwm-output--read-output-name "Disable output: ")))
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-output: IPC not connected")
    (ewwm-ipc-send `(:type :output-configure :name ,name :enabled nil))
    (message "ewwm-output: disabling %s" name)))

(defun ewwm-output-set-scale (name scale)
  "Set SCALE factor for output NAME."
  (interactive
   (list (ewwm-output--read-output-name "Output: ")
         (read-number "Scale factor: " ewwm-output-default-scale)))
  (unless (> scale 0)
    (error "Scale factor must be positive"))
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-output: IPC not connected")
    (ewwm-ipc-send `(:type :output-configure :name ,name :scale ,scale))
    (message "ewwm-output: scale for %s set to %.2f" name scale)))

(defun ewwm-output-set-position (name x y)
  "Set position (X, Y) for output NAME."
  (interactive
   (list (ewwm-output--read-output-name "Output: ")
         (read-number "X position: " 0)
         (read-number "Y position: " 0)))
  (if (not (and (fboundp 'ewwm-ipc-connected-p)
                (ewwm-ipc-connected-p)))
      (message "ewwm-output: IPC not connected")
    (ewwm-ipc-send `(:type :output-configure :name ,name :x ,x :y ,y))
    (message "ewwm-output: position for %s set to %d,%d" name x y)))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-output--register-events ()
  "Register output event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:output-list-response . ewwm-output--handle-list)
     (:output-configured    . ewwm-output--handle-configured))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-output-init ()
  "Initialize output management.
Registers IPC event handlers."
  (ewwm-output--register-events))

(defun ewwm-output-teardown ()
  "Clean up output management state."
  (setq ewwm-output--configurations nil))

(provide 'ewwm-output)
;;; ewwm-output.el ends here
