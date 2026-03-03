;;; ewwm-autostart.el --- XDG Autostart for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; XDG Autostart spec compliance for ewwm.  Scans autostart directories
;; for .desktop files, filters by OnlyShowIn/NotShowIn/Hidden/TryExec,
;; and launches qualifying entries via `ewwm-launch'.

;;; Code:

(require 'cl-lib)

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-autostart nil
  "XDG Autostart for EWWM."
  :group 'ewwm)

(defcustom ewwm-autostart-directories
  (let ((config-home (or (getenv "XDG_CONFIG_HOME")
                         (expand-file-name "~/.config")))
        (config-dirs (or (getenv "XDG_CONFIG_DIRS") "/etc/xdg")))
    (mapcar (lambda (dir) (expand-file-name "autostart" dir))
            (cons config-home (split-string config-dirs ":"))))
  "Directories to scan for .desktop autostart entries.
Defaults to $XDG_CONFIG_HOME/autostart and $XDG_CONFIG_DIRS/autostart."
  :type '(repeat directory)
  :group 'ewwm-autostart)

(defcustom ewwm-autostart-exclude nil
  "List of .desktop file basenames to skip.
For example: (\"nm-applet.desktop\" \"blueman.desktop\")."
  :type '(repeat string)
  :group 'ewwm-autostart)

(defcustom ewwm-autostart-delay 2
  "Seconds to wait after init before running autostart entries."
  :type 'number
  :group 'ewwm-autostart)

(defcustom ewwm-autostart-desktop-name "EXWM-VR"
  "Desktop name used for OnlyShowIn/NotShowIn filtering.
This is matched against the OnlyShowIn and NotShowIn keys in .desktop files."
  :type 'string
  :group 'ewwm-autostart)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-autostart--launched nil
  "List of .desktop basenames that have been launched this session.")

(defvar ewwm-autostart--timer nil
  "Timer for delayed autostart.")

;; ── Desktop file parsing ─────────────────────────────────────

(defun ewwm-autostart--parse-desktop-file (file)
  "Parse a .desktop FILE and return an alist of key-value pairs.
Only parses keys from the [Desktop Entry] group."
  (when (file-readable-p file)
    (let ((result nil)
          (in-desktop-entry nil))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (cond
             ;; Group header
             ((string-match "^\\[\\(.*\\)\\]" line)
              (setq in-desktop-entry
                    (string= (match-string 1 line) "Desktop Entry")))
             ;; Key=Value in Desktop Entry group
             ((and in-desktop-entry
                   (string-match "^\\([A-Za-z0-9-]+\\)\\s-*=\\s-*\\(.*\\)" line))
              (push (cons (match-string 1 line)
                          (string-trim (match-string 2 line)))
                    result))))
          (forward-line 1)))
      (nreverse result))))

(defun ewwm-autostart--get (entry key)
  "Get KEY from parsed desktop ENTRY alist."
  (cdr (assoc key entry)))

;; ── Filtering ────────────────────────────────────────────────

(defun ewwm-autostart--should-run-p (entry)
  "Return non-nil if parsed desktop ENTRY should be autostarted.
Checks Hidden, OnlyShowIn, NotShowIn, and TryExec keys."
  (and
   ;; Not hidden
   (not (string= (or (ewwm-autostart--get entry "Hidden") "") "true"))
   ;; Type must be Application (or absent)
   (let ((type (ewwm-autostart--get entry "Type")))
     (or (null type) (string= type "Application")))
   ;; Has an Exec line
   (ewwm-autostart--get entry "Exec")
   ;; OnlyShowIn: if present, our desktop must be listed
   (let ((only (ewwm-autostart--get entry "OnlyShowIn")))
     (or (null only)
         (member ewwm-autostart-desktop-name
                 (split-string only ";"  t))))
   ;; NotShowIn: if present, our desktop must NOT be listed
   (let ((not-show (ewwm-autostart--get entry "NotShowIn")))
     (or (null not-show)
         (not (member ewwm-autostart-desktop-name
                      (split-string not-show ";" t)))))
   ;; TryExec: if present, the executable must be found
   (let ((try-exec (ewwm-autostart--get entry "TryExec")))
     (or (null try-exec)
         (executable-find try-exec)))))

;; ── Exec line handling ───────────────────────────────────────

(defun ewwm-autostart--strip-field-codes (exec)
  "Strip freedesktop field codes (%f, %F, %u, %U, etc.) from EXEC string."
  (replace-regexp-in-string "%[fFuUdDnNickvm]" "" exec t))

(defun ewwm-autostart--exec-entry (entry)
  "Launch the Exec line from parsed desktop ENTRY.
Uses `ewwm-launch' if available, otherwise `start-process-shell-command'."
  (let* ((exec-raw (ewwm-autostart--get entry "Exec"))
         (command (string-trim (ewwm-autostart--strip-field-codes exec-raw)))
         (name (or (ewwm-autostart--get entry "Name") command)))
    (if (fboundp 'ewwm-launch)
        (ewwm-launch command)
      (let ((proc-name (format "ewwm-autostart:%s" name)))
        (start-process-shell-command
         proc-name (format " *%s*" proc-name) command)))
    (message "ewwm-autostart: launched %s" name)))

