;;; ewwm-vr-display.el --- VR display and HMD management  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Manages VR display output: DRM leases, HMD detection, display mode,
;; refresh rate negotiation.  Communicates with the compositor's
;; HmdManager via IPC.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-display nil
  "VR display and HMD management settings."
  :group 'ewwm-vr)

(defcustom ewwm-vr-display-default-mode 'auto
  "Default VR display mode on startup.
`auto': auto-detect based on available hardware.
`headset': direct HMD output via DRM lease.
`preview': desktop window preview (no HMD).
`headless': no display (testing only).
`off': VR display disabled."
  :type '(choice (const auto)
                 (const headset)
                 (const preview)
                 (const headless)
                 (const off))
  :group 'ewwm-vr-display)

(defcustom ewwm-vr-display-default-refresh-rate 90
  "Default target refresh rate in Hz."
  :type 'integer
  :group 'ewwm-vr-display)

(defcustom ewwm-vr-display-auto-select-hmd t
  "Non-nil to automatically select the best HMD on hotplug."
  :type 'boolean
  :group 'ewwm-vr-display)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-display-mode nil
  "Current VR display mode as a symbol.
One of: headset, preview, headless, off, or nil.")

(defvar ewwm-vr-display-hmd nil
  "Name of the currently selected HMD (string), or nil.")

(defvar ewwm-vr-display-connector nil
  "DRM connector name of the selected HMD (string), or nil.")

(defvar ewwm-vr-display-refresh-rate nil
  "Active refresh rate in Hz, or nil.")

(defvar ewwm-vr-display-target-refresh-rate nil
  "Target refresh rate in Hz, or nil.")

(defvar ewwm-vr-display-connectors nil
  "List of all detected DRM connectors as plists.")

(defvar ewwm-vr-display-hmd-count 0
  "Number of detected HMD connectors.")

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-display-mode-hook nil
  "Hook run when VR display mode changes.
`ewwm-vr-display-mode' is set before this hook runs.")

(defvar ewwm-vr-display-hotplug-hook nil
  "Hook run when an HMD is connected or disconnected.")

;; ── IPC event handlers ──────────────────────────────────────

(defun ewwm-vr-display--on-mode-changed (msg)
  "Handle :vr-display-mode-changed event MSG."
  (let ((mode (plist-get msg :mode)))
    (when mode
      (setq ewwm-vr-display-mode mode)
      (run-hooks 'ewwm-vr-display-mode-hook)
      (force-mode-line-update t))))

(defun ewwm-vr-display--on-hotplug (msg)
  "Handle :vr-display-hotplug event MSG."
  (let ((connector (plist-get msg :connector))
        (connected (plist-get msg :connected)))
    (message "ewwm-vr-display: %s %s"
             (or connector "unknown")
             (if (eq connected t) "connected" "disconnected"))
    (run-hooks 'ewwm-vr-display-hotplug-hook)))

(defun ewwm-vr-display--on-hmd-selected (msg)
  "Handle :vr-display-hmd-selected event MSG."
  (let ((hmd (plist-get msg :hmd))
        (connector (plist-get msg :connector)))
    (setq ewwm-vr-display-hmd hmd
          ewwm-vr-display-connector connector)
    (when hmd
      (message "ewwm-vr-display: HMD selected: %s (%s)" hmd connector))))

;; ── Interactive commands ────────────────────────────────────

(defun ewwm-vr-display-info ()
  "Display VR display/HMD info in the minibuffer."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-display: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :vr-display-info))))
          (if (eq (plist-get resp :status) :ok)
              (let ((display (plist-get resp :display)))
                (setq ewwm-vr-display-mode (plist-get display :mode)
                      ewwm-vr-display-hmd (plist-get display :hmd)
                      ewwm-vr-display-connector (plist-get display :connector)
                      ewwm-vr-display-refresh-rate (plist-get display :refresh-rate)
                      ewwm-vr-display-target-refresh-rate (plist-get display :target-refresh-rate))
                (message "ewwm-vr-display: mode=%s hmd=%s connector=%s refresh=%sHz"
                         ewwm-vr-display-mode
                         (or ewwm-vr-display-hmd "none")
                         (or ewwm-vr-display-connector "none")
                         (or ewwm-vr-display-refresh-rate "?")))
            (message "ewwm-vr-display: query failed: %s"
                     (plist-get resp :reason))))
      (error (message "ewwm-vr-display: %s" (error-message-string err))))))

