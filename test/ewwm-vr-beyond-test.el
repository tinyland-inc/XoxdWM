;;; ewwm-vr-beyond-test.el --- Tests for Bigscreen Beyond control  -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ewwm-core)
(require 'ewwm-vr-beyond)

;; Forward-declare so `let' creates dynamic binding (needed for `boundp')
(defvar ewwm-ipc--event-handlers)

;; Provide ewwm-ipc-register-events if not already loaded, so event
;; registration tests work in batch mode without loading the full IPC layer.
(unless (fboundp 'ewwm-ipc-register-events)
  (defun ewwm-ipc-register-events (handlers)
    "Stub for test: push HANDLERS onto ewwm-ipc--event-handlers."
    (when (boundp 'ewwm-ipc--event-handlers)
      (dolist (h handlers)
        (unless (assq (car h) ewwm-ipc--event-handlers)
          (push h ewwm-ipc--event-handlers))))))

;; ── Defcustoms ──────────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-default-brightness-defcustom ()
  "Default brightness is 70."
  (should (= (default-value 'ewwm-vr-beyond-default-brightness) 70)))

(ert-deftest ewwm-vr-beyond-test-default-fan-speed-defcustom ()
  "Default fan speed is 60."
  (should (= (default-value 'ewwm-vr-beyond-default-fan-speed) 60)))

(ert-deftest ewwm-vr-beyond-test-led-color-defcustom ()
  "Default LED color is (0 255 128)."
  (should (equal (default-value 'ewwm-vr-beyond-led-color) '(0 255 128))))

(ert-deftest ewwm-vr-beyond-test-auto-power-on-defcustom ()
  "Auto power-on defaults to t."
  (should (eq (default-value 'ewwm-vr-beyond-auto-power-on) t)))

(ert-deftest ewwm-vr-beyond-test-mode-line-defcustom ()
  "Mode-line display defaults to t."
  (should (eq (default-value 'ewwm-vr-beyond-mode-line) t)))

;; ── Variables ───────────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-connected-variable-exists ()
  "ewwm-vr-beyond--connected variable exists."
  (should (boundp 'ewwm-vr-beyond--connected)))

(ert-deftest ewwm-vr-beyond-test-brightness-variable-exists ()
  "ewwm-vr-beyond--brightness variable exists."
  (should (boundp 'ewwm-vr-beyond--brightness)))

(ert-deftest ewwm-vr-beyond-test-fan-speed-variable-exists ()
  "ewwm-vr-beyond--fan-speed variable exists."
  (should (boundp 'ewwm-vr-beyond--fan-speed)))

(ert-deftest ewwm-vr-beyond-test-display-powered-variable-exists ()
  "ewwm-vr-beyond--display-powered variable exists."
  (should (boundp 'ewwm-vr-beyond--display-powered)))

(ert-deftest ewwm-vr-beyond-test-serial-variable-exists ()
  "ewwm-vr-beyond--serial variable exists."
  (should (boundp 'ewwm-vr-beyond--serial)))

;; ── Interactive commands ────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-power-on-interactive ()
  "ewwm-vr-beyond-power-on is interactive."
  (should (commandp 'ewwm-vr-beyond-power-on)))

(ert-deftest ewwm-vr-beyond-test-set-brightness-interactive ()
  "ewwm-vr-beyond-set-brightness is interactive."
  (should (commandp 'ewwm-vr-beyond-set-brightness)))

(ert-deftest ewwm-vr-beyond-test-set-fan-speed-interactive ()
  "ewwm-vr-beyond-set-fan-speed is interactive."
  (should (commandp 'ewwm-vr-beyond-set-fan-speed)))

(ert-deftest ewwm-vr-beyond-test-set-led-color-interactive ()
  "ewwm-vr-beyond-set-led-color is interactive."
  (should (commandp 'ewwm-vr-beyond-set-led-color)))

(ert-deftest ewwm-vr-beyond-test-status-interactive ()
  "ewwm-vr-beyond-status is interactive."
  (should (commandp 'ewwm-vr-beyond-status)))

(ert-deftest ewwm-vr-beyond-test-detect-interactive ()
  "ewwm-vr-beyond-detect is interactive."
  (should (commandp 'ewwm-vr-beyond-detect)))

;; ── Brightness validation ───────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-brightness-valid-low ()
  "Setting brightness to 0 succeeds."
  (let ((ewwm-vr-beyond--brightness nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
      (ewwm-vr-beyond-set-brightness 0)
      (should (= ewwm-vr-beyond--brightness 0)))))

(ert-deftest ewwm-vr-beyond-test-brightness-valid-high ()
  "Setting brightness to 100 succeeds."
  (let ((ewwm-vr-beyond--brightness nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
      (ewwm-vr-beyond-set-brightness 100)
      (should (= ewwm-vr-beyond--brightness 100)))))

(ert-deftest ewwm-vr-beyond-test-brightness-valid-mid ()
  "Setting brightness to 50 succeeds."
  (let ((ewwm-vr-beyond--brightness nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
      (ewwm-vr-beyond-set-brightness 50)
      (should (= ewwm-vr-beyond--brightness 50)))))

(ert-deftest ewwm-vr-beyond-test-brightness-reject-negative ()
  "Setting brightness below 0 signals user-error."
  (should-error (ewwm-vr-beyond-set-brightness -1) :type 'user-error))

(ert-deftest ewwm-vr-beyond-test-brightness-reject-over-100 ()
  "Setting brightness above 100 signals user-error."
  (should-error (ewwm-vr-beyond-set-brightness 101) :type 'user-error))

;; ── Fan speed validation ────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-fan-speed-valid-low ()
  "Setting fan speed to 40 succeeds."
  (let ((ewwm-vr-beyond--fan-speed nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
      (ewwm-vr-beyond-set-fan-speed 40)
      (should (= ewwm-vr-beyond--fan-speed 40)))))

(ert-deftest ewwm-vr-beyond-test-fan-speed-valid-high ()
  "Setting fan speed to 100 succeeds."
  (let ((ewwm-vr-beyond--fan-speed nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
      (ewwm-vr-beyond-set-fan-speed 100)
      (should (= ewwm-vr-beyond--fan-speed 100)))))

(ert-deftest ewwm-vr-beyond-test-fan-speed-reject-below-40 ()
  "Setting fan speed below 40 signals user-error."
  (should-error (ewwm-vr-beyond-set-fan-speed 39) :type 'user-error))

(ert-deftest ewwm-vr-beyond-test-fan-speed-reject-over-100 ()
  "Setting fan speed above 100 signals user-error."
  (should-error (ewwm-vr-beyond-set-fan-speed 101) :type 'user-error))

;; ── LED color validation ────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-led-color-valid ()
  "Setting LED color (128 64 32) succeeds."
  (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
            ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
    (ewwm-vr-beyond-set-led-color 128 64 32)))

(ert-deftest ewwm-vr-beyond-test-led-color-reject-red-over ()
  "Setting LED with red > 255 signals user-error."
  (should-error (ewwm-vr-beyond-set-led-color 256 0 0) :type 'user-error))

(ert-deftest ewwm-vr-beyond-test-led-color-reject-green-negative ()
  "Setting LED with green < 0 signals user-error."
  (should-error (ewwm-vr-beyond-set-led-color 0 -1 0) :type 'user-error))

(ert-deftest ewwm-vr-beyond-test-led-color-reject-blue-over ()
  "Setting LED with blue > 255 signals user-error."
  (should-error (ewwm-vr-beyond-set-led-color 0 0 256) :type 'user-error))

(ert-deftest ewwm-vr-beyond-test-led-color-boundary-zeros ()
  "Setting LED color (0 0 0) succeeds."
  (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
            ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
    (ewwm-vr-beyond-set-led-color 0 0 0)))

(ert-deftest ewwm-vr-beyond-test-led-color-boundary-max ()
  "Setting LED color (255 255 255) succeeds."
  (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
            ((symbol-function 'ewwm-ipc-send) (lambda (_msg) 1)))
    (ewwm-vr-beyond-set-led-color 255 255 255)))

;; ── IPC command formatting ──────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-ipc-brightness-format ()
  "Brightness IPC sends correct plist."
  (let ((ewwm-vr-beyond--brightness nil)
        (sent nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (msg) (setq sent msg) 1)))
      (ewwm-vr-beyond-set-brightness 75)
      (should (equal sent '(:type :beyond-set-brightness :value 75))))))

(ert-deftest ewwm-vr-beyond-test-ipc-fan-speed-format ()
  "Fan speed IPC sends correct plist."
  (let ((ewwm-vr-beyond--fan-speed nil)
        (sent nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (msg) (setq sent msg) 1)))
      (ewwm-vr-beyond-set-fan-speed 80)
      (should (equal sent '(:type :beyond-set-fan-speed :value 80))))))

(ert-deftest ewwm-vr-beyond-test-ipc-led-color-format ()
  "LED color IPC sends correct plist."
  (let ((sent nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (msg) (setq sent msg) 1)))
      (ewwm-vr-beyond-set-led-color 10 20 30)
      (should (equal sent '(:type :beyond-set-led-color :r 10 :g 20 :b 30))))))

(ert-deftest ewwm-vr-beyond-test-ipc-power-on-format ()
  "Power-on IPC sends correct plist."
  (let ((ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--display-powered nil)
        (sent nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (msg) (setq sent msg) 1)))
      (ewwm-vr-beyond-power-on)
      (should (equal sent '(:type :beyond-power-on))))))

;; ── Mode-line string ────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-mode-line-connected-powered ()
  "Mode-line shows brightness when connected and powered."
  (let ((ewwm-vr-beyond-mode-line t)
        (ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--display-powered t)
        (ewwm-vr-beyond--brightness 70))
    (should (equal (ewwm-vr-beyond-mode-line-string) " BSB[70%]"))))

(ert-deftest ewwm-vr-beyond-test-mode-line-connected-unpowered ()
  "Mode-line shows exclamation when display is off."
  (let ((ewwm-vr-beyond-mode-line t)
        (ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--display-powered nil)
        (ewwm-vr-beyond--brightness 70))
    (should (equal (ewwm-vr-beyond-mode-line-string) " BSB[70%!]"))))

(ert-deftest ewwm-vr-beyond-test-mode-line-disconnected ()
  "Mode-line returns nil when not connected."
  (let ((ewwm-vr-beyond-mode-line t)
        (ewwm-vr-beyond--connected nil))
    (should-not (ewwm-vr-beyond-mode-line-string))))

(ert-deftest ewwm-vr-beyond-test-mode-line-disabled ()
  "Mode-line returns nil when ewwm-vr-beyond-mode-line is nil."
  (let ((ewwm-vr-beyond-mode-line nil)
        (ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--display-powered t)
        (ewwm-vr-beyond--brightness 70))
    (should-not (ewwm-vr-beyond-mode-line-string))))

(ert-deftest ewwm-vr-beyond-test-mode-line-unknown-brightness ()
  "Mode-line shows ? when brightness is unknown."
  (let ((ewwm-vr-beyond-mode-line t)
        (ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--display-powered t)
        (ewwm-vr-beyond--brightness nil))
    (should (equal (ewwm-vr-beyond-mode-line-string) " BSB[?%]"))))

;; ── Status parsing ──────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-status-parse-full ()
  "Parsing a full status plist updates all state."
  (let ((ewwm-vr-beyond--connected nil)
        (ewwm-vr-beyond--brightness nil)
        (ewwm-vr-beyond--fan-speed nil)
        (ewwm-vr-beyond--display-powered nil)
        (ewwm-vr-beyond--serial nil))
    (ewwm-vr-beyond--on-status
     '(:brightness 85 :fan-speed 70 :display-powered t :serial "BSB-2E-001"))
    (should (= ewwm-vr-beyond--brightness 85))
    (should (= ewwm-vr-beyond--fan-speed 70))
    (should ewwm-vr-beyond--display-powered)
    (should (equal ewwm-vr-beyond--serial "BSB-2E-001"))))

(ert-deftest ewwm-vr-beyond-test-status-parse-partial ()
  "Parsing a partial status plist updates only present fields."
  (let ((ewwm-vr-beyond--brightness 50)
        (ewwm-vr-beyond--fan-speed 60)
        (ewwm-vr-beyond--display-powered nil)
        (ewwm-vr-beyond--serial "old-serial"))
    (ewwm-vr-beyond--on-status '(:brightness 90))
    (should (= ewwm-vr-beyond--brightness 90))
    ;; fan-speed should remain unchanged since not in msg
    (should (= ewwm-vr-beyond--fan-speed 60))))

;; ── Auto-power-on logic ────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-connect-auto-power-on ()
  "On connect, auto-power-on sends power-on when flag is t."
  (let ((ewwm-vr-beyond--connected nil)
        (ewwm-vr-beyond--serial nil)
        (ewwm-vr-beyond--display-powered nil)
        (ewwm-vr-beyond-auto-power-on t)
        (ewwm-vr-beyond-connected-hook nil)
        (power-sent nil))
    ;; Mock: power-on requires --connected=t and IPC
    ;; on-connected sets connected=t first, then the minor mode body
    ;; would call power-on.  Here we test the event handler directly.
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (msg) (setq power-sent msg) 1)))
      ;; Simulate minor mode auto-power path: after connect, if auto-power-on
      ;; and connected, ewwm-vr-beyond-power-on is called.
      (ewwm-vr-beyond--on-connected '(:serial "BSB-001"))
      (should ewwm-vr-beyond--connected)
      ;; Now simulate what the minor mode would do
      (when (and ewwm-vr-beyond-auto-power-on
                 ewwm-vr-beyond--connected)
        (ewwm-vr-beyond-power-on))
      (should (equal power-sent '(:type :beyond-power-on))))))

(ert-deftest ewwm-vr-beyond-test-connect-no-auto-power ()
  "On connect, no power-on sent when auto-power-on is nil."
  (let ((ewwm-vr-beyond--connected nil)
        (ewwm-vr-beyond--serial nil)
        (ewwm-vr-beyond-auto-power-on nil)
        (ewwm-vr-beyond-connected-hook nil)
        (power-sent nil))
    (cl-letf (((symbol-function 'ewwm-ipc-connected-p) (lambda () t))
              ((symbol-function 'ewwm-ipc-send) (lambda (msg) (setq power-sent msg) 1)))
      (ewwm-vr-beyond--on-connected '(:serial "BSB-001"))
      (should ewwm-vr-beyond--connected)
      ;; Simulate what the minor mode would check
      (when (and ewwm-vr-beyond-auto-power-on
                 ewwm-vr-beyond--connected)
        (ewwm-vr-beyond-power-on))
      ;; Should NOT have sent power-on
      (should-not power-sent))))

;; ── Minor mode toggle ───────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-minor-mode-exists ()
  "ewwm-vr-beyond-mode minor mode exists."
  (should (fboundp 'ewwm-vr-beyond-mode)))

;; ── State reset on disconnect ───────────────────────────────

(ert-deftest ewwm-vr-beyond-test-disconnect-clears-state ()
  "Disconnect event clears all internal state."
  (let ((ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--brightness 70)
        (ewwm-vr-beyond--fan-speed 60)
        (ewwm-vr-beyond--display-powered t)
        (ewwm-vr-beyond--serial "BSB-001")
        (ewwm-vr-beyond-disconnected-hook nil))
    (ewwm-vr-beyond--on-disconnected nil)
    (should-not ewwm-vr-beyond--connected)
    (should-not ewwm-vr-beyond--brightness)
    (should-not ewwm-vr-beyond--fan-speed)
    (should-not ewwm-vr-beyond--display-powered)
    (should-not ewwm-vr-beyond--serial)))

(ert-deftest ewwm-vr-beyond-test-disconnect-runs-hook ()
  "Disconnect event runs the disconnect hook."
  (let ((ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--brightness nil)
        (ewwm-vr-beyond--fan-speed nil)
        (ewwm-vr-beyond--display-powered nil)
        (ewwm-vr-beyond--serial nil)
        (hook-ran nil))
    (let ((ewwm-vr-beyond-disconnected-hook (list (lambda () (setq hook-ran t)))))
      (ewwm-vr-beyond--on-disconnected nil)
      (should hook-ran))))

;; ── Connect event ───────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-connect-sets-state ()
  "Connect event sets connected and serial."
  (let ((ewwm-vr-beyond--connected nil)
        (ewwm-vr-beyond--serial nil)
        (ewwm-vr-beyond-connected-hook nil))
    (ewwm-vr-beyond--on-connected '(:serial "BSB-2E-042"))
    (should ewwm-vr-beyond--connected)
    (should (equal ewwm-vr-beyond--serial "BSB-2E-042"))))

(ert-deftest ewwm-vr-beyond-test-connect-runs-hook ()
  "Connect event runs the connect hook."
  (let ((ewwm-vr-beyond--connected nil)
        (ewwm-vr-beyond--serial nil)
        (hook-ran nil))
    (let ((ewwm-vr-beyond-connected-hook (list (lambda () (setq hook-ran t)))))
      (ewwm-vr-beyond--on-connected '(:serial "BSB-001"))
      (should hook-ran))))

;; ── Event registration ──────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-register-events ()
  "ewwm-vr-beyond--register-events adds handlers."
  (let ((ewwm-ipc--event-handlers nil))
    (ewwm-vr-beyond--register-events)
    (should (assq :beyond-status ewwm-ipc--event-handlers))
    (should (assq :beyond-connected ewwm-ipc--event-handlers))
    (should (assq :beyond-disconnected ewwm-ipc--event-handlers))))

(ert-deftest ewwm-vr-beyond-test-register-events-idempotent ()
  "Calling register twice doesn't duplicate."
  (let ((ewwm-ipc--event-handlers nil))
    (ewwm-vr-beyond--register-events)
    (ewwm-vr-beyond--register-events)
    (should (= (length (cl-remove-if-not
                        (lambda (pair) (eq (car pair) :beyond-status))
                        ewwm-ipc--event-handlers))
               1))))

;; ── Init / teardown ─────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-init-sets-defaults ()
  "ewwm-vr-beyond-init sets brightness and fan from defcustoms."
  (let ((ewwm-vr-beyond--brightness nil)
        (ewwm-vr-beyond--fan-speed nil)
        (ewwm-ipc--event-handlers nil))
    (ewwm-vr-beyond-init)
    (should (= ewwm-vr-beyond--brightness 70))
    (should (= ewwm-vr-beyond--fan-speed 60))))

(ert-deftest ewwm-vr-beyond-test-teardown-clears-state ()
  "ewwm-vr-beyond-teardown clears all state."
  (let ((ewwm-vr-beyond--connected t)
        (ewwm-vr-beyond--brightness 70)
        (ewwm-vr-beyond--fan-speed 60)
        (ewwm-vr-beyond--display-powered t)
        (ewwm-vr-beyond--serial "BSB-001"))
    (ewwm-vr-beyond-teardown)
    (should-not ewwm-vr-beyond--connected)
    (should-not ewwm-vr-beyond--brightness)
    (should-not ewwm-vr-beyond--fan-speed)
    (should-not ewwm-vr-beyond--display-powered)
    (should-not ewwm-vr-beyond--serial)))

;; ── Hooks exist ─────────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-connected-hook-exists ()
  "Connected hook variable exists."
  (should (boundp 'ewwm-vr-beyond-connected-hook)))

(ert-deftest ewwm-vr-beyond-test-disconnected-hook-exists ()
  "Disconnected hook variable exists."
  (should (boundp 'ewwm-vr-beyond-disconnected-hook)))

;; ── Power-on requires connection ────────────────────────────

(ert-deftest ewwm-vr-beyond-test-power-on-requires-connection ()
  "Power-on signals user-error when not connected."
  (let ((ewwm-vr-beyond--connected nil))
    (should-error (ewwm-vr-beyond-power-on) :type 'user-error)))

;; ── Provides ────────────────────────────────────────────────

(ert-deftest ewwm-vr-beyond-test-provides-feature ()
  "ewwm-vr-beyond provides its feature."
  (should (featurep 'ewwm-vr-beyond)))

;;; ewwm-vr-beyond-test.el ends here
