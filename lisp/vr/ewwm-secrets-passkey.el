;;; ewwm-secrets-passkey.el --- WebAuthn/FIDO2 passkey support for EWWM via KeePassXC  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; EXPERIMENTAL (Stage 14.10) — This module is under active development.
;; The API, IPC message format, and browser bridge protocol are all subject
;; to breaking changes without notice.
;;
;; WebAuthn/FIDO2 passkey support for the EWWM secrets subsystem.
;; Bridges navigator.credentials.get() and navigator.credentials.create()
;; requests from Qutebrowser (via userscript) to KeePassXC's passkey
;; storage, using the KeePassXC browser protocol.
;;
;; Architecture:
;;   Qutebrowser userscript  --IPC-->  ewwm-secrets-passkey  --browser-protocol-->  KeePassXC
;;
;; Requirements:
;;   - KeePassXC with browser integration and passkey support enabled
;;   - ewwm-keepassxc-browser module for the native messaging channel
;;   - A Qutebrowser userscript that intercepts WebAuthn API calls

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")
(declare-function ewwm-keepassxc--send-message "ewwm-keepassxc-browser")
(declare-function ewwm-keepassxc--receive-response "ewwm-keepassxc-browser")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-secrets-passkey nil
  "WebAuthn/FIDO2 passkey support for EWWM via KeePassXC.
EXPERIMENTAL (Stage 14.10): this feature is under active development."
  :group 'ewwm)

