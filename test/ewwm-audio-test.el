;;; ewwm-audio-test.el --- Tests for ewwm-audio.el  -*- lexical-binding: t -*-

;;; Commentary:
;; Comprehensive tests for ewwm-audio: volume parsing, defcustom defaults,
;; interactive commands, internal state, and mode-line integration.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ewwm-audio)

;; Capture project root at load time
(defvar audio-test--project-root
  (let* ((this-file (or load-file-name buffer-file-name))
         (test-dir (and this-file (file-name-directory this-file))))
    (if test-dir
        (file-name-directory (directory-file-name test-dir))
      default-directory))
  "Project root directory, captured at load time.")

;; ══════════════════════════════════════════════════════════════
;; Feature and group
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/provides-feature ()
  "ewwm-audio provides its feature."
  (should (featurep 'ewwm-audio)))

(ert-deftest audio/group-exists ()
  "ewwm-audio customization group exists."
  (should (get 'ewwm-audio 'custom-group)))

;; ══════════════════════════════════════════════════════════════
;; Defcustom defaults
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/step-default ()
  "Volume step defaults to 5."
  (should (= (default-value 'ewwm-audio-step) 5)))

(ert-deftest audio/max-volume-default ()
  "Max volume defaults to 150."
  (should (= (default-value 'ewwm-audio-max-volume) 150)))

(ert-deftest audio/wpctl-path-default ()
  "wpctl path defaults to \"wpctl\"."
  (should (equal (default-value 'ewwm-audio-wpctl-path) "wpctl")))

(ert-deftest audio/sink-id-default ()
  "Sink ID defaults to @DEFAULT_AUDIO_SINK@."
  (should (equal (default-value 'ewwm-audio-sink-id) "@DEFAULT_AUDIO_SINK@")))

(ert-deftest audio/source-id-default ()
  "Source ID defaults to @DEFAULT_AUDIO_SOURCE@."
  (should (equal (default-value 'ewwm-audio-source-id) "@DEFAULT_AUDIO_SOURCE@")))

(ert-deftest audio/mode-line-default ()
  "Mode-line display defaults to t."
  (should (eq (default-value 'ewwm-audio-mode-line) t)))

(ert-deftest audio/poll-interval-default ()
  "Poll interval defaults to 5."
  (should (= (default-value 'ewwm-audio-poll-interval) 5)))

;; ══════════════════════════════════════════════════════════════
;; Internal state variables
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/volume-var-exists ()
  "Volume cache variable is bound."
  (should (boundp 'ewwm-audio--volume)))

(ert-deftest audio/muted-var-exists ()
  "Muted cache variable is bound."
  (should (boundp 'ewwm-audio--muted)))

(ert-deftest audio/timer-var-exists ()
  "Timer variable is bound."
  (should (boundp 'ewwm-audio--timer)))

(ert-deftest audio/mode-line-string-var ()
  "Mode-line string variable is bound and is a string."
  (should (boundp 'ewwm-audio--mode-line-string))
  (should (stringp ewwm-audio--mode-line-string)))

;; ══════════════════════════════════════════════════════════════
;; ewwm-audio--parse-volume
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/parse-volume-normal ()
  "Parse normal volume output."
  (let ((result (ewwm-audio--parse-volume "Volume: 0.75")))
    (should (consp result))
    (should (= (car result) 75))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-muted ()
  "Parse muted volume output."
  (let ((result (ewwm-audio--parse-volume "Volume: 0.50 [MUTED]")))
    (should (consp result))
    (should (= (car result) 50))
    (should (eq (cdr result) t))))

(ert-deftest audio/parse-volume-zero ()
  "Parse zero volume output."
  (let ((result (ewwm-audio--parse-volume "Volume: 0.00")))
    (should (consp result))
    (should (= (car result) 0))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-zero-muted ()
  "Parse zero volume muted output."
  (let ((result (ewwm-audio--parse-volume "Volume: 0.00 [MUTED]")))
    (should (consp result))
    (should (= (car result) 0))
    (should (eq (cdr result) t))))

(ert-deftest audio/parse-volume-full ()
  "Parse 100% volume output."
  (let ((result (ewwm-audio--parse-volume "Volume: 1.00")))
    (should (consp result))
    (should (= (car result) 100))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-over-100 ()
  "Parse volume above 100% (amplified)."
  (let ((result (ewwm-audio--parse-volume "Volume: 1.50")))
    (should (consp result))
    (should (= (car result) 150))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-small ()
  "Parse small volume value."
  (let ((result (ewwm-audio--parse-volume "Volume: 0.05")))
    (should (consp result))
    (should (= (car result) 5))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-garbage ()
  "Parse garbage input returns (0 . nil)."
  (let ((result (ewwm-audio--parse-volume "something unexpected")))
    (should (consp result))
    (should (= (car result) 0))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-empty ()
  "Parse empty string returns (0 . nil)."
  (let ((result (ewwm-audio--parse-volume "")))
    (should (consp result))
    (should (= (car result) 0))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-one-digit ()
  "Parse single-digit decimal volume."
  (let ((result (ewwm-audio--parse-volume "Volume: 0.3")))
    (should (consp result))
    (should (= (car result) 30))
    (should (null (cdr result)))))

(ert-deftest audio/parse-volume-integer-format ()
  "Parse integer volume (no decimal)."
  (let ((result (ewwm-audio--parse-volume "Volume: 1")))
    (should (consp result))
    (should (= (car result) 100))
    (should (null (cdr result)))))

;; ══════════════════════════════════════════════════════════════
;; Interactive commands
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/volume-up-interactive ()
  "ewwm-audio-volume-up is an interactive command."
  (should (commandp 'ewwm-audio-volume-up)))

(ert-deftest audio/volume-down-interactive ()
  "ewwm-audio-volume-down is an interactive command."
  (should (commandp 'ewwm-audio-volume-down)))

(ert-deftest audio/mute-toggle-interactive ()
  "ewwm-audio-mute-toggle is an interactive command."
  (should (commandp 'ewwm-audio-mute-toggle)))

(ert-deftest audio/mic-mute-toggle-interactive ()
  "ewwm-audio-mic-mute-toggle is an interactive command."
  (should (commandp 'ewwm-audio-mic-mute-toggle)))

(ert-deftest audio/set-volume-interactive ()
  "ewwm-audio-set-volume is an interactive command."
  (should (commandp 'ewwm-audio-set-volume)))

(ert-deftest audio/status-interactive ()
  "ewwm-audio-status is an interactive command."
  (should (commandp 'ewwm-audio-status)))

(ert-deftest audio/enable-interactive ()
  "ewwm-audio-enable is an interactive command."
  (should (commandp 'ewwm-audio-enable)))

(ert-deftest audio/disable-interactive ()
  "ewwm-audio-disable is an interactive command."
  (should (commandp 'ewwm-audio-disable)))

;; ══════════════════════════════════════════════════════════════
;; Mode-line update logic
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/mode-line-volume-format ()
  "Mode-line shows V:NN% when not muted."
  (let ((ewwm-audio-mode-line t)
        (ewwm-audio--volume 75)
        (ewwm-audio--muted nil))
    (ewwm-audio--update-mode-line)
    (should (equal ewwm-audio--mode-line-string " V:75%"))))

(ert-deftest audio/mode-line-muted-format ()
  "Mode-line shows M:NN% when muted."
  (let ((ewwm-audio-mode-line t)
        (ewwm-audio--volume 50)
        (ewwm-audio--muted t))
    (ewwm-audio--update-mode-line)
    (should (equal ewwm-audio--mode-line-string " M:50%"))))

(ert-deftest audio/mode-line-disabled ()
  "Mode-line string is empty when mode-line display is off."
  (let ((ewwm-audio-mode-line nil)
        (ewwm-audio--volume 50)
        (ewwm-audio--muted nil))
    (ewwm-audio--update-mode-line)
    (should (equal ewwm-audio--mode-line-string ""))))

(ert-deftest audio/mode-line-nil-volume ()
  "Mode-line string is empty when volume is nil."
  (let ((ewwm-audio-mode-line t)
        (ewwm-audio--volume nil)
        (ewwm-audio--muted nil))
    (ewwm-audio--update-mode-line)
    (should (equal ewwm-audio--mode-line-string ""))))

(ert-deftest audio/mode-line-zero-volume ()
  "Mode-line shows V:0% when volume is zero."
  (let ((ewwm-audio-mode-line t)
        (ewwm-audio--volume 0)
        (ewwm-audio--muted nil))
    (ewwm-audio--update-mode-line)
    (should (equal ewwm-audio--mode-line-string " V:0%"))))

;; ══════════════════════════════════════════════════════════════
;; Lifecycle (disable cleans up)
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/disable-clears-timer ()
  "Disabling clears the timer."
  (let ((ewwm-audio--timer (run-with-timer 9999 nil #'ignore)))
    (ewwm-audio-disable)
    (should (null ewwm-audio--timer))))

(ert-deftest audio/disable-clears-mode-line-string ()
  "Disabling clears the mode-line string."
  (let ((ewwm-audio--mode-line-string " V:50%")
        (ewwm-audio--timer nil))
    (ewwm-audio-disable)
    (should (equal ewwm-audio--mode-line-string ""))))

;; ══════════════════════════════════════════════════════════════
;; Function existence checks
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/wpctl-function-exists ()
  "ewwm-audio--wpctl function is defined."
  (should (fboundp 'ewwm-audio--wpctl)))

(ert-deftest audio/wpctl-async-function-exists ()
  "ewwm-audio--wpctl-async function is defined."
  (should (fboundp 'ewwm-audio--wpctl-async)))

(ert-deftest audio/refresh-function-exists ()
  "ewwm-audio-refresh function is defined."
  (should (fboundp 'ewwm-audio-refresh)))

(ert-deftest audio/poll-function-exists ()
  "ewwm-audio--poll function is defined."
  (should (fboundp 'ewwm-audio--poll)))

;; ══════════════════════════════════════════════════════════════
;; Source file exists
;; ══════════════════════════════════════════════════════════════

(ert-deftest audio/source-file-exists ()
  "ewwm-audio.el source file exists."
  (should (file-exists-p
           (expand-file-name "lisp/vr/ewwm-audio.el"
                             audio-test--project-root))))

(provide 'ewwm-audio-test)
;;; ewwm-audio-test.el ends here
