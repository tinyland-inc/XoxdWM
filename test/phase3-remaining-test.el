;;; phase3-remaining-test.el --- Tests for v0.5.0 Phase 3 remaining + Phase 4  -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for ewwm-vr-radial.el, ewwm-vr-capture.el, and ewwm-vr-gpu.el.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Capture project root at load time
(defvar phase3r-test--project-root
  (let* ((this-file (or load-file-name buffer-file-name))
         (test-dir (and this-file (file-name-directory this-file))))
    (if test-dir
        (file-name-directory (directory-file-name test-dir))
      default-directory))
  "Project root directory, captured at load time.")

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-radial tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-radial)

(ert-deftest phase3r/radial-provides-feature ()
  "ewwm-vr-radial provides its feature."
  (should (featurep 'ewwm-vr-radial)))

(ert-deftest phase3r/radial-group-exists ()
  "ewwm-vr-radial customization group exists."
  (should (get 'ewwm-vr-radial 'custom-group)))

(ert-deftest phase3r/radial-items-defcustom ()
  "Radial items default is a non-empty alist."
  (let ((items (default-value 'ewwm-vr-radial-items)))
    (should (listp items))
    (should (> (length items) 0))
    (should (stringp (caar items)))))

(ert-deftest phase3r/radial-radius-defcustom ()
  "Radial radius defaults to 0.3."
  (should (= (default-value 'ewwm-vr-radial-radius) 0.3)))

(ert-deftest phase3r/radial-inner-radius-defcustom ()
  "Radial inner radius defaults to 0.05."
  (should (= (default-value 'ewwm-vr-radial-inner-radius) 0.05)))

(ert-deftest phase3r/radial-state-var ()
  "Radial state variable exists and is a string."
  (should (boundp 'ewwm-vr-radial--state))
  (should (stringp ewwm-vr-radial--state)))

(ert-deftest phase3r/radial-action-alist-exists ()
  "Radial action alist is bound."
  (should (boundp 'ewwm-vr-radial-action-alist))
  (should (listp ewwm-vr-radial-action-alist)))

(ert-deftest phase3r/radial-commands-interactive ()
  "Radial menu commands are interactive."
  (should (commandp 'ewwm-vr-radial-open))
  (should (commandp 'ewwm-vr-radial-close))
  (should (commandp 'ewwm-vr-radial-toggle))
  (should (commandp 'ewwm-vr-radial-configure))
  (should (commandp 'ewwm-vr-radial-add-item))
  (should (commandp 'ewwm-vr-radial-remove-item))
  (should (commandp 'ewwm-vr-radial-status)))

(ert-deftest phase3r/radial-dispatch-unknown ()
  "Dispatching an unknown action does not error."
  (should (progn (ewwm-vr-radial--dispatch-action "nonexistent-action") t)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-capture tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-capture)

(ert-deftest phase3r/capture-provides-feature ()
  "ewwm-vr-capture provides its feature."
  (should (featurep 'ewwm-vr-capture)))

(ert-deftest phase3r/capture-group-exists ()
  "ewwm-vr-capture customization group exists."
  (should (get 'ewwm-vr-capture 'custom-group)))

(ert-deftest phase3r/capture-default-visibility ()
  "Default capture visibility is visible."
  (should (equal (default-value 'ewwm-vr-capture-default-visibility) "visible")))

(ert-deftest phase3r/capture-sensitive-patterns ()
  "Sensitive patterns is a non-empty list of regexps."
  (let ((patterns (default-value 'ewwm-vr-capture-sensitive-patterns)))
    (should (listp patterns))
    (should (> (length patterns) 0))
    (should (stringp (car patterns)))))

(ert-deftest phase3r/capture-auto-classify-sensitive ()
  "Auto-classify detects sensitive buffer names."
  (should (equal (ewwm-vr-capture--auto-classify "*KeePass: db*") "sensitive"))
  (should (equal (ewwm-vr-capture--auto-classify "*Password*") "sensitive"))
  (should (equal (ewwm-vr-capture--auto-classify "*TOTP*") "sensitive")))

(ert-deftest phase3r/capture-auto-classify-normal ()
  "Auto-classify returns default for non-sensitive buffers."
  (should (equal (ewwm-vr-capture--auto-classify "*scratch*") "visible"))
  (should (equal (ewwm-vr-capture--auto-classify "main.rs") "visible")))

(ert-deftest phase3r/capture-commands-interactive ()
  "Capture commands are interactive."
  (should (commandp 'ewwm-vr-capture-hide-surface))
  (should (commandp 'ewwm-vr-capture-show-surface))
  (should (commandp 'ewwm-vr-capture-mark-sensitive))
  (should (commandp 'ewwm-vr-capture-status)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-gpu tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-gpu)

(ert-deftest phase3r/gpu-provides-feature ()
  "ewwm-vr-gpu provides its feature."
  (should (featurep 'ewwm-vr-gpu)))

(ert-deftest phase3r/gpu-group-exists ()
  "ewwm-vr-gpu customization group exists."
  (should (get 'ewwm-vr-gpu 'custom-group)))

(ert-deftest phase3r/gpu-auto-boost-defcustom ()
  "Auto boost defaults to t."
  (should (eq (default-value 'ewwm-vr-gpu-auto-boost) t)))

(ert-deftest phase3r/gpu-default-profile-defcustom ()
  "Default profile is auto."
  (should (equal (default-value 'ewwm-vr-gpu-default-profile) "auto")))

(ert-deftest phase3r/gpu-current-profile-var ()
  "Current profile variable is bound."
  (should (boundp 'ewwm-vr-gpu--current-profile))
  (should (stringp ewwm-vr-gpu--current-profile)))

(ert-deftest phase3r/gpu-changed-hook-exists ()
  "GPU changed hook variable is bound."
  (should (boundp 'ewwm-vr-gpu-changed-hook)))

(ert-deftest phase3r/gpu-commands-interactive ()
  "GPU power commands are interactive."
  (should (commandp 'ewwm-vr-gpu-set-profile))
  (should (commandp 'ewwm-vr-gpu-detect))
  (should (commandp 'ewwm-vr-gpu-status)))

;; ── Compositor handler file checks ──────────────────────────

(ert-deftest phase3r/radial-menu-handler-exists ()
  "Radial menu handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/vr/radial_menu.rs"
                             phase3r-test--project-root))))

(ert-deftest phase3r/capture-visibility-handler-exists ()
  "Capture visibility handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/vr/capture_visibility.rs"
                             phase3r-test--project-root))))

(ert-deftest phase3r/gpu-power-handler-exists ()
  "GPU power handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/vr/gpu_power.rs"
                             phase3r-test--project-root))))

(ert-deftest phase3r/config-handler-exists ()
  "Compositor config module exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/config.rs"
                             phase3r-test--project-root))))

(provide 'phase3-remaining-test)
;;; phase3-remaining-test.el ends here