(defcustom ewwm-secrets-passkeys-enabled t
  "Non-nil to enable WebAuthn/FIDO2 passkey support.
EXPERIMENTAL: when nil, all passkey requests are rejected."
  :type 'boolean
  :group 'ewwm-secrets-passkey)

(defcustom ewwm-secrets-passkey-allow-registration t
  "Non-nil to allow creating new passkeys via navigator.credentials.create().
EXPERIMENTAL: set to nil to restrict to authentication-only mode."
  :type 'boolean
  :group 'ewwm-secrets-passkey)

(defcustom ewwm-secrets-passkey-confirm-registration t
  "Non-nil to prompt the user before creating a new passkey.
EXPERIMENTAL: when non-nil, `y-or-n-p' is called before each registration."
  :type 'boolean
  :group 'ewwm-secrets-passkey)

(defcustom ewwm-secrets-passkey-timeout 60
  "Timeout in seconds for user interaction during passkey operations.
EXPERIMENTAL: applies to both authentication and registration flows."
  :type 'integer
  :group 'ewwm-secrets-passkey)

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-secrets-passkey-register-hook nil
  "Hook run after a passkey is successfully registered.
EXPERIMENTAL: hook functions receive the origin string as argument.")

(defvar ewwm-secrets-passkey-authenticate-hook nil
  "Hook run after a successful passkey authentication.
EXPERIMENTAL: hook functions receive the origin string as argument.")

(defvar ewwm-secrets-passkey-error-hook nil
  "Hook run when a passkey operation encounters an error.
EXPERIMENTAL: hook functions receive the error message string as argument.")

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-secrets-passkey--pending-request nil
  "The current WebAuthn request being processed, or nil.
EXPERIMENTAL: plist with :action, :public-key, :origin, :callback-id.")

(defvar ewwm-secrets-passkey--registered-origins nil
  "List of origin strings with registered passkeys.
EXPERIMENTAL: populated from KeePassXC queries.")

(defvar ewwm-secrets-passkey--active nil
  "Non-nil while a passkey operation is in progress.
EXPERIMENTAL: used to prevent concurrent operations.")

(defvar ewwm-secrets-passkey--events-registered nil
  "Non-nil when IPC event handlers have been registered.
Used by `ewwm-secrets-passkey--register-events' for idempotency.")

;; ── WebAuthn protocol bridge ─────────────────────────────────

(defun ewwm-secrets-passkey-get (public-key-options origin)
  "Handle a navigator.credentials.get() request.
PUBLIC-KEY-OPTIONS is a JSON-decoded alist of the publicKey parameter.
ORIGIN is the requesting origin string (e.g. \"https://example.com\").
Sends the request to KeePassXC via the browser protocol and returns
the assertion response as an alist, or nil on failure.

EXPERIMENTAL (Stage 14.10): protocol format may change."
  (unless ewwm-secrets-passkeys-enabled
    (run-hook-with-args 'ewwm-secrets-passkey-error-hook
                        "Passkey support is disabled")
    (error "ewwm-secrets-passkey: passkey support is disabled"))
  (when ewwm-secrets-passkey--active
    (run-hook-with-args 'ewwm-secrets-passkey-error-hook
                        "Another passkey operation is already in progress")
    (error "ewwm-secrets-passkey: another operation is in progress"))
  (setq ewwm-secrets-passkey--active t
        ewwm-secrets-passkey--pending-request
        (list :action "get" :public-key public-key-options :origin origin))
  (unwind-protect
      (let ((message (json-encode
                      `((action . "passkeys-get")
                        (publicKey . ,public-key-options)
                        (origin . ,origin))))
            (response nil))
        (ewwm-keepassxc--send-message message)
        (setq response (ewwm-keepassxc--receive-response))
        (let ((parsed (and response (json-read-from-string response))))
          (cond
           ((and parsed (not (alist-get 'error parsed)))
            (run-hook-with-args 'ewwm-secrets-passkey-authenticate-hook origin)
            parsed)
           (t
            (let ((err-msg (or (alist-get 'error parsed)
                               "Unknown error during passkey authentication")))
              (run-hook-with-args 'ewwm-secrets-passkey-error-hook err-msg)
              (message "ewwm-secrets-passkey: authentication error: %s" err-msg)
              nil)))))
    (setq ewwm-secrets-passkey--active nil
          ewwm-secrets-passkey--pending-request nil)))

(defun ewwm-secrets-passkey-register (public-key-options origin)
  "Handle a navigator.credentials.create() request.
PUBLIC-KEY-OPTIONS is a JSON-decoded alist of the publicKey parameter.
ORIGIN is the requesting origin string (e.g. \"https://example.com\").
If `ewwm-secrets-passkey-confirm-registration' is non-nil, prompts the
user before proceeding.  Sends the request to KeePassXC via the browser
protocol and returns the attestation response as an alist, or nil on failure.

EXPERIMENTAL (Stage 14.10): protocol format may change."
  (unless ewwm-secrets-passkeys-enabled
    (run-hook-with-args 'ewwm-secrets-passkey-error-hook
                        "Passkey support is disabled")
    (error "ewwm-secrets-passkey: passkey support is disabled"))
  (unless ewwm-secrets-passkey-allow-registration
    (run-hook-with-args 'ewwm-secrets-passkey-error-hook
                        "Passkey registration is disabled")
    (error "ewwm-secrets-passkey: registration is disabled"))
  (when ewwm-secrets-passkey--active
    (run-hook-with-args 'ewwm-secrets-passkey-error-hook
                        "Another passkey operation is already in progress")
    (error "ewwm-secrets-passkey: another operation is in progress"))
  (when (and ewwm-secrets-passkey-confirm-registration
             (not (y-or-n-p (format "Register new passkey for %s? " origin))))
    (run-hook-with-args 'ewwm-secrets-passkey-error-hook
                        "User declined passkey registration")
    (user-error "ewwm-secrets-passkey: registration declined by user"))
  (setq ewwm-secrets-passkey--active t
        ewwm-secrets-passkey--pending-request
        (list :action "register" :public-key public-key-options :origin origin))
  (unwind-protect
      (let ((message (json-encode
                      `((action . "passkeys-register")
                        (publicKey . ,public-key-options)
                        (origin . ,origin))))
            (response nil))
        (ewwm-keepassxc--send-message message)
        (setq response (ewwm-keepassxc--receive-response))
        (let ((parsed (and response (json-read-from-string response))))
          (cond
           ((and parsed (not (alist-get 'error parsed)))
            ;; Track the registered origin
            (cl-pushnew origin ewwm-secrets-passkey--registered-origins
                        :test #'string=)
            (run-hook-with-args 'ewwm-secrets-passkey-register-hook origin)
            parsed)
           (t
            (let ((err-msg (or (alist-get 'error parsed)
                               "Unknown error during passkey registration")))
              (run-hook-with-args 'ewwm-secrets-passkey-error-hook err-msg)
              (message "ewwm-secrets-passkey: registration error: %s" err-msg)
              nil)))))
    (setq ewwm-secrets-passkey--active nil
          ewwm-secrets-passkey--pending-request nil)))

;; ── Qutebrowser bridge ──────────────────────────────────────

(defun ewwm-secrets-passkey--handle-browser-request (data)
  "Handle a passkey request from a Qutebrowser userscript.
DATA is a plist with :action (\"get\" or \"register\"), :public-key
\(the publicKey options alist), :origin, and :callback-id.

EXPERIMENTAL (Stage 14.10): IPC message format may change."
  (cond
   ((not ewwm-secrets-passkeys-enabled)
    (ewwm-secrets-passkey--send-browser-response
     (plist-get data :callback-id)
     `((error . "Passkey support is disabled")))
    nil)
   (t
    (let ((action (plist-get data :action))
          (public-key (plist-get data :public-key))
          (origin (plist-get data :origin))
          (callback-id (plist-get data :callback-id)))
      (condition-case err
          (let ((response
                 (pcase action
                   ("get"
                    (ewwm-secrets-passkey-get public-key origin))
                   ("register"
                    (ewwm-secrets-passkey-register public-key origin))
                   (_
                    (error "Unknown passkey action: %s" action)))))
            (ewwm-secrets-passkey--send-browser-response callback-id
                                                         (or response
                                                             '((error . "No response")))))
        (error
         (let ((err-msg (error-message-string err)))
           (run-hook-with-args 'ewwm-secrets-passkey-error-hook err-msg)
           (ewwm-secrets-passkey--send-browser-response
            callback-id
            `((error . ,err-msg))))))))))

(defun ewwm-secrets-passkey--send-browser-response (callback-id response)
  "Send RESPONSE back to Qutebrowser for CALLBACK-ID via IPC.
RESPONSE is an alist that will be JSON-encoded.

EXPERIMENTAL (Stage 14.10): IPC message format may change."
  (when (and callback-id (ewwm-ipc-connected-p))
    (ewwm-ipc-send `(:type :passkey-response
                     :callback-id ,callback-id
                     :payload ,(json-encode response)))))

;; ── Interactive commands ─────────────────────────────────────

(defun ewwm-secrets-passkey-status ()
  "Display passkey support status in the minibuffer.
EXPERIMENTAL (Stage 14.10)."
  (interactive)
  (message (concat "ewwm-secrets-passkey status:\n"
                   "  enabled:        %s\n"
                   "  registration:   %s\n"
                   "  confirm-reg:    %s\n"
                   "  timeout:        %ds\n"
                   "  active:         %s\n"
                   "  origins:        %d\n"
                   "  events:         %s")
           (if ewwm-secrets-passkeys-enabled "yes" "no")
           (if ewwm-secrets-passkey-allow-registration "allowed" "denied")
           (if ewwm-secrets-passkey-confirm-registration "yes" "no")
           ewwm-secrets-passkey-timeout
           (if ewwm-secrets-passkey--active "yes" "no")
           (length ewwm-secrets-passkey--registered-origins)
           (if ewwm-secrets-passkey--events-registered "registered" "not registered")))

(defun ewwm-secrets-passkey-list ()
  "List registered passkey origins from KeePassXC in a temporary buffer.
Queries KeePassXC for all stored passkey entries and displays them.
EXPERIMENTAL (Stage 14.10)."
  (interactive)
  (unless ewwm-secrets-passkeys-enabled
    (user-error "ewwm-secrets-passkey: passkey support is disabled"))
  (let ((response nil))
    (condition-case err
        (progn
          (ewwm-keepassxc--send-message
           (json-encode '((action . "passkeys-list"))))
          (setq response (ewwm-keepassxc--receive-response)))
      (error
       (run-hook-with-args 'ewwm-secrets-passkey-error-hook
                           (error-message-string err))
       (user-error "ewwm-secrets-passkey: failed to query KeePassXC: %s"
                   (error-message-string err))))
    (let* ((parsed (and response (json-read-from-string response)))
           (entries (alist-get 'entries parsed)))
      ;; Update cached origins
      (setq ewwm-secrets-passkey--registered-origins
            (mapcar (lambda (entry) (alist-get 'origin entry))
                    entries))
      (with-current-buffer (get-buffer-create "*ewwm-passkeys*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "EWWM Passkey Origins (via KeePassXC)\n")
          (insert "EXPERIMENTAL (Stage 14.10)\n")
          (insert (make-string 50 ?─) "\n\n")
          (if (null entries)
              (insert "(no passkeys registered)\n")
            (insert (format "  %d passkey(s) found:\n\n" (length entries)))
            (dolist (entry (append entries nil))
              (let ((origin (alist-get 'origin entry))
                    (rp-id (alist-get 'rpId entry))
                    (user-name (alist-get 'userName entry))
                    (created (alist-get 'createdDate entry)))
                (insert (format "  Origin:   %s\n" (or origin "?")))
                (when rp-id
                  (insert (format "  RP ID:    %s\n" rp-id)))
                (when user-name
                  (insert (format "  User:     %s\n" user-name)))
                (when created
                  (insert (format "  Created:  %s\n" created)))
                (insert "\n")))))
        (goto-char (point-min))
        (special-mode))
      (display-buffer "*ewwm-passkeys*"))))

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-secrets-passkey--on-request (data)
  "Handle an incoming passkey request event from IPC.
DATA is the event plist from the compositor/browser bridge.

EXPERIMENTAL (Stage 14.10)."
  (let ((request-data (plist-get data :passkey-request)))
    (when request-data
      (ewwm-secrets-passkey--handle-browser-request request-data))))

(defun ewwm-secrets-passkey--on-response (data)
  "Handle a response from KeePassXC arriving via IPC.
DATA is the event plist containing the passkey response.

EXPERIMENTAL (Stage 14.10)."
  (let ((callback-id (plist-get data :callback-id))
        (payload (plist-get data :payload)))
    (when (and callback-id payload)
      (ewwm-secrets-passkey--send-browser-response callback-id payload))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-secrets-passkey--register-events ()
  "Register IPC event handlers for passkey operations.
This function is idempotent; calling it multiple times has no effect.

EXPERIMENTAL (Stage 14.10)."
  (unless ewwm-secrets-passkey--events-registered
    (ewwm-ipc-register-events
     (list (cons :passkey-request
                 #'ewwm-secrets-passkey--on-request)
           (cons :passkey-response
                 #'ewwm-secrets-passkey--on-response)))
    (setq ewwm-secrets-passkey--events-registered t)))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-secrets-passkey-init ()
  "Initialize WebAuthn/FIDO2 passkey support.
Registers IPC event handlers for passkey request/response messages.

EXPERIMENTAL (Stage 14.10): this module is under active development."
  (ewwm-secrets-passkey--register-events)
  (message "ewwm-secrets-passkey: initialized (experimental)"))

(defun ewwm-secrets-passkey-teardown ()
  "Tear down passkey support and clear all state.
Clears pending requests, registered origins, and active flags.

EXPERIMENTAL (Stage 14.10)."
  (setq ewwm-secrets-passkey--pending-request nil
        ewwm-secrets-passkey--registered-origins nil
        ewwm-secrets-passkey--active nil)
  ;; Remove event handlers
  (when (boundp 'ewwm-ipc--event-handlers)
    (setq ewwm-ipc--event-handlers
          (cl-remove-if (lambda (entry)
                          (memq (car entry)
                                '(:passkey-request :passkey-response)))
                        ewwm-ipc--event-handlers)))
  (setq ewwm-secrets-passkey--events-registered nil))

(provide 'ewwm-secrets-passkey)
;;; ewwm-secrets-passkey.el ends here
