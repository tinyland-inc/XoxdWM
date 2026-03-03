;;; phase2-daily-use-test.el --- Tests for v0.5.0 Phase 2 modules  -*- lexical-binding: t -*-

;;; Commentary:
;; Tests for ewwm-audio.el and ewwm-notify.el (v0.5.0 Phase 2 — daily use).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ewwm-audio)
(require 'ewwm-notify)

;; Capture project root at load time
(defvar phase2-test--project-root
  (let* ((this-file (or load-file-name buffer-file-name))
         (test-dir (and this-file (file-name-directory this-file))))
    (if test-dir
        (file-name-directory (directory-file-name test-dir))
      default-directory))
  "Project root directory, captured at load time.")

;; ══════════════════════════════════════════════════════════════
;; ewwm-audio tests
;; ══════════════════════════════════════════════════════════════

(ert-deftest phase2/audio-provides-feature ()
  "ewwm-audio provides its feature."
  (should (featurep 'ewwm-audio)))

(ert-deftest phase2/audio-group-exists ()
  "ewwm-audio customization group exists."
  (should (get 'ewwm-audio 'custom-group)))

(ert-deftest phase2/audio-step-defcustom ()
  "ewwm-audio-step defaults to 5."
  (should (= (default-value 'ewwm-audio-step) 5)))

(ert-deftest phase2/audio-max-volume-defcustom ()
  "ewwm-audio-max-volume defaults to 150."
  (should (= (default-value 'ewwm-audio-max-volume) 150)))

(ert-deftest phase2/audio-wpctl-path-defcustom ()
  "ewwm-audio-wpctl-path defaults to wpctl."
  (should (equal (default-value 'ewwm-audio-wpctl-path) "wpctl")))

(ert-deftest phase2/audio-poll-interval-defcustom ()
  "ewwm-audio-poll-interval defaults to 5."
  (should (= (default-value 'ewwm-audio-poll-interval) 5)))

(ert-deftest phase2/audio-parse-volume-normal ()
  "Parse normal volume output."
  (let ((parsed (ewwm-audio--parse-volume "Volume: 0.75")))
    (should (= (car parsed) 75))
    (should-not (cdr parsed))))

(ert-deftest phase2/audio-parse-volume-muted ()
  "Parse muted volume output."
  (let ((parsed (ewwm-audio--parse-volume "Volume: 0.50 [MUTED]")))
    (should (= (car parsed) 50))
    (should (cdr parsed))))

(ert-deftest phase2/audio-parse-volume-zero ()
  "Parse zero volume output."
  (let ((parsed (ewwm-audio--parse-volume "Volume: 0.00")))
    (should (= (car parsed) 0))
    (should-not (cdr parsed))))

(ert-deftest phase2/audio-parse-volume-over-100 ()
  "Parse volume over 100%."
  (let ((parsed (ewwm-audio--parse-volume "Volume: 1.20")))
    (should (= (car parsed) 120))
    (should-not (cdr parsed))))

(ert-deftest phase2/audio-parse-volume-invalid ()
  "Parse invalid output returns 0."
  (let ((parsed (ewwm-audio--parse-volume "error: no sink")))
    (should (= (car parsed) 0))))

(ert-deftest phase2/audio-commands-interactive ()
  "Audio commands are interactive."
  (should (commandp 'ewwm-audio-volume-up))
  (should (commandp 'ewwm-audio-volume-down))
  (should (commandp 'ewwm-audio-mute-toggle))
  (should (commandp 'ewwm-audio-mic-mute-toggle))
  (should (commandp 'ewwm-audio-set-volume))
  (should (commandp 'ewwm-audio-status))
  (should (commandp 'ewwm-audio-enable))
  (should (commandp 'ewwm-audio-disable)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-notify tests
;; ══════════════════════════════════════════════════════════════

(ert-deftest phase2/notify-provides-feature ()
  "ewwm-notify provides its feature."
  (should (featurep 'ewwm-notify)))

(ert-deftest phase2/notify-group-exists ()
  "ewwm-notify customization group exists."
  (should (get 'ewwm-notify 'custom-group)))

(ert-deftest phase2/notify-max-history-defcustom ()
  "ewwm-notify-max-history defaults to 100."
  (should (= (default-value 'ewwm-notify-max-history) 100)))

(ert-deftest phase2/notify-timeout-defcustom ()
  "ewwm-notify-timeout-default defaults to 5000."
  (should (= (default-value 'ewwm-notify-timeout-default) 5000)))

(ert-deftest phase2/notify-show-minibuffer-defcustom ()
  "ewwm-notify-show-in-minibuffer defaults to t."
  (should (eq (default-value 'ewwm-notify-show-in-minibuffer) t)))

(ert-deftest phase2/notify-log-buffer-defcustom ()
  "ewwm-notify-log-buffer defaults to *ewwm-notifications*."
  (should (equal (default-value 'ewwm-notify-log-buffer) "*ewwm-notifications*")))

(ert-deftest phase2/notify-urgency-format-defcustom ()
  "ewwm-notify-urgency-format is an alist with 3 entries."
  (let ((fmt (default-value 'ewwm-notify-urgency-format)))
    (should (= (length fmt) 3))
    (should (assoc 0 fmt))
    (should (assoc 1 fmt))
    (should (assoc 2 fmt))))

(ert-deftest phase2/notify-get-capabilities ()
  "GetCapabilities returns expected list."
  (let ((caps (ewwm-notify--get-capabilities)))
    (should (member "body" caps))
    (should (member "persistence" caps))))

(ert-deftest phase2/notify-get-server-information ()
  "GetServerInformation returns expected values."
  (let ((info (ewwm-notify--get-server-information)))
    (should (equal (nth 0 info) "ewwm-notify"))
    (should (equal (nth 1 info) "EXWM-VR"))))

(ert-deftest phase2/notify-history-operations ()
  "Notification history can be added and cleared."
  (let ((ewwm-notify--history nil))
    (push '(1 nil "test" "summary" "body" 1) ewwm-notify--history)
    (should (= (length ewwm-notify--history) 1))
    (setq ewwm-notify--history nil)
    (should (null ewwm-notify--history))))

(ert-deftest phase2/notify-commands-interactive ()
  "Notification commands are interactive."
  (should (commandp 'ewwm-notify-show-history))
  (should (commandp 'ewwm-notify-clear-history))
  (should (commandp 'ewwm-notify-dismiss))
  (should (commandp 'ewwm-notify-dismiss-all))
  (should (commandp 'ewwm-notify-enable))
  (should (commandp 'ewwm-notify-disable)))

;; ── Packaging checks ────────────────────────────────────────

(ert-deftest phase2/portal-config-exists ()
  "Portal config file exists in packaging."
  (let ((root phase2-test--project-root))
    (should (file-exists-p
             (expand-file-name "packaging/desktop/exwm-vr-portals.conf" root)))))

(ert-deftest phase2/session-wrapper-has-wayland-env ()
  "Session wrapper sets Wayland toolkit environment variables."
  (let* ((root phase2-test--project-root)
         (wrapper (expand-file-name "packaging/desktop/exwm-vr-session" root)))
    (when (file-exists-p wrapper)
      (with-temp-buffer
        (insert-file-contents wrapper)
        (should (search-forward "QT_QPA_PLATFORM" nil t))
        (should (search-forward "MOZ_ENABLE_WAYLAND" nil t))))))

(ert-deftest phase2/desktop-file-has-session-type ()
  "Desktop file includes session registration."
  (let* ((root phase2-test--project-root)
         (desktop (expand-file-name "packaging/desktop/exwm-vr.desktop" root)))
    (when (file-exists-p desktop)
      (with-temp-buffer
        (insert-file-contents desktop)
        (should (search-forward "DesktopNames" nil t))))))

(provide 'phase2-daily-use-test)
;;; phase2-daily-use-test.el ends here
