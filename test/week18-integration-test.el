;;; week18-integration-test.el --- Week 18 integration tests  -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ewwm-core)
(require 'ewwm-vr-hand)
(require 'ewwm-vr-gesture)
(require 'ewwm-vr-keyboard)

;; Forward-declare functions from modules under test
(declare-function ewwm-vr-hand--on-tracking-started "ewwm-vr-hand")
(declare-function ewwm-vr-hand--on-tracking-lost "ewwm-vr-hand")
(declare-function ewwm-vr-hand--on-confidence-update "ewwm-vr-hand")
(declare-function ewwm-vr-hand-mode-line-string "ewwm-vr-hand")
(declare-function ewwm-vr-gesture--on-started "ewwm-vr-gesture")
(declare-function ewwm-vr-gesture-bind "ewwm-vr-gesture")
(declare-function ewwm-vr-gesture--lookup "ewwm-vr-gesture")
(declare-function ewwm-vr-keyboard--insert-text "ewwm-vr-keyboard")
(declare-function ewwm-vr-keyboard--on-text-input "ewwm-vr-keyboard")
(declare-function ewwm-vr-keyboard--on-visibility-changed "ewwm-vr-keyboard")
(declare-function ewwm-vr-keyboard-show "ewwm-vr-keyboard")
(declare-function ewwm-vr-keyboard-hide "ewwm-vr-keyboard")
(declare-function ewwm-vr-keyboard-mode-line-string "ewwm-vr-keyboard")
(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")

;; Forward-declare dynamic variables for `let' bindings
(defvar ewwm-vr-hand-enable)
(defvar ewwm-vr-hand--left-active)
(defvar ewwm-vr-hand--right-active)
(defvar ewwm-vr-hand--left-confidence)
(defvar ewwm-vr-hand--right-confidence)
(defvar ewwm-vr-gesture-enable)
(defvar ewwm-vr-gesture--bindings)
(defvar ewwm-vr-gesture--last-gesture)
(defvar ewwm-vr-gesture--last-time)
(defvar ewwm-vr-gesture-verbose)
(defvar ewwm-vr-keyboard--visible)
(defvar ewwm-vr-keyboard-show-hook)
(defvar ewwm-vr-keyboard-hide-hook)

;; ── Module loading ───────────────────────────────────────────

(ert-deftest week18/all-modules-loaded ()
  "All week 18 modules provide their features."
  (dolist (feat '(ewwm-vr-hand
                  ewwm-vr-gesture
                  ewwm-vr-keyboard))
    (should (featurep feat))))

;; ── Cross-module function availability ──────────────────────

(ert-deftest week18/cross-module-hand-functions ()
  "Hand tracking functions are available."
  (should (fboundp 'ewwm-vr-hand-status))
  (should (fboundp 'ewwm-vr-hand-toggle))
  (should (fboundp 'ewwm-vr-hand-configure))
  (should (fboundp 'ewwm-vr-hand-mode-line-string)))

(ert-deftest week18/cross-module-gesture-functions ()
  "Gesture recognition functions are available."
  (should (fboundp 'ewwm-vr-gesture-status))
  (should (fboundp 'ewwm-vr-gesture-toggle))
  (should (fboundp 'ewwm-vr-gesture-bind))
  (should (fboundp 'ewwm-vr-gesture--lookup)))

(ert-deftest week18/cross-module-keyboard-functions ()
  "Virtual keyboard functions are available."
  (should (fboundp 'ewwm-vr-keyboard-show))
  (should (fboundp 'ewwm-vr-keyboard-hide))
  (should (fboundp 'ewwm-vr-keyboard-toggle))
  (should (fboundp 'ewwm-vr-keyboard-set-layout))
  (should (fboundp 'ewwm-vr-keyboard-mode-line-string)))

;; ── Hand tracking + gesture pipeline ────────────────────────

(ert-deftest week18/hand-gesture-pipeline ()
  "Hand tracking start -> confidence -> gesture -> dispatch."
  (let ((ewwm-vr-hand-enable t)
        (ewwm-vr-hand--left-active nil)
        (ewwm-vr-hand--right-active nil)
        (ewwm-vr-hand--left-confidence 0.0)
        (ewwm-vr-hand--right-confidence 0.0)
        (ewwm-vr-gesture-enable t)
        (ewwm-vr-gesture--bindings nil)
        (ewwm-vr-gesture--last-gesture nil)
        (ewwm-vr-gesture--last-time nil)
        (ewwm-vr-gesture-verbose nil)
        (dispatched nil))
    ;; 1. Start hand tracking
    (ewwm-vr-hand--on-tracking-started '(:hand right))
    (should ewwm-vr-hand--right-active)
    ;; 2. Update confidence
    (ewwm-vr-hand--on-confidence-update '(:hand right :confidence 0.9))
    (should (= ewwm-vr-hand--right-confidence 0.9))
    ;; 3. Bind a gesture
    (ewwm-vr-gesture-bind 'right 'pinch (lambda () (setq dispatched t)))
    ;; 4. Trigger gesture -> dispatch command
    (ewwm-vr-gesture--on-started '(:hand right :gesture pinch))
    (should dispatched)))

;; ── Keyboard text input end-to-end ──────────────────────────

(ert-deftest week18/keyboard-text-input-e2e ()
  "Show keyboard -> key events -> text -> hide keyboard."
  (let ((ewwm-vr-keyboard--visible nil)
        (ewwm-vr-keyboard-show-hook nil)
        (ewwm-vr-keyboard-hide-hook nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () nil)))
      ;; 1. Show keyboard
      (ewwm-vr-keyboard-show)
      (should ewwm-vr-keyboard--visible)
      (should (equal (ewwm-vr-keyboard-mode-line-string) " [KB]"))
      ;; 2. Type text
      (with-temp-buffer
        (ewwm-vr-keyboard--on-text-input '(:text "hello "))
        (ewwm-vr-keyboard--on-text-input '(:text "world"))
        (should (equal (buffer-string) "hello world")))
      ;; 3. Hide keyboard
      (ewwm-vr-keyboard-hide)
      (should-not ewwm-vr-keyboard--visible)
      (should-not (ewwm-vr-keyboard-mode-line-string)))))

;; ── Mode-line integration ───────────────────────────────────

(ert-deftest week18/mode-line-all-modules ()
  "Mode-line strings from all modules work together."
  (let ((ewwm-vr-hand-enable t)
        (ewwm-vr-hand--left-active t)
        (ewwm-vr-hand--right-active t)
        (ewwm-vr-keyboard--visible t))
    (should (equal (ewwm-vr-hand-mode-line-string) " [H:L+R]"))
    (should (equal (ewwm-vr-keyboard-mode-line-string) " [KB]"))))

;; ── IPC handler names in dispatch.rs ────────────────────────

(ert-deftest week18/dispatch-rs-has-hand-tracking-commands ()
  "dispatch.rs contains hand tracking IPC command handlers."
  (let* ((root (locate-dominating-file default-directory ".git"))
         (dispatch-file (expand-file-name "compositor/src/ipc/dispatch.rs" root)))
    (when (file-exists-p dispatch-file)
      (let ((contents (with-temp-buffer
                        (insert-file-contents dispatch-file)
                        (buffer-string))))
        (should (string-match-p "hand-tracking-status" contents))
        (should (string-match-p "hand-tracking-config" contents))
        (should (string-match-p "gesture-status" contents))
        (should (string-match-p "gesture-config" contents))
        (should (string-match-p "gesture-bind" contents))
        (should (string-match-p "keyboard-show" contents))
        (should (string-match-p "keyboard-hide" contents))
        (should (string-match-p "keyboard-toggle" contents))
        (should (string-match-p "keyboard-status" contents))))))

;; ── Rust module files exist ─────────────────────────────────

(ert-deftest week18/rust-module-files-exist ()
  "Rust hand tracking module file exists."
  (let ((root (locate-dominating-file default-directory ".git")))
    (should (file-exists-p
             (expand-file-name "compositor/src/vr/hand_tracking.rs" root)))))

;; ── Research documents exist ────────────────────────────────

(ert-deftest week18/research-docs-exist ()
  "Week 18 research directory exists."
  (let ((root (locate-dominating-file default-directory ".git")))
    (should (file-directory-p
             (expand-file-name "docs/research" root)))))

;; ── Elisp module files exist ────────────────────────────────

(ert-deftest week18/elisp-module-files-exist ()
  "Week 18 Elisp module files exist."
  (let ((root (locate-dominating-file default-directory ".git")))
    (should (file-exists-p
             (expand-file-name "lisp/vr/ewwm-vr-hand.el" root)))
    (should (file-exists-p
             (expand-file-name "lisp/vr/ewwm-vr-gesture.el" root)))
    (should (file-exists-p
             (expand-file-name "lisp/vr/ewwm-vr-keyboard.el" root)))))

;;; week18-integration-test.el ends here