(defun ewwm-vr-display-set-mode (mode)
  "Set the VR display mode to MODE.
MODE is a symbol: `headset', `preview', `headless', or `off'."
  (interactive
   (list (intern (completing-read "Display mode: "
                                  '("headset" "preview" "headless" "off")
                                  nil t))))
  (unless (memq mode '(headset preview headless off))
    (error "Invalid display mode: %s (use headset, preview, headless, or off)" mode))
  (setq ewwm-vr-display-mode mode)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :vr-display-set-mode :mode ,(symbol-name mode))))
  (message "ewwm-vr-display: mode set to %s" mode))

(defun ewwm-vr-display-select-hmd (connector-id)
  "Select HMD by CONNECTOR-ID."
  (interactive "nConnector ID: ")
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :vr-display-select-hmd :connector-id ,connector-id)))
  (message "ewwm-vr-display: selecting HMD connector %d" connector-id))

(defun ewwm-vr-display-set-refresh-rate (rate)
  "Set the target refresh RATE in Hz."
  (interactive "nTarget refresh rate (Hz): ")
  (unless (> rate 0)
    (error "Refresh rate must be positive"))
  (setq ewwm-vr-display-target-refresh-rate rate)
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send
     `(:type :vr-display-set-refresh-rate :rate ,rate)))
  (message "ewwm-vr-display: target refresh rate set to %dHz" rate))

(defun ewwm-vr-display-auto-detect ()
  "Auto-detect the best display mode based on available hardware."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-display: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :vr-display-auto-detect))))
          (if (eq (plist-get resp :status) :ok)
              (let ((mode (plist-get resp :mode)))
                (setq ewwm-vr-display-mode mode)
                (message "ewwm-vr-display: auto-detected mode: %s" mode))
            (message "ewwm-vr-display: auto-detect failed: %s"
                     (plist-get resp :reason))))
      (error (message "ewwm-vr-display: %s" (error-message-string err))))))

(defun ewwm-vr-display-list-connectors ()
  "List all DRM connectors in a dedicated buffer."
  (interactive)
  (if (not (fboundp 'ewwm-ipc-send-sync))
      (message "ewwm-vr-display: IPC not available")
    (condition-case err
        (let ((resp (ewwm-ipc-send-sync '(:type :vr-display-list-connectors))))
          (if (eq (plist-get resp :status) :ok)
              (let ((connectors (plist-get resp :connectors))
                    (buf (get-buffer-create "*ewwm-vr-connectors*")))
                (with-current-buffer buf
                  (let ((inhibit-read-only t))
                    (erase-buffer)
                    (insert "EWWM VR DRM Connectors\n")
                    (insert "======================\n\n")
                    (if connectors
                        (dolist (conn connectors)
                          (insert (format "  %s (%s) %s\n"
                                          (or (plist-get conn :connector) "?")
                                          (or (plist-get conn :model) "?")
                                          (if (eq (plist-get conn :non-desktop) t)
                                              "[HMD]" ""))))
                      (insert "  No connectors detected.\n"))
                    (insert "\n[Press q to close]"))
                  (special-mode))
                (display-buffer buf))
            (message "ewwm-vr-display: connector list failed")))
      (error (message "ewwm-vr-display: %s" (error-message-string err))))))

;; ── Event registration ──────────────────────────────────────

(defun ewwm-vr-display--register-events ()
  "Register VR display event handlers with IPC event dispatch."
  (ewwm-ipc-register-events
   '((:vr-display-mode-changed . ewwm-vr-display--on-mode-changed)
     (:vr-display-hotplug      . ewwm-vr-display--on-hotplug)
     (:vr-display-hmd-selected . ewwm-vr-display--on-hmd-selected))))

;; ── Init / teardown ─────────────────────────────────────────

(defun ewwm-vr-display-init ()
  "Initialize VR display management.
Registers IPC event handlers and applies default mode."
  (ewwm-vr-display--register-events)
  (setq ewwm-vr-display-target-refresh-rate
        ewwm-vr-display-default-refresh-rate))

(defun ewwm-vr-display-teardown ()
  "Clean up VR display state."
  (setq ewwm-vr-display-mode nil
        ewwm-vr-display-hmd nil
        ewwm-vr-display-connector nil
        ewwm-vr-display-refresh-rate nil
        ewwm-vr-display-target-refresh-rate nil
        ewwm-vr-display-connectors nil
        ewwm-vr-display-hmd-count 0))

(provide 'ewwm-vr-display)
;;; ewwm-vr-display.el ends here
