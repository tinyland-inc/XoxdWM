;;; ewwm-ext.el --- EWWM extension framework  -*- lexical-binding: t -*-

;;; Commentary:
;; Register, enable, and disable modular extensions with dependency resolution.

;;; Code:

(require 'cl-lib)

(defvar ewwm-ext--registry (make-hash-table :test 'eq)
  "Hash table of registered extensions.  Key: symbol, value: plist.")

(defvar ewwm-ext--enabled nil
  "List of currently enabled extension symbols.")

(defvar ewwm-ext--initialized nil
  "List of extensions whose init-fn has been called.")

(cl-defun ewwm-ext-register (name &key init-fn enable-fn disable-fn deps)
  "Register extension NAME with optional INIT-FN, ENABLE-FN, DISABLE-FN, DEPS."
  (puthash name (list :init-fn init-fn
                      :enable-fn enable-fn
                      :disable-fn disable-fn
                      :deps deps)
           ewwm-ext--registry))

(defun ewwm-ext-list ()
  "Return list of registered extension names."
  (let (exts)
    (maphash (lambda (k _v) (push k exts)) ewwm-ext--registry)
    exts))

(defun ewwm-ext-enabled-p (name)
  "Return non-nil if extension NAME is enabled."
  (memq name ewwm-ext--enabled))

(defun ewwm-ext--resolve-deps (name visited)
  "Resolve dependencies for NAME, detecting cycles via VISITED."
  (when (memq name visited)
    (error "Circular dependency detected: %s" name))
  (let* ((ext (gethash name ewwm-ext--registry))
         (deps (plist-get ext :deps)))
    (dolist (dep deps)
      (unless (ewwm-ext-enabled-p dep)
        (ewwm-ext--resolve-deps dep (cons name visited))
        (ewwm-ext--do-enable dep)))))

(defun ewwm-ext--do-enable (name)
  "Enable extension NAME (internal, no dep resolution)."
  (let ((ext (gethash name ewwm-ext--registry)))
    (unless (memq name ewwm-ext--initialized)
      (when-let ((init (plist-get ext :init-fn)))
        (funcall init))
      (push name ewwm-ext--initialized))
    (when-let ((enable (plist-get ext :enable-fn)))
      (funcall enable))
    (push name ewwm-ext--enabled)))

(defun ewwm-ext-enable (name)
  "Enable extension NAME, resolving dependencies."
  (unless (gethash name ewwm-ext--registry)
    (error "Unknown extension: %s" name))
  (unless (ewwm-ext-enabled-p name)
    (ewwm-ext--resolve-deps name nil)
    (ewwm-ext--do-enable name)))

(defun ewwm-ext-disable (name)
  "Disable extension NAME."
  (when (ewwm-ext-enabled-p name)
    (let ((ext (gethash name ewwm-ext--registry)))
      (when-let ((disable (plist-get ext :disable-fn)))
        (funcall disable)))
    (setq ewwm-ext--enabled (delq name ewwm-ext--enabled))))

(provide 'ewwm-ext)
;;; ewwm-ext.el ends here
