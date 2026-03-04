;;; week7-integration-test.el --- Week 7 integration tests  -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'ewwm-core)
(require 'ewwm-vr)

;; ── VR module structure ─────────────────────────────────────

(ert-deftest week7-integration/vr-module-exists ()
  "VR Rust module directory exists."
  (let ((dir (expand-file-name "compositor/src/vr"
                               (locate-dominating-file default-directory ".git"))))
    (should (file-directory-p dir))))

(ert-deftest week7-integration/vr-mod-rs-exists ()
  "compositor/src/vr/mod.rs exists."
  (let ((f (expand-file-name "compositor/src/vr/mod.rs"
                              (locate-dominating-file default-directory ".git"))))
    (should (file-exists-p f))))

(ert-deftest week7-integration/vr-stub-exists ()
  "compositor/src/vr/stub.rs exists."
  (let ((f (expand-file-name "compositor/src/vr/stub.rs"
                              (locate-dominating-file default-directory ".git"))))
    (should (file-exists-p f))))

(ert-deftest week7-integration/vr-frame-timing-exists ()
  "compositor/src/vr/frame_timing.rs exists."
  (let ((f (expand-file-name "compositor/src/vr/frame_timing.rs"
                              (locate-dominating-file default-directory ".git"))))
    (should (file-exists-p f))))

(ert-deftest week7-integration/vr-openxr-state-exists ()
  "compositor/src/vr/openxr_state.rs exists."
  (let ((f (expand-file-name "compositor/src/vr/openxr_state.rs"
                              (locate-dominating-file default-directory ".git"))))
    (should (file-exists-p f))))

;; ── Cargo.toml VR feature ───────────────────────────────────

(ert-deftest week7-integration/cargo-has-vr-feature ()
  "Cargo.toml has vr feature flag."
  (let ((cargo (expand-file-name "compositor/Cargo.toml"
                                  (locate-dominating-file default-directory ".git"))))
    (with-temp-buffer
      (insert-file-contents cargo)
      (should (search-forward "vr = [" nil t)))))

(ert-deftest week7-integration/cargo-has-openxrs-dep ()
  "Cargo.toml has openxrs optional dependency."
  (let ((cargo (expand-file-name "compositor/Cargo.toml"
                                  (locate-dominating-file default-directory ".git"))))
    (with-temp-buffer
      (insert-file-contents cargo)
      (should (search-forward "openxrs" nil t)))))

;; ── Emacs VR module ─────────────────────────────────────────

(ert-deftest week7-integration/ewwm-vr-provides ()
  "ewwm-vr provides its feature."
  (should (featurep 'ewwm-vr)))

(ert-deftest week7-integration/ewwm-vr-commands ()
  "All VR interactive commands exist."
  (should (commandp 'ewwm-vr-status))
  (should (commandp 'ewwm-vr-set-reference-space))
  (should (commandp 'ewwm-vr-restart))
  (should (commandp 'ewwm-vr-frame-timing)))

(ert-deftest week7-integration/ewwm-vr-state-vars ()
  "All VR state variables are bound."
  (should (boundp 'ewwm-vr-session-state))
  (should (boundp 'ewwm-vr-hmd-name))
  (should (boundp 'ewwm-vr-hmd-info))
  (should (boundp 'ewwm-vr-headless))
  (should (boundp 'ewwm-vr-frame-stats))
  (should (boundp 'ewwm-vr-enabled)))

(ert-deftest week7-integration/ewwm-vr-customizations ()
  "VR defcustoms exist with correct defaults."
  (should (eq (default-value 'ewwm-vr-reference-space) 'local))
  (should (eq (default-value 'ewwm-vr-mode-line) t))
  (should (= (default-value 'ewwm-vr-frame-stats-interval) 5)))

(ert-deftest week7-integration/ewwm-vr-hook-exists ()
  "VR session state hook variable exists."
  (should (boundp 'ewwm-vr-session-state-hook)))

;; ── IPC dispatch VR commands ────────────────────────────────

(ert-deftest week7-integration/ipc-dispatch-has-vr-commands ()
  "IPC dispatch handles VR message types."
  (let ((dispatch-file (expand-file-name "compositor/src/ipc/dispatch.rs"
                                          (locate-dominating-file default-directory ".git"))))
    (with-temp-buffer
      (insert-file-contents dispatch-file)
      (should (search-forward "\"vr-status\"" nil t))
      (goto-char (point-min))
      (should (search-forward "\"vr-set-reference-space\"" nil t))
      (goto-char (point-min))
      (should (search-forward "\"vr-restart\"" nil t))
      (goto-char (point-min))
      (should (search-forward "\"vr-get-frame-timing\"" nil t)))))

;; ── VR state in compositor ──────────────────────────────────

(ert-deftest week7-integration/state-has-vr-field ()
  "Compositor state.rs has vr_state field."
  (let ((state-file (expand-file-name "compositor/src/state.rs"
                                       (locate-dominating-file default-directory ".git"))))
    (with-temp-buffer
      (insert-file-contents state-file)
      (should (search-forward "vr_state" nil t)))))

(ert-deftest week7-integration/main-has-vr-mod ()
  "Compositor lib.rs declares vr module."
  (let ((lib-file (expand-file-name "compositor/src/lib.rs"
                                     (locate-dominating-file default-directory ".git"))))
    (with-temp-buffer
      (insert-file-contents lib-file)
      (should (search-forward "pub mod vr;" nil t)))))

;;; week7-integration-test.el ends here