;; ── Scanning ─────────────────────────────────────────────────

(defun ewwm-autostart--collect-entries ()
  "Scan autostart directories and return list of (BASENAME . ENTRY) pairs.
Later directories do not override earlier ones (user config takes precedence)."
  (let ((seen (make-hash-table :test 'equal))
        (entries nil))
    (dolist (dir ewwm-autostart-directories)
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\.desktop\\'"))
          (let ((basename (file-name-nondirectory file)))
            (unless (or (gethash basename seen)
                        (member basename ewwm-autostart-exclude))
              (puthash basename t seen)
              (let ((entry (ewwm-autostart--parse-desktop-file file)))
                (when entry
                  (push (cons basename entry) entries))))))))
    (nreverse entries)))

;; ── Interactive commands ─────────────────────────────────────

(defun ewwm-autostart-run ()
  "Scan XDG autostart directories and launch all qualifying entries."
  (interactive)
  (let ((entries (ewwm-autostart--collect-entries))
        (count 0))
    (dolist (pair entries)
      (let ((basename (car pair))
            (entry (cdr pair)))
        (when (and (ewwm-autostart--should-run-p entry)
                   (not (member basename ewwm-autostart--launched)))
          (ewwm-autostart--exec-entry entry)
          (push basename ewwm-autostart--launched)
          (cl-incf count))))
    (message "ewwm-autostart: launched %d entries" count)))

(defun ewwm-autostart-list ()
  "Display a buffer listing what would be autostarted.
Useful for debugging autostart configuration."
  (interactive)
  (let ((buf (get-buffer-create "*ewwm-autostart*"))
        (entries (ewwm-autostart--collect-entries)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "EWWM XDG Autostart Entries\n")
        (insert (make-string 40 ?=) "\n\n")
        (if (null entries)
            (insert "No .desktop files found in autostart directories.\n")
          (dolist (pair entries)
            (let* ((basename (car pair))
                   (entry (cdr pair))
                   (name (or (ewwm-autostart--get entry "Name") basename))
                   (exec (ewwm-autostart--get entry "Exec"))
                   (runp (ewwm-autostart--should-run-p entry))
                   (launched (member basename ewwm-autostart--launched)))
              (insert (format "  %s  %s\n" (cond (launched "[DONE]")
                                                  (runp     "[ OK ]")
                                                  (t        "[SKIP]"))
                              basename))
              (insert (format "       Name: %s\n" name))
              (insert (format "       Exec: %s\n" (or exec "(none)")))
              (let ((only (ewwm-autostart--get entry "OnlyShowIn"))
                    (not-show (ewwm-autostart--get entry "NotShowIn")))
                (when only
                  (insert (format "       OnlyShowIn: %s\n" only)))
                (when not-show
                  (insert (format "       NotShowIn: %s\n" not-show))))
              (insert "\n"))))
        (insert (format "\nDirectories scanned:\n"))
        (dolist (dir ewwm-autostart-directories)
          (insert (format "  %s %s\n"
                          (if (file-directory-p dir) "[exists]" "[absent]")
                          dir)))
        (insert (format "\nDesktop name: %s\n" ewwm-autostart-desktop-name)))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buf)))

;; ── Integration ──────────────────────────────────────────────

(defun ewwm-autostart-enable ()
  "Enable XDG autostart after ewwm init.
Schedules autostart to run after `ewwm-autostart-delay' seconds."
  (when ewwm-autostart--timer
    (cancel-timer ewwm-autostart--timer))
  (setq ewwm-autostart--timer
        (run-with-timer ewwm-autostart-delay nil #'ewwm-autostart-run)))

(defun ewwm-autostart-disable ()
  "Cancel pending autostart timer."
  (when ewwm-autostart--timer
    (cancel-timer ewwm-autostart--timer)
    (setq ewwm-autostart--timer nil)))

(defun ewwm-autostart-reset ()
  "Reset autostart state, allowing entries to be launched again."
  (setq ewwm-autostart--launched nil))

(provide 'ewwm-autostart)
;;; ewwm-autostart.el ends here
