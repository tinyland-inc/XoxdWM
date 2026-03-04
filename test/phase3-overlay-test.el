;;; phase3-overlay-test.el --- Tests for v0.5.0 Phase 3 overlay/anchor/transient  -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for ewwm-vr-overlay.el, ewwm-vr-anchor.el, and ewwm-vr-transient.el.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Capture project root at load time
(defvar phase3o-test--project-root
  (let* ((this-file (or load-file-name buffer-file-name))
         (test-dir (and this-file (file-name-directory this-file))))
    (if test-dir
        (file-name-directory (directory-file-name test-dir))
      default-directory))
  "Project root directory, captured at load time.")

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-overlay tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-overlay)

(ert-deftest phase3o/overlay-provides-feature ()
  "ewwm-vr-overlay provides its feature."
  (should (featurep 'ewwm-vr-overlay)))

(ert-deftest phase3o/overlay-group-exists ()
  "ewwm-vr-overlay customization group exists."
  (should (get 'ewwm-vr-overlay 'custom-group)))

(ert-deftest phase3o/overlay-max-count-defcustom ()
  "Max overlay count defaults to 16."
  (should (= (default-value 'ewwm-vr-overlay-max-count) 16)))

(ert-deftest phase3o/overlay-default-alpha-defcustom ()
  "Default alpha defaults to 0.9."
  (should (= (default-value 'ewwm-vr-overlay-default-alpha) 0.9)))

(ert-deftest phase3o/overlay-commands-interactive ()
  "Overlay commands are interactive."
  (should (commandp 'ewwm-vr-overlay-create))
  (should (commandp 'ewwm-vr-overlay-remove))
  (should (commandp 'ewwm-vr-overlay-list))
  (should (commandp 'ewwm-vr-overlay-set-alpha))
  (should (commandp 'ewwm-vr-overlay-status)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-anchor tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-anchor)

(ert-deftest phase3o/anchor-provides-feature ()
  "ewwm-vr-anchor provides its feature."
  (should (featurep 'ewwm-vr-anchor)))

(ert-deftest phase3o/anchor-group-exists ()
  "ewwm-vr-anchor customization group exists."
  (should (get 'ewwm-vr-anchor 'custom-group)))

(ert-deftest phase3o/anchor-persist-file-defcustom ()
  "Persist file has a default path."
  (should (stringp (default-value 'ewwm-vr-anchor-persist-file))))

(ert-deftest phase3o/anchor-auto-restore-defcustom ()
  "Auto restore defaults to t."
  (should (eq (default-value 'ewwm-vr-anchor-auto-restore) t)))

(ert-deftest phase3o/anchor-commands-interactive ()
  "Anchor commands are interactive."
  (should (commandp 'ewwm-vr-anchor-create))
  (should (commandp 'ewwm-vr-anchor-remove))
  (should (commandp 'ewwm-vr-anchor-list))
  (should (commandp 'ewwm-vr-anchor-save))
  (should (commandp 'ewwm-vr-anchor-restore))
  (should (commandp 'ewwm-vr-anchor-status)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-transient tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-transient)

(ert-deftest phase3o/transient-provides-feature ()
  "ewwm-vr-transient provides its feature."
  (should (featurep 'ewwm-vr-transient)))

(ert-deftest phase3o/transient-group-exists ()
  "ewwm-vr-transient customization group exists."
  (should (get 'ewwm-vr-transient 'custom-group)))

(ert-deftest phase3o/transient-z-offset-defcustom ()
  "Z offset defaults to 0.1."
  (should (= (default-value 'ewwm-vr-transient-z-offset) 0.1)))

(ert-deftest phase3o/transient-max-depth-defcustom ()
  "Max depth defaults to 5."
  (should (= (default-value 'ewwm-vr-transient-max-depth) 5)))

(ert-deftest phase3o/transient-placement-defcustom ()
  "Default placement is auto."
  (should (equal (default-value 'ewwm-vr-transient-placement) "auto")))

(ert-deftest phase3o/transient-commands-interactive ()
  "Transient commands are interactive."
  (should (commandp 'ewwm-vr-transient-list))
  (should (commandp 'ewwm-vr-transient-set-placement))
  (should (commandp 'ewwm-vr-transient-status)))

;; ── Compositor handler file checks ──────────────────────────

(ert-deftest phase3o/transient-3d-handler-exists ()
  "Transient 3D handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/vr/transient_3d.rs"
                             phase3o-test--project-root))))

(ert-deftest phase3o/overlay-handler-exists ()
  "Overlay handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/vr/overlay.rs"
                             phase3o-test--project-root))))

(provide 'phase3-overlay-test)
;;; phase3-overlay-test.el ends here
