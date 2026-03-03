;;; phase2-protocols-test.el --- Tests for v0.5.0 Phase 2 protocol modules  -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for ewwm-dark-mode.el and ewwm-output.el (v0.5.0 Phase 2).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ewwm-session)

;; Capture project root at load time
(defvar phase2p-test--project-root
  (let* ((this-file (or load-file-name buffer-file-name))
         (test-dir (and this-file (file-name-directory this-file))))
    (if test-dir
        (file-name-directory (directory-file-name test-dir))
      default-directory))
  "Project root directory, captured at load time.")

;; ══════════════════════════════════════════════════════════════
;; ewwm-dark-mode tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-dark-mode)

(ert-deftest phase2p/dark-mode-provides-feature ()
  "ewwm-dark-mode provides its feature."
  (should (featurep 'ewwm-dark-mode)))

(ert-deftest phase2p/dark-mode-group-exists ()
  "ewwm-dark-mode customization group exists."
  (should (get 'ewwm-dark-mode 'custom-group)))

(ert-deftest phase2p/dark-mode-dark-theme-defcustom ()
  "Dark theme defaults to modus-vivendi."
  (should (equal (default-value 'ewwm-dark-mode-dark-theme) "modus-vivendi")))

(ert-deftest phase2p/dark-mode-light-theme-defcustom ()
  "Light theme defaults to modus-operandi."
  (should (equal (default-value 'ewwm-dark-mode-light-theme) "modus-operandi")))

(ert-deftest phase2p/dark-mode-follow-system-defcustom ()
  "Follow system defaults to t."
  (should (eq (default-value 'ewwm-dark-mode-follow-system) t)))

(ert-deftest phase2p/dark-mode-current-state ()
  "Current dark mode state is a symbol."
  (should (symbolp ewwm-dark-mode--current)))

(ert-deftest phase2p/dark-mode-commands-interactive ()
  "Dark mode commands are interactive."
  (should (commandp 'ewwm-dark-mode-toggle))
  (should (commandp 'ewwm-dark-mode-set-dark))
  (should (commandp 'ewwm-dark-mode-set-light))
  (should (commandp 'ewwm-dark-mode-enable))
  (should (commandp 'ewwm-dark-mode-disable)))

(ert-deftest phase2p/dark-mode-hook-exists ()
  "Dark mode changed hook is a proper variable."
  (should (boundp 'ewwm-dark-mode-changed-hook)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-output tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-output)

(ert-deftest phase2p/output-provides-feature ()
  "ewwm-output provides its feature."
  (should (featurep 'ewwm-output)))

(ert-deftest phase2p/output-group-exists ()
  "ewwm-output customization group exists."
  (should (get 'ewwm-output 'custom-group)))

(ert-deftest phase2p/output-default-scale-defcustom ()
  "Default scale is 1.0."
  (should (= (default-value 'ewwm-output-default-scale) 1.0)))

(ert-deftest phase2p/output-configurations-var ()
  "Output configurations variable exists."
  (should (boundp 'ewwm-output--configurations)))

(ert-deftest phase2p/output-commands-interactive ()
  "Output commands are interactive."
  (should (commandp 'ewwm-output-list))
  (should (commandp 'ewwm-output-configure))
  (should (commandp 'ewwm-output-set-scale)))

;; ── Compositor handler file checks ──────────────────────────

(ert-deftest phase2p/screencopy-handler-exists ()
  "Screencopy handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/handlers/screencopy.rs"
                             phase2p-test--project-root))))

(ert-deftest phase2p/output-management-handler-exists ()
  "Output management handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/handlers/output_management.rs"
                             phase2p-test--project-root))))

(ert-deftest phase2p/pointer-constraints-handler-exists ()
  "Pointer constraints handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/handlers/pointer_constraints.rs"
                             phase2p-test--project-root))))

;; ── Session wrapper audit verification ──────────────────────

(ert-deftest phase2p/session-wrapper-no-wlr-renderer ()
  "Session wrapper no longer references WLR_RENDERER."
  (let* ((root phase2p-test--project-root)
         (wrapper (expand-file-name "packaging/desktop/exwm-vr-session" root)))
    (when (file-exists-p wrapper)
      (with-temp-buffer
        (insert-file-contents wrapper)
        (should-not (search-forward "WLR_RENDERER" nil t))))))

(ert-deftest phase2p/session-wrapper-has-electron-hint ()
  "Session wrapper sets ELECTRON_OZONE_PLATFORM_HINT."
  (let* ((root phase2p-test--project-root)
         (wrapper (expand-file-name "packaging/desktop/exwm-vr-session" root)))
    (when (file-exists-p wrapper)
      (with-temp-buffer
        (insert-file-contents wrapper)
        (should (search-forward "ELECTRON_OZONE_PLATFORM_HINT" nil t))))))

(ert-deftest phase2p/session-wrapper-socket-poll ()
  "Session wrapper polls for Wayland socket instead of sleep."
  (let* ((root phase2p-test--project-root)
         (wrapper (expand-file-name "packaging/desktop/exwm-vr-session" root)))
    (when (file-exists-p wrapper)
      (with-temp-buffer
        (insert-file-contents wrapper)
        ;; Should NOT have a bare 'sleep 1' anymore
        (goto-char (point-min))
        (should-not (re-search-forward "^sleep 1$" nil t))))))

(ert-deftest phase2p/desktop-file-has-tryexec ()
  "Desktop file includes TryExec."
  (let* ((root phase2p-test--project-root)
         (desktop (expand-file-name "packaging/desktop/exwm-vr.desktop" root)))
    (when (file-exists-p desktop)
      (with-temp-buffer
        (insert-file-contents desktop)
        (should (search-forward "TryExec" nil t))))))

(ert-deftest phase2p/compositor-service-type-simple ()
  "Compositor service uses Type=simple (not notify)."
  (let* ((root phase2p-test--project-root)
         (service (expand-file-name "packaging/systemd/exwm-vr-compositor.service" root)))
    (when (file-exists-p service)
      (with-temp-buffer
        (insert-file-contents service)
        (should (search-forward "Type=simple" nil t))
        (goto-char (point-min))
        (should-not (search-forward "Type=notify" nil t))))))

(ert-deftest phase2p/session-idle-no-swaymsg ()
  "ewwm-session idle args do not reference swaymsg."
  (let ((args (default-value 'ewwm-session-idle-args)))
    (should-not (cl-some (lambda (a) (string-match-p "swaymsg" a)) args))))

(provide 'phase2-protocols-test)
;;; phase2-protocols-test.el ends here
