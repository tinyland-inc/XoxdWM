;;; phase1-protocols-test.el --- Tests for v0.5.0 Phase 1 modules  -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for ewwm-autostart.el and ewwm-session.el (v0.5.0 Phase 1).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ewwm-autostart)
(require 'ewwm-session)

;; Capture project root at load time (load-file-name is nil at test runtime)
(defvar phase1-test--project-root
  (let* ((this-file (or load-file-name buffer-file-name))
         (test-dir (and this-file (file-name-directory this-file))))
    (if test-dir
        (file-name-directory (directory-file-name test-dir))
      default-directory))
  "Project root directory, captured at load time.")

;; ══════════════════════════════════════════════════════════════
;; ewwm-autostart tests
;; ══════════════════════════════════════════════════════════════

;; ── Module loading ───────────────────────────────────────────

(ert-deftest phase1/autostart-provides-feature ()
  "ewwm-autostart provides its feature."
  (should (featurep 'ewwm-autostart)))

(ert-deftest phase1/autostart-group-exists ()
  "ewwm-autostart customization group exists."
  (should (get 'ewwm-autostart 'custom-group)))

;; ── Defcustoms ──────────────────────────────────────────────

(ert-deftest phase1/autostart-directories-defcustom ()
  "ewwm-autostart-directories is a list."
  (should (listp ewwm-autostart-directories)))

(ert-deftest phase1/autostart-exclude-defcustom ()
  "ewwm-autostart-exclude defaults to nil."
  (should (null (default-value 'ewwm-autostart-exclude))))

(ert-deftest phase1/autostart-delay-defcustom ()
  "ewwm-autostart-delay defaults to 2."
  (should (= (default-value 'ewwm-autostart-delay) 2)))

(ert-deftest phase1/autostart-desktop-name-defcustom ()
  "ewwm-autostart-desktop-name defaults to EXWM-VR."
  (should (equal (default-value 'ewwm-autostart-desktop-name) "EXWM-VR")))

;; ── Desktop file parsing ─────────────────────────────────────

(ert-deftest phase1/autostart-parse-desktop-file ()
  "Parse a .desktop file into an alist."
  (let ((tmpfile (make-temp-file "test-autostart" nil ".desktop")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "[Desktop Entry]\n")
            (insert "Type=Application\n")
            (insert "Name=Test App\n")
            (insert "Exec=test-app --flag\n")
            (insert "Hidden=false\n"))
          (let ((entry (ewwm-autostart--parse-desktop-file tmpfile)))
            (should entry)
            (should (equal (ewwm-autostart--get entry "Type") "Application"))
            (should (equal (ewwm-autostart--get entry "Name") "Test App"))
            (should (equal (ewwm-autostart--get entry "Exec") "test-app --flag"))
            (should (equal (ewwm-autostart--get entry "Hidden") "false"))))
      (delete-file tmpfile))))

(ert-deftest phase1/autostart-parse-ignores-other-groups ()
  "Parser only reads [Desktop Entry] group."
  (let ((tmpfile (make-temp-file "test-autostart" nil ".desktop")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "[Desktop Entry]\n")
            (insert "Name=Real App\n")
            (insert "Exec=real-app\n")
            (insert "[Desktop Action New]\n")
            (insert "Name=New Window\n")
            (insert "Exec=real-app --new-window\n"))
          (let ((entry (ewwm-autostart--parse-desktop-file tmpfile)))
            (should (equal (ewwm-autostart--get entry "Name") "Real App"))
            (should (equal (ewwm-autostart--get entry "Exec") "real-app"))))
      (delete-file tmpfile))))

;; ── Field code stripping ─────────────────────────────────────

(ert-deftest phase1/autostart-strip-field-codes ()
  "Strip freedesktop field codes from Exec strings."
  (should (equal (ewwm-autostart--strip-field-codes "firefox %u") "firefox "))
  (should (equal (ewwm-autostart--strip-field-codes "app %F %U") "app  "))
  (should (equal (ewwm-autostart--strip-field-codes "plain-cmd") "plain-cmd")))

;; ── Filtering ────────────────────────────────────────────────

(ert-deftest phase1/autostart-should-run-normal ()
  "Normal Application entry should run."
  (let ((entry '(("Type" . "Application")
                 ("Name" . "Test")
                 ("Exec" . "test-cmd"))))
    (should (ewwm-autostart--should-run-p entry))))

(ert-deftest phase1/autostart-should-run-hidden ()
  "Hidden entry should not run."
  (let ((entry '(("Type" . "Application")
                 ("Name" . "Hidden Test")
                 ("Exec" . "test-cmd")
                 ("Hidden" . "true"))))
    (should-not (ewwm-autostart--should-run-p entry))))

(ert-deftest phase1/autostart-should-run-only-show-in-match ()
  "OnlyShowIn matching our desktop should run."
  (let ((entry '(("Type" . "Application")
                 ("Name" . "Test")
                 ("Exec" . "test-cmd")
                 ("OnlyShowIn" . "GNOME;EXWM-VR;KDE"))))
    (should (ewwm-autostart--should-run-p entry))))

(ert-deftest phase1/autostart-should-run-only-show-in-no-match ()
  "OnlyShowIn not matching our desktop should not run."
  (let ((entry '(("Type" . "Application")
                 ("Name" . "Test")
                 ("Exec" . "test-cmd")
                 ("OnlyShowIn" . "GNOME;KDE"))))
    (should-not (ewwm-autostart--should-run-p entry))))

(ert-deftest phase1/autostart-should-run-not-show-in ()
  "NotShowIn containing our desktop should not run."
  (let ((entry '(("Type" . "Application")
                 ("Name" . "Test")
                 ("Exec" . "test-cmd")
                 ("NotShowIn" . "EXWM-VR;LXDE"))))
    (should-not (ewwm-autostart--should-run-p entry))))

(ert-deftest phase1/autostart-should-run-no-exec ()
  "Entry without Exec should not run."
  (let ((entry '(("Type" . "Application")
                 ("Name" . "No Exec"))))
    (should-not (ewwm-autostart--should-run-p entry))))

(ert-deftest phase1/autostart-should-run-tryexec-missing ()
  "TryExec for non-existent binary should not run."
  (let ((entry '(("Type" . "Application")
                 ("Name" . "Test")
                 ("Exec" . "nonexistent-binary-xyz")
                 ("TryExec" . "nonexistent-binary-xyz"))))
    (should-not (ewwm-autostart--should-run-p entry))))

;; ── Reset ────────────────────────────────────────────────────

(ert-deftest phase1/autostart-reset ()
  "Reset clears launched state."
  (let ((ewwm-autostart--launched '("foo.desktop" "bar.desktop")))
    (ewwm-autostart-reset)
    (should (null ewwm-autostart--launched))))

;; ── Collect entries deduplication ────────────────────────────

(ert-deftest phase1/autostart-collect-deduplicates ()
  "Collect entries deduplicates by basename (first dir wins)."
  (let* ((dir1 (make-temp-file "autostart1" t))
         (dir2 (make-temp-file "autostart2" t))
         (ewwm-autostart-directories (list dir1 dir2))
         (ewwm-autostart-exclude nil))
    (unwind-protect
        (progn
          ;; Same basename in both dirs
          (with-temp-file (expand-file-name "test.desktop" dir1)
            (insert "[Desktop Entry]\nName=Dir1 App\nExec=app1\nType=Application\n"))
          (with-temp-file (expand-file-name "test.desktop" dir2)
            (insert "[Desktop Entry]\nName=Dir2 App\nExec=app2\nType=Application\n"))
          (let ((entries (ewwm-autostart--collect-entries)))
            (should (= (length entries) 1))
            (should (equal (ewwm-autostart--get (cdar entries) "Name") "Dir1 App"))))
      (delete-directory dir1 t)
      (delete-directory dir2 t))))

;; ══════════════════════════════════════════════════════════════
;; ewwm-session tests
;; ══════════════════════════════════════════════════════════════

;; ── Module loading ───────────────────────────────────────────

(ert-deftest phase1/session-provides-feature ()
  "ewwm-session provides its feature."
  (should (featurep 'ewwm-session)))

(ert-deftest phase1/session-group-exists ()
  "ewwm-session customization group exists."
  (should (get 'ewwm-session 'custom-group)))

;; ── Defcustoms ──────────────────────────────────────────────

(ert-deftest phase1/session-lock-command-defcustom ()
  "ewwm-session-lock-command defaults to swaylock."
  (should (equal (default-value 'ewwm-session-lock-command) "swaylock")))

(ert-deftest phase1/session-lock-args-defcustom ()
  "ewwm-session-lock-args defaults to nil."
  (should (null (default-value 'ewwm-session-lock-args))))

(ert-deftest phase1/session-idle-command-defcustom ()
  "ewwm-session-idle-command defaults to swayidle."
  (should (equal (default-value 'ewwm-session-idle-command) "swayidle")))

(ert-deftest phase1/session-idle-args-defcustom ()
  "ewwm-session-idle-args is a list."
  (should (listp (default-value 'ewwm-session-idle-args))))

(ert-deftest phase1/session-shutdown-command-defcustom ()
  "ewwm-session-shutdown-command defaults to systemctl poweroff."
  (should (equal (default-value 'ewwm-session-shutdown-command) "systemctl poweroff")))

(ert-deftest phase1/session-reboot-command-defcustom ()
  "ewwm-session-reboot-command defaults to systemctl reboot."
  (should (equal (default-value 'ewwm-session-reboot-command) "systemctl reboot")))

(ert-deftest phase1/session-suspend-command-defcustom ()
  "ewwm-session-suspend-command defaults to systemctl suspend."
  (should (equal (default-value 'ewwm-session-suspend-command) "systemctl suspend")))

;; ── State variables ──────────────────────────────────────────

(ert-deftest phase1/session-idle-process-var ()
  "ewwm-session-idle-process starts as nil."
  (should (null ewwm-session-idle-process)))

(ert-deftest phase1/session-lock-process-var ()
  "ewwm-session-lock-process starts as nil."
  (should (null ewwm-session-lock-process)))

;; ── Status command ──────────────────────────────────────────

(ert-deftest phase1/session-status-reports ()
  "Session status reports both idle and lock states."
  (let ((ewwm-session-idle-process nil)
        (ewwm-session-lock-process nil)
        (captured nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq captured (apply #'format fmt args)))))
      (ewwm-session-status))
    (should (string-match "idle=stopped" captured))
    (should (string-match "lock=inactive" captured))))

;; ── Interactive commands exist ────────────────────────────────

(ert-deftest phase1/session-commands-interactive ()
  "Session management commands are interactive."
  (should (commandp 'ewwm-session-lock))
  (should (commandp 'ewwm-session-logout))
  (should (commandp 'ewwm-session-shutdown))
  (should (commandp 'ewwm-session-reboot))
  (should (commandp 'ewwm-session-suspend))
  (should (commandp 'ewwm-session-start-idle))
  (should (commandp 'ewwm-session-stop-idle))
  (should (commandp 'ewwm-session-status)))

(ert-deftest phase1/autostart-commands-interactive ()
  "Autostart commands are interactive."
  (should (commandp 'ewwm-autostart-run))
  (should (commandp 'ewwm-autostart-list)))

;; ── Compositor handler file checks ──────────────────────────

(ert-deftest phase1/session-lock-handler-exists ()
  "session_lock.rs handler file exists."
  (let ((root phase1-test--project-root))
    (should (file-exists-p
             (expand-file-name "compositor/src/handlers/session_lock.rs" root)))))

(ert-deftest phase1/idle-handler-exists ()
  "idle.rs handler file exists."
  (let ((root phase1-test--project-root))
    (should (file-exists-p
             (expand-file-name "compositor/src/handlers/idle.rs" root)))))

(ert-deftest phase1/dmabuf-handler-exists ()
  "dmabuf.rs handler file exists."
  (let ((root phase1-test--project-root))
    (should (file-exists-p
             (expand-file-name "compositor/src/handlers/dmabuf.rs" root)))))

(ert-deftest phase1/xdg-activation-handler-exists ()
  "xdg_activation.rs handler file exists."
  (let ((root phase1-test--project-root))
    (should (file-exists-p
             (expand-file-name "compositor/src/handlers/xdg_activation.rs" root)))))

(ert-deftest phase1/dpms-handler-exists ()
  "dpms.rs handler file exists."
  (let ((root phase1-test--project-root))
    (should (file-exists-p
             (expand-file-name "compositor/src/handlers/dpms.rs" root)))))

(ert-deftest phase1/data-control-stub-exists ()
  "data_control.rs stub file exists."
  (let ((root phase1-test--project-root))
    (should (file-exists-p
             (expand-file-name "compositor/src/handlers/data_control.rs" root)))))

;; ── Udev and NixOS config checks ────────────────────────────

(ert-deftest phase1/udev-has-beyond-rules ()
  "udev rules contain Bigscreen Beyond VID."
  (let* ((root (file-name-directory
                (directory-file-name
                 (file-name-directory
                  (or load-file-name default-directory)))))
         (rules-file (expand-file-name "packaging/udev/99-exwm-vr.rules" root)))
    (when (file-exists-p rules-file)
      (with-temp-buffer
        (insert-file-contents rules-file)
        (should (search-forward "35bd" nil t))))))

(ert-deftest phase1/monado-has-beyond-option ()
  "monado.nix contains bigscreen-beyond option."
  (let* ((root (file-name-directory
                (directory-file-name
                 (file-name-directory
                  (or load-file-name default-directory)))))
         (nix-file (expand-file-name "nix/modules/monado.nix" root)))
    (when (file-exists-p nix-file)
      (with-temp-buffer
        (insert-file-contents nix-file)
        (should (search-forward "bigscreen-beyond" nil t))))))

(provide 'phase1-protocols-test)
;;; phase1-protocols-test.el ends here
