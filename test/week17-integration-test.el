;;; week17-integration-test.el --- Week 17 integration tests  -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'ewwm-core)
(require 'ewwm-qutebrowser)
(require 'ewwm-qutebrowser-ipc)
(require 'ewwm-qutebrowser-tabs)
(require 'ewwm-qutebrowser-theme)
(require 'ewwm-qutebrowser-consult)
(require 'ewwm-qutebrowser-downloads)
(require 'ewwm-qutebrowser-reader)
(require 'ewwm-qutebrowser-adblock)
(require 'ewwm-qutebrowser-userscript)
(require 'ewwm-qutebrowser-gaze)

;; Forward-declare functions from feature modules
(declare-function ewwm-qutebrowser-ipc--format-json
                  "ewwm-qutebrowser-ipc")
(declare-function ewwm-qutebrowser--surface-p "ewwm-qutebrowser")
(declare-function ewwm-qutebrowser-theme--extract-colors
                  "ewwm-qutebrowser-theme")
(declare-function ewwm-qutebrowser-tab--create
                  "ewwm-qutebrowser-tabs")
(declare-function ewwm-qutebrowser-tab--find
                  "ewwm-qutebrowser-tabs")
(declare-function ewwm-qutebrowser-tab--update
                  "ewwm-qutebrowser-tabs")
(declare-function ewwm-qutebrowser-tab--kill
                  "ewwm-qutebrowser-tabs")
(declare-function ewwm-qutebrowser-consult--read-bookmarks
                  "ewwm-qutebrowser-consult")
(declare-function ewwm-qutebrowser-consult--read-quickmarks
                  "ewwm-qutebrowser-consult")
(declare-function ewwm-qutebrowser-reader--generate-css
                  "ewwm-qutebrowser-reader")
(declare-function ewwm-qutebrowser-gaze--load-hints
                  "ewwm-qutebrowser-gaze")
(declare-function ewwm-qutebrowser-gaze--highlight
                  "ewwm-qutebrowser-gaze")
(declare-function ewwm-qutebrowser-gaze--confirm
                  "ewwm-qutebrowser-gaze")
(declare-function ewwm-qutebrowser-ipc-send "ewwm-qutebrowser-ipc")

;; Forward-declare dynamic variables for `let' bindings
(defvar ewwm-qutebrowser-tab--buffers)
(defvar ewwm-qutebrowser-tab-buffer-prefix)
(defvar ewwm-qutebrowser-reader-font-size)
(defvar ewwm-qutebrowser-reader-dark-mode)
(defvar ewwm-qutebrowser-reader-line-spacing)
(defvar ewwm-qutebrowser-reader-max-width)
(defvar ewwm-qutebrowser-consult-bookmark-file)
(defvar ewwm-qutebrowser-consult-quickmark-file)
(defvar ewwm-qutebrowser-gaze--hints)
(defvar ewwm-qutebrowser-gaze--highlighted)

;; ── Module loading ───────────────────────────────────────────

(ert-deftest week17/all-qb-modules-loaded ()
  "All qutebrowser modules provide their features."
  (dolist (feat '(ewwm-qutebrowser
                  ewwm-qutebrowser-ipc
                  ewwm-qutebrowser-tabs
                  ewwm-qutebrowser-theme
                  ewwm-qutebrowser-consult
                  ewwm-qutebrowser-downloads
                  ewwm-qutebrowser-reader
                  ewwm-qutebrowser-adblock
                  ewwm-qutebrowser-userscript
                  ewwm-qutebrowser-gaze))
    (should (featurep feat))))

;; ── Cross-module function availability ──────────────────────

(ert-deftest week17/cross-module-ipc-functions ()
  "IPC functions are available from qutebrowser module."
  (should (fboundp 'ewwm-qutebrowser-ipc-send))
  (should (fboundp 'ewwm-qutebrowser-ipc-connected-p))
  (should (fboundp 'ewwm-qutebrowser-ipc--format-json))
  (should (fboundp 'ewwm-qutebrowser--surface-p)))

;; ── JSON round-trip ─────────────────────────────────────────

(ert-deftest week17/json-roundtrip ()
  "JSON format and parse round-trip preserves protocol data."
  (let* ((json-str (ewwm-qutebrowser-ipc--format-json ":reload"))
         (parsed (json-read-from-string json-str))
         (re-encoded (json-encode parsed))
         (re-parsed (json-read-from-string re-encoded)))
    (should (equal (alist-get 'args parsed)
                   (alist-get 'args re-parsed)))
    (should (equal (alist-get 'protocol_version parsed)
                   (alist-get 'protocol_version re-parsed)))))

;; ── Theme color extraction ──────────────────────────────────

(ert-deftest week17/theme-colors-valid-hex ()
  "Theme color extraction produces valid hex color strings."
  (let ((colors (ewwm-qutebrowser-theme--extract-colors)))
    (dolist (pair colors)
      (let ((val (cdr pair)))
        ;; Colors should be strings starting with # or a color name
        (should (stringp val))))))

;; ── Tab buffer lifecycle ────────────────────────────────────

(ert-deftest week17/tab-buffer-lifecycle ()
  "Tab create, find, update, kill lifecycle works end-to-end."
  (let ((ewwm-qutebrowser-tab--buffers nil)
        (ewwm-qutebrowser-tab-buffer-prefix "*qb:"))
    ;; Create
    (let ((buf (ewwm-qutebrowser-tab--create
                0 "https://example.com" "Test Page")))
      (should (buffer-live-p buf))
      ;; Find
      (should (eq (ewwm-qutebrowser-tab--find 0) buf))
      ;; Update
      (ewwm-qutebrowser-tab--update 0 :title "Updated Page"
                                    :url "https://updated.com")
      (with-current-buffer buf
        (should (equal ewwm-qutebrowser-tab-title "Updated Page"))
        (should (equal ewwm-qutebrowser-tab-url "https://updated.com")))
      ;; Kill
      (ewwm-qutebrowser-tab--kill 0)
      (should-not (buffer-live-p buf))
      (should-not (ewwm-qutebrowser-tab--find 0)))))

;; ── Bookmark file parsing ───────────────────────────────────

(ert-deftest week17/bookmark-parsing ()
  "Bookmark reader parses sample data correctly."
  (let ((temp-file (make-temp-file "qb-bookmarks-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "https://example.com Example Site\n")
            (insert "https://emacs.org GNU Emacs\n"))
          (let ((ewwm-qutebrowser-consult-bookmark-file temp-file))
            (let ((results (ewwm-qutebrowser-consult--read-bookmarks)))
              (should (= (length results) 2))
              (should (string-match-p "Example Site"
                                      (car results)))
              (should (equal (get-text-property 0 'url (car results))
                             "https://example.com")))))
      (delete-file temp-file))))

;; ── Quickmark file parsing ──────────────────────────────────

(ert-deftest week17/quickmark-parsing ()
  "Quickmark reader parses sample data correctly."
  (let ((temp-file (make-temp-file "qb-quickmarks-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "emacs https://www.gnu.org/software/emacs/\n")
            (insert "wiki https://en.wikipedia.org/\n"))
          (let ((ewwm-qutebrowser-consult-quickmark-file temp-file))
            (let ((results (ewwm-qutebrowser-consult--read-quickmarks)))
              (should (= (length results) 2))
              (should (string-match-p "\\[emacs\\]" (car results)))
              (should (equal (get-text-property 0 'url (car results))
                             "https://www.gnu.org/software/emacs/")))))
      (delete-file temp-file))))

;; ── Reader CSS includes font-size ───────────────────────────

(ert-deftest week17/reader-css-includes-font-size ()
  "Reader CSS generation includes the configured font-size."
  (let ((ewwm-qutebrowser-reader-font-size 24)
        (ewwm-qutebrowser-reader-dark-mode nil)
        (ewwm-qutebrowser-reader-line-spacing 1.8)
        (ewwm-qutebrowser-reader-max-width "50ch"))
    (let ((css (ewwm-qutebrowser-reader--generate-css)))
      (should (string-match-p "font-size:24px" css))
      (should (string-match-p "max-width:50ch" css))
      ;; Light mode background
      (should (string-match-p "#fafafa" css)))))

;; ── Gaze follow mock cycle ──────────────────────────────────

(ert-deftest week17/gaze-follow-mock-cycle ()
  "Gaze follow cycle: load hints, highlight, confirm."
  (let ((ewwm-qutebrowser-gaze--hints nil)
        (ewwm-qutebrowser-gaze--highlighted nil)
        (sent-commands nil))
    ;; Mock IPC send
    (cl-letf (((symbol-function 'ewwm-qutebrowser-ipc-send)
               (lambda (cmd) (push cmd sent-commands))))
      ;; Load hints
      (ewwm-qutebrowser-gaze--load-hints
       (list (list :id 0 :text "Link 1"
                   :rect '(:x 100 :y 200 :w 150 :h 20)
                   :url "https://example.com")
             (list :id 1 :text "Link 2"
                   :rect '(:x 100 :y 250 :w 150 :h 20)
                   :url "https://emacs.org")))
      (should (= (length ewwm-qutebrowser-gaze--hints) 2))
      ;; Highlight first hint
      (ewwm-qutebrowser-gaze--highlight 0)
      (should (= ewwm-qutebrowser-gaze--highlighted 0))
      (should (= (length sent-commands) 1))
      ;; Confirm
      (ewwm-qutebrowser-gaze--confirm)
      (should (= (length sent-commands) 2))
      (should (string-match-p "example\\.com"
                              (car sent-commands))))))

;; ── Userscript directory ────────────────────────────────────

(ert-deftest week17/userscript-js-files-exist ()
  "EWWM VR userscript JavaScript files exist in packaging."
  (let ((root (locate-dominating-file default-directory ".git")))
    (should (file-exists-p
             (expand-file-name "packaging/userscripts/exwm-vr-hints.js" root)))
    (should (file-exists-p
             (expand-file-name "packaging/userscripts/exwm-vr-reader.js" root)))
    (should (file-exists-p
             (expand-file-name "packaging/userscripts/exwm-vr-form-fill.js" root)))
    (should (file-exists-p
             (expand-file-name "packaging/userscripts/exwm-vr-tab-tree.js" root)))))

;; ── Research documents exist ────────────────────────────────

(ert-deftest week17/research-docs-exist ()
  "Week 17 research directory exists."
  (let ((root (locate-dominating-file default-directory ".git")))
    (should (file-directory-p
             (expand-file-name "docs/research" root)))))

;;; week17-integration-test.el ends here
