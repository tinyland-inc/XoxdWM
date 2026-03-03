;;; ewwm-environment.el --- Environment validation for EXWM-VR  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 EXWM-VR contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Validates that all required environment variables, paths, and
;; runtime dependencies are correctly configured for EXWM-VR.

;;; Code:

(require 'ewwm-core)

(declare-function ewwm-ipc--send "ewwm-ipc")

(defgroup ewwm-environment nil
  "Environment validation for EXWM-VR."
  :group 'ewwm
  :prefix "ewwm-environment-")

(defcustom ewwm-environment-compositor-path "/usr/bin/ewwm-compositor"
  "Path to the EXWM-VR compositor binary."
  :type 'string
  :group 'ewwm-environment)

(defcustom ewwm-environment-monado-json "/etc/xdg/openxr/1/active_runtime.json"
  "Path to OpenXR active runtime JSON."
  :type 'string
  :group 'ewwm-environment)

(defcustom ewwm-environment-brainflow-board-ids
  '(("cyton" . 0) ("cyton-daisy" . 2) ("synthetic" . -1))
  "Mapping of BCI device names to BrainFlow board IDs."
  :type '(alist :key-type string :value-type integer)
  :group 'ewwm-environment)

;; Internal state
(defvar ewwm-environment--check-results nil
  "Results from the last environment check.")

(defun ewwm-environment--check-env-var (name &optional required)
  "Check if environment variable NAME is set.
If REQUIRED is non-nil, report failure if missing.
Returns (NAME status value-or-message)."
  (let ((val (getenv name)))
    (cond
     (val (list name 'ok val))
     (required (list name 'error (format "Required variable %s is not set" name)))
     (t (list name 'warn (format "Optional variable %s is not set" name))))))

(defun ewwm-environment--check-path (path description &optional required)
  "Check if PATH exists.
DESCRIPTION is a human-readable label.  If REQUIRED, report error if missing.
Returns (description status message)."
  (cond
   ((file-exists-p path)
    (list description 'ok path))
   (required
    (list description 'error (format "%s not found: %s" description path)))
   (t
    (list description 'warn (format "%s not found (optional): %s" description path)))))

(defun ewwm-environment--check-executable (name &optional required)
  "Check if executable NAME is in PATH.
Returns (name status message)."
  (let ((path (executable-find name)))
    (cond
     (path (list name 'ok path))
     (required (list name 'error (format "Required executable %s not found in PATH" name)))
     (t (list name 'warn (format "Optional executable %s not found in PATH" name))))))

(defun ewwm-environment--check-wayland ()
  "Check Wayland session readiness.
Returns list of check results."
  (let (results)
    (push (ewwm-environment--check-env-var "WAYLAND_DISPLAY" t) results)
    (push (ewwm-environment--check-env-var "XDG_RUNTIME_DIR" t) results)
    (let ((xdg (getenv "XDG_RUNTIME_DIR"))
          (wl (getenv "WAYLAND_DISPLAY")))
      (when (and xdg wl)
        (push (ewwm-environment--check-path
               (expand-file-name wl xdg) "Wayland socket" t)
              results)))
    (push (ewwm-environment--check-env-var "XDG_CURRENT_DESKTOP") results)
    (push (ewwm-environment--check-env-var "XDG_SESSION_TYPE") results)
    (nreverse results)))

(defun ewwm-environment--check-vr ()
  "Check VR/OpenXR readiness.
Returns list of check results."
  (let (results)
    (push (ewwm-environment--check-env-var "XR_RUNTIME_JSON") results)
    (let ((json (getenv "XR_RUNTIME_JSON")))
      (when json
        (push (ewwm-environment--check-path json "OpenXR runtime JSON" t)
              results)))
    (push (ewwm-environment--check-path
           ewwm-environment-monado-json "Monado runtime JSON") results)
    (push (ewwm-environment--check-executable "monado-service") results)
    (nreverse results)))

(defun ewwm-environment--check-compositor ()
  "Check compositor readiness.
Returns list of check results."
  (let (results)
    (push (ewwm-environment--check-executable "ewwm-compositor" t) results)
    (nreverse results)))

(defun ewwm-environment--check-dbus ()
  "Check D-Bus session readiness.
Returns list of check results."
  (let (results)
    (push (ewwm-environment--check-env-var "DBUS_SESSION_BUS_ADDRESS") results)
    (push (ewwm-environment--check-executable "dbus-daemon") results)
    results))

(defun ewwm-environment--check-bci ()
  "Check BCI/BrainFlow readiness.
Returns list of check results."
  (let (results)
    (push (ewwm-environment--check-env-var "BRAINFLOW_BOARD_ID") results)
    (push (ewwm-environment--check-path "/dev/openbci" "OpenBCI device") results)
    (push (ewwm-environment--check-executable "python3") results)
    results))

(defun ewwm-environment--check-eye-tracking ()
  "Check eye tracking readiness.
Returns list of check results."
  (let (results)
    (push (ewwm-environment--check-executable "pupil_capture") results)
    results))

(defun ewwm-environment--check-secrets ()
  "Check secrets integration readiness.
Returns list of check results."
  (let (results)
    (push (ewwm-environment--check-executable "keepassxc") results)
    (push (ewwm-environment--check-executable "ydotool") results)
    results))

(defun ewwm-environment-check-all ()
  "Run all environment checks.
Returns alist of (category . results) pairs."
  (list
   (cons "Wayland Session" (ewwm-environment--check-wayland))
   (cons "Compositor" (ewwm-environment--check-compositor))
   (cons "VR / OpenXR" (ewwm-environment--check-vr))
   (cons "D-Bus" (ewwm-environment--check-dbus))
   (cons "Eye Tracking" (ewwm-environment--check-eye-tracking))
   (cons "BCI / BrainFlow" (ewwm-environment--check-bci))
   (cons "Secrets" (ewwm-environment--check-secrets))))

(defun ewwm-environment--format-status (status)
  "Format STATUS symbol as a display string."
  (pcase status
    ('ok   "[OK]   ")
    ('warn "[WARN] ")
    ('error "[FAIL] ")
    (_     "[????] ")))

(defun ewwm-environment--format-results (all-results)
  "Format ALL-RESULTS into a human-readable string."
  (let ((lines nil)
        (errors 0)
        (warnings 0)
        (passes 0))
    (dolist (category all-results)
      (push (format "\n== %s ==" (car category)) lines)
      (dolist (check (cdr category))
        (let ((name (nth 0 check))
              (status (nth 1 check))
              (msg (nth 2 check)))
          (pcase status
            ('ok (cl-incf passes))
            ('warn (cl-incf warnings))
            ('error (cl-incf errors)))
          (push (format "  %s %s: %s"
                        (ewwm-environment--format-status status)
                        name msg)
                lines))))
    (push (format "\n== Summary: %d passed, %d warnings, %d errors =="
                  passes warnings errors)
          lines)
    (mapconcat #'identity (nreverse lines) "\n")))

;;;###autoload
(defun ewwm-check-environment ()
  "Validate EXWM-VR environment configuration.
Shows a buffer with check results for all subsystems."
  (interactive)
  (let* ((results (ewwm-environment-check-all))
         (formatted (ewwm-environment--format-results results))
         (buf (get-buffer-create "*EXWM-VR Environment*")))
    (setq ewwm-environment--check-results results)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "EXWM-VR Environment Check\n")
        (insert (make-string 40 ?=))
        (insert "\n")
        (insert formatted)
        (insert "\n")))
    (display-buffer buf)
    results))

;;;###autoload
(defun ewwm-environment-ok-p ()
  "Return non-nil if required environment checks pass.
Checks only critical requirements (Wayland, compositor)."
  (let ((results (ewwm-environment-check-all))
        (ok t))
    (dolist (category results)
      (dolist (check (cdr category))
        (when (eq (nth 1 check) 'error)
          (setq ok nil))))
    ok))

(provide 'ewwm-environment)
;;; ewwm-environment.el ends here
