;;; phase3-vr-patterns-test.el --- Tests for v0.5.0 Phase 3 VR patterns  -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for ewwm-vr-follow.el, ewwm-vr-focus-routing.el, and
;; ewwm-vr-passthrough.el (v0.5.0 Phase 3 — VR implementable patterns).

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Capture project root at load time
(defvar phase3-test--project-root
  (let* ((this-file (or load-file-name buffer-file-name))
         (test-dir (and this-file (file-name-directory this-file))))
    (if test-dir
        (file-name-directory (directory-file-name test-dir))
      default-directory))
  "Project root directory, captured at load time.")

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-follow tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-follow)

(ert-deftest phase3/follow-provides-feature ()
  "ewwm-vr-follow provides its feature."
  (should (featurep 'ewwm-vr-follow)))

(ert-deftest phase3/follow-group-exists ()
  "ewwm-vr-follow customization group exists."
  (should (get 'ewwm-vr-follow 'custom-group)))

(ert-deftest phase3/follow-policy-defcustom ()
  "Follow policy defaults to threshold-only."
  (should (equal (default-value 'ewwm-vr-follow-policy) "threshold-only")))

(ert-deftest phase3/follow-h-fov-defcustom ()
  "H-FOV threshold defaults to 80.0."
  (should (= (default-value 'ewwm-vr-follow-h-fov) 80.0)))

(ert-deftest phase3/follow-v-fov-defcustom ()
  "V-FOV threshold defaults to 60.0."
  (should (= (default-value 'ewwm-vr-follow-v-fov) 60.0)))

(ert-deftest phase3/follow-speed-defcustom ()
  "Follow speed defaults to 0.15."
  (should (= (default-value 'ewwm-vr-follow-speed) 0.15)))

(ert-deftest phase3/follow-distance-defcustom ()
  "Follow distance defaults to 1.5."
  (should (= (default-value 'ewwm-vr-follow-distance) 1.5)))

(ert-deftest phase3/follow-suppress-reading-defcustom ()
  "Suppress during reading defaults to t."
  (should (eq (default-value 'ewwm-vr-follow-suppress-reading) t)))

(ert-deftest phase3/follow-commands-interactive ()
  "Follow mode commands are interactive."
  (should (commandp 'ewwm-vr-follow-set-policy))
  (should (commandp 'ewwm-vr-follow-recenter))
  (should (commandp 'ewwm-vr-follow-grab-all))
  (should (commandp 'ewwm-vr-follow-toggle))
  (should (commandp 'ewwm-vr-follow-status)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-focus-routing tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-focus-routing)

(ert-deftest phase3/focus-routing-provides-feature ()
  "ewwm-vr-focus-routing provides its feature."
  (should (featurep 'ewwm-vr-focus-routing)))

(ert-deftest phase3/focus-routing-group-exists ()
  "ewwm-vr-focus-routing customization group exists."
  (should (get 'ewwm-vr-focus-routing 'custom-group)))

(ert-deftest phase3/focus-routing-mode-defcustom ()
  "Routing mode defaults to gaze-primary."
  (should (equal (default-value 'ewwm-vr-focus-routing-mode) "gaze-primary")))

(ert-deftest phase3/focus-routing-dwell-defcustom ()
  "Dwell time defaults to 400ms."
  (should (= (default-value 'ewwm-vr-focus-routing-dwell-ms) 400)))

(ert-deftest phase3/focus-routing-confirm-visual-defcustom ()
  "Confirm visual defaults to t."
  (should (eq (default-value 'ewwm-vr-focus-routing-confirm-visual) t)))

(ert-deftest phase3/focus-routing-ignore-transients-defcustom ()
  "Ignore transients defaults to t."
  (should (eq (default-value 'ewwm-vr-focus-routing-ignore-transients) t)))

(ert-deftest phase3/focus-routing-commands-interactive ()
  "Focus routing commands are interactive."
  (should (commandp 'ewwm-vr-focus-routing-set-mode))
  (should (commandp 'ewwm-vr-focus-routing-set-dwell))
  (should (commandp 'ewwm-vr-focus-routing-toggle))
  (should (commandp 'ewwm-vr-focus-routing-status)))

(ert-deftest phase3/focus-routing-hook-exists ()
  "Focus routing changed hook exists."
  (should (boundp 'ewwm-vr-focus-routing-changed-hook)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-vr-passthrough tests
;; ══════════════════════════════════════════════════════════════

(require 'ewwm-vr-passthrough)

(ert-deftest phase3/passthrough-provides-feature ()
  "ewwm-vr-passthrough provides its feature."
  (should (featurep 'ewwm-vr-passthrough)))

(ert-deftest phase3/passthrough-group-exists ()
  "ewwm-vr-passthrough customization group exists."
  (should (get 'ewwm-vr-passthrough 'custom-group)))

(ert-deftest phase3/passthrough-blend-mode-defcustom ()
  "Blend mode defaults to opaque."
  (should (equal (default-value 'ewwm-vr-passthrough-blend-mode) "opaque")))

(ert-deftest phase3/passthrough-opacity-defcustom ()
  "Opacity defaults to 1.0."
  (should (= (default-value 'ewwm-vr-passthrough-opacity) 1.0)))

(ert-deftest phase3/passthrough-commands-interactive ()
  "Passthrough commands are interactive."
  (should (commandp 'ewwm-vr-passthrough-enable))
  (should (commandp 'ewwm-vr-passthrough-disable))
  (should (commandp 'ewwm-vr-passthrough-toggle))
  (should (commandp 'ewwm-vr-passthrough-set-blend-mode))
  (should (commandp 'ewwm-vr-passthrough-set-opacity))
  (should (commandp 'ewwm-vr-passthrough-status)))

;; ── Compositor handler file checks ──────────────────────────

(ert-deftest phase3/follow-mode-handler-exists ()
  "Follow mode handler file exists."
  (should (file-exists-p
           (expand-file-name "compositor/src/vr/follow_mode.rs"
                             phase3-test--project-root))))

(provide 'phase3-vr-patterns-test)
;;; phase3-vr-patterns-test.el ends here
