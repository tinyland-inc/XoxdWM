;;; ewwm-dark-mode.el --- Dark mode portal integration for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Implements org.freedesktop.appearance color-scheme portal integration.
;; Watches the XDG desktop portal for dark/light preference changes and
;; automatically loads the appropriate Emacs theme.  Optionally syncs
;; the preference to qutebrowser via ewwm-qutebrowser-theme.

;;; Code:

(require 'cl-lib)
(require 'dbus)

(declare-function ewwm-qutebrowser-theme-sync "ewwm-qutebrowser-theme")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-dark-mode nil
  "Dark mode portal integration for EWWM."
  :group 'ewwm
  :prefix "ewwm-dark-mode-")

(defcustom ewwm-dark-mode-dark-theme "modus-vivendi"
  "Emacs theme to load when the portal reports dark preference."
  :type 'string
  :group 'ewwm-dark-mode)

(defcustom ewwm-dark-mode-light-theme "modus-operandi"
  "Emacs theme to load when the portal reports light preference."
  :type 'string
  :group 'ewwm-dark-mode)

(defcustom ewwm-dark-mode-follow-system t
  "Non-nil to follow the system color-scheme portal preference.
When nil, theme changes only happen via manual toggle commands."
  :type 'boolean
  :group 'ewwm-dark-mode)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-dark-mode--current 'dark
  "Current color scheme: `dark' or `light'.")

(defvar ewwm-dark-mode--signal-registration nil
  "D-Bus signal registration object for SettingChanged.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-dark-mode-changed-hook nil
  "Hook run after the dark/light theme has been applied.
`ewwm-dark-mode--current' is set before this hook runs.")

;; ── D-Bus constants ──────────────────────────────────────────

(defconst ewwm-dark-mode--portal-service "org.freedesktop.portal.Desktop"
  "D-Bus service name for the XDG desktop portal.")

(defconst ewwm-dark-mode--portal-path "/org/freedesktop/portal/desktop"
  "D-Bus object path for the portal settings.")

(defconst ewwm-dark-mode--portal-interface "org.freedesktop.portal.Settings"
  "D-Bus interface for portal settings.")

(defconst ewwm-dark-mode--appearance-namespace "org.freedesktop.appearance"
  "D-Bus namespace for appearance settings.")

(defconst ewwm-dark-mode--color-scheme-key "color-scheme"
  "D-Bus key for the color-scheme setting.")

;; ── Portal read ──────────────────────────────────────────────

(defun ewwm-dark-mode--read-portal ()
  "Read the color-scheme preference via D-Bus.
Return 0 (no preference), 1 (prefer dark), or 2 (prefer light).
Returns nil if the portal is not available."
  (condition-case _err
      (let ((result (dbus-call-method
                     :session
                     ewwm-dark-mode--portal-service
                     ewwm-dark-mode--portal-path
                     ewwm-dark-mode--portal-interface
                     "Read"
                     ewwm-dark-mode--appearance-namespace
                     ewwm-dark-mode--color-scheme-key)))
        ;; The portal returns a variant-wrapped uint32.
        ;; Unwrap: result may be (((1))) or ((1)) or (1) or just 1
        ;; depending on D-Bus variant nesting.
        (ewwm-dark-mode--unwrap-variant result))
    (dbus-error nil)))

(defun ewwm-dark-mode--unwrap-variant (value)
  "Unwrap nested D-Bus variant VALUE to a plain integer."
  (cond
   ((integerp value) value)
   ((and (listp value) (car value))
    (ewwm-dark-mode--unwrap-variant (car value)))
   (t 0)))

(defun ewwm-dark-mode--preference-to-scheme (pref)
  "Convert portal preference PREF to a scheme symbol.
0 = no preference (default to dark), 1 = dark, 2 = light."
  (cond
   ((eql pref 2) 'light)
   (t 'dark)))

;; ── Theme application ────────────────────────────────────────

(defun ewwm-dark-mode--apply (scheme)
  "Apply the Emacs theme for SCHEME (`dark' or `light').
Disables themes not matching the target before loading."
  (let ((theme-name (if (eq scheme 'dark)
                        ewwm-dark-mode-dark-theme
                      ewwm-dark-mode-light-theme)))
    (setq ewwm-dark-mode--current scheme)
    ;; Disable current custom themes to avoid stacking
    (mapc #'disable-theme custom-enabled-themes)
    ;; Load the target theme
    (load-theme (intern theme-name) t)
    ;; Sync qutebrowser if available
    (ewwm-dark-mode--sync-qutebrowser)
    ;; Run user hook
    (run-hooks 'ewwm-dark-mode-changed-hook)
    (message "ewwm-dark-mode: applied %s (%s)" theme-name scheme)))

;; ── Qutebrowser sync ─────────────────────────────────────────

(defun ewwm-dark-mode--sync-qutebrowser ()
  "Sync theme to qutebrowser if `ewwm-qutebrowser-theme' is available."
  (when (fboundp 'ewwm-qutebrowser-theme-sync)
    (ewwm-qutebrowser-theme-sync)))

;; ── D-Bus signal handler ────────────────────────────────────

(defun ewwm-dark-mode--portal-changed (namespace key value)
  "Handle SettingChanged signal for NAMESPACE KEY VALUE.
Only acts on org.freedesktop.appearance color-scheme changes."
  (when (and ewwm-dark-mode-follow-system
             (string= namespace ewwm-dark-mode--appearance-namespace)
             (string= key ewwm-dark-mode--color-scheme-key))
    (let* ((pref (ewwm-dark-mode--unwrap-variant value))
           (scheme (ewwm-dark-mode--preference-to-scheme pref)))
      (unless (eq scheme ewwm-dark-mode--current)
        (ewwm-dark-mode--apply scheme)))))

;; ── Interactive commands ─────────────────────────────────────

(defun ewwm-dark-mode-toggle ()
  "Manually toggle between dark and light themes."
  (interactive)
  (ewwm-dark-mode--apply
   (if (eq ewwm-dark-mode--current 'dark) 'light 'dark)))

(defun ewwm-dark-mode-set-dark ()
  "Switch to the dark theme."
  (interactive)
  (ewwm-dark-mode--apply 'dark))

(defun ewwm-dark-mode-set-light ()
  "Switch to the light theme."
  (interactive)
  (ewwm-dark-mode--apply 'light))

(defun ewwm-dark-mode-follow-portal ()
  "Enable following the system portal preference.
Reads the current portal value and applies it immediately."
  (interactive)
  (setq ewwm-dark-mode-follow-system t)
  (let ((pref (ewwm-dark-mode--read-portal)))
    (if pref
        (ewwm-dark-mode--apply
         (ewwm-dark-mode--preference-to-scheme pref))
      (message "ewwm-dark-mode: portal not available, follow-system enabled for signals"))))

;; ── Lifecycle ────────────────────────────────────────────────

(defun ewwm-dark-mode-enable ()
  "Enable dark mode portal watching.
Registers a D-Bus signal handler for SettingChanged and reads
the current portal preference."
  (interactive)
  (when ewwm-dark-mode--signal-registration
    (ewwm-dark-mode-disable))
  ;; Register for SettingChanged signals
  (setq ewwm-dark-mode--signal-registration
        (dbus-register-signal
         :session
         ewwm-dark-mode--portal-service
         ewwm-dark-mode--portal-path
         ewwm-dark-mode--portal-interface
         "SettingChanged"
         #'ewwm-dark-mode--portal-changed))
  ;; Read current preference and apply
  (when ewwm-dark-mode-follow-system
    (let ((pref (ewwm-dark-mode--read-portal)))
      (when pref
        (ewwm-dark-mode--apply
         (ewwm-dark-mode--preference-to-scheme pref)))))
  (message "ewwm-dark-mode: enabled"))

(defun ewwm-dark-mode-disable ()
  "Disable dark mode portal watching.
Unregisters the D-Bus signal handler."
  (interactive)
  (when ewwm-dark-mode--signal-registration
    (dbus-unregister-object ewwm-dark-mode--signal-registration)
    (setq ewwm-dark-mode--signal-registration nil))
  (message "ewwm-dark-mode: disabled"))

(provide 'ewwm-dark-mode)
;;; ewwm-dark-mode.el ends here
