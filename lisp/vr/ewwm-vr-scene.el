;;; ewwm-vr-scene.el --- VR scene management for EWWM  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Emacs interface to the compositor's VR 3D scene graph.
;; Controls layout, PPU, projection, background, and surface positioning
;; in the VR environment via IPC.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-send-sync "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")
(declare-function ewwm-ipc-register-events "ewwm-ipc")

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-vr-scene nil
  "VR scene settings for EWWM."
  :group 'ewwm)

(defcustom ewwm-vr-scene-default-layout 'arc
  "Default VR surface layout mode.
`arc': horizontal arc at uniform distance.
`grid': 2D grid with configurable columns.
`stack': stacked at same position.
`freeform': user-positioned."
  :type '(choice (const arc)
                 (const grid)
                 (const stack)
                 (const freeform))
  :group 'ewwm-vr-scene)

(defcustom ewwm-vr-scene-default-ppu 1000
  "Default pixels-per-unit for VR surface sizing.
Higher values make surfaces appear smaller in VR space.
1000 = 1920px surface is ~1.92m wide."
  :type 'integer
  :group 'ewwm-vr-scene)

(defcustom ewwm-vr-scene-default-background 'dark
  "Default VR background type.
`dark': solid dark color.
`gradient': vertical gradient.
`grid': reference grid.
`passthrough': camera passthrough (if supported)."
  :type '(choice (const dark)
                 (const gradient)
                 (const grid)
                 (const passthrough))
  :group 'ewwm-vr-scene)

(defcustom ewwm-vr-scene-grid-columns 2
  "Number of columns for grid layout mode."
  :type 'integer
  :group 'ewwm-vr-scene)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-vr-scene-layout nil
  "Current VR scene layout mode as a symbol.")

(defvar ewwm-vr-scene-ppu nil
  "Current global PPU value.")

(defvar ewwm-vr-scene-background nil
  "Current VR background type as a symbol.")

(defvar ewwm-vr-scene-surfaces nil
  "Alist of VR scene surfaces.
Each entry is (SURFACE-ID . PLIST) where PLIST has keys:
:position, :projection, :ppu, :visible, :focused.")

;; ── IPC helpers ──────────────────────────────────────────────

(defun ewwm-vr-scene--send (msg)
  "Send MSG to compositor if IPC is connected."
  (when (and (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (ewwm-ipc-send msg)))

(defun ewwm-vr-scene--send-sync (msg)
  "Send MSG synchronously and return response, or nil."
  (when (and (fboundp 'ewwm-ipc-send-sync)
             (fboundp 'ewwm-ipc-connected-p)
             (ewwm-ipc-connected-p))
    (condition-case err
        (ewwm-ipc-send-sync msg)
      (error
       (message "ewwm-vr-scene: %s" (error-message-string err))
       nil))))

;; ── Interactive commands ─────────────────────────────────────

(defun ewwm-vr-scene-status ()
  "Query and display VR scene status."
  (interactive)
  (let ((resp (ewwm-vr-scene--send-sync '(:type :vr-scene-status))))
    (if (and resp (eq (plist-get resp :status) :ok))
        (let ((scene (plist-get resp :scene)))
          (message "ewwm-vr-scene: %s" scene))
      (message "ewwm-vr-scene: status query failed"))))

(defun ewwm-vr-scene-set-layout (layout)
  "Set the VR scene layout to LAYOUT.
LAYOUT is a symbol: `arc', `grid', `stack', or `freeform'."
  (interactive
   (list (intern (completing-read "VR layout: "
                                  '("arc" "grid" "stack" "freeform")
                                  nil t))))
  (unless (memq layout '(arc grid stack freeform))
    (error "Invalid layout: %s" layout))
  (let ((layout-str (if (eq layout 'grid)
                        (format "grid-%d" ewwm-vr-scene-grid-columns)
                      (symbol-name layout))))
    (ewwm-vr-scene--send
     `(:type :vr-scene-set-layout :layout ,layout-str)))
  (setq ewwm-vr-scene-layout layout)
  (message "ewwm-vr-scene: layout set to %s" layout))

(defun ewwm-vr-scene-set-ppu (ppu &optional surface-id)
  "Set pixels-per-unit to PPU.
With SURFACE-ID, set PPU for that surface only.
Without, set global PPU."
  (interactive "nPPU (pixels per meter): ")
  (let ((msg `(:type :vr-scene-set-ppu :ppu ,ppu)))
    (when surface-id
      (setq msg (plist-put msg :surface-id surface-id)))
    (ewwm-vr-scene--send msg))
  (unless surface-id
    (setq ewwm-vr-scene-ppu ppu))
  (message "ewwm-vr-scene: PPU set to %d%s"
           ppu (if surface-id (format " (surface %d)" surface-id) "")))

(defun ewwm-vr-scene-set-background (background)
  "Set the VR background to BACKGROUND.
BACKGROUND is a symbol: `dark', `gradient', `grid', or `passthrough'."
  (interactive
   (list (intern (completing-read "VR background: "
                                  '("dark" "gradient" "grid" "passthrough")
                                  nil t))))
  (unless (memq background '(dark gradient grid passthrough))
    (error "Invalid background: %s" background))
  (ewwm-vr-scene--send
   `(:type :vr-scene-set-background :background ,(symbol-name background)))
  (setq ewwm-vr-scene-background background)
  (message "ewwm-vr-scene: background set to %s" background))

(defun ewwm-vr-scene-set-projection (surface-id projection)
  "Set the projection type for SURFACE-ID to PROJECTION.
PROJECTION is a symbol: `flat' or `cylinder'."
  (interactive
   (list (read-number "Surface ID: ")
         (intern (completing-read "Projection: "
                                  '("flat" "cylinder")
                                  nil t))))
  (unless (memq projection '(flat cylinder))
    (error "Invalid projection: %s" projection))
  (ewwm-vr-scene--send
   `(:type :vr-scene-set-projection
     :surface-id ,surface-id
     :projection ,(symbol-name projection)))
  (message "ewwm-vr-scene: surface %d projection set to %s"
           surface-id projection))

(defun ewwm-vr-scene-focus (surface-id)
  "Set VR focus to SURFACE-ID, or clear focus if nil."
  (interactive "nSurface ID (0 to clear): ")
  (let ((id (if (= surface-id 0) nil surface-id)))
    (ewwm-vr-scene--send
     `(:type :vr-scene-focus
       ,@(when id (list :surface-id id)))))
  (message "ewwm-vr-scene: focus %s"
           (if (= surface-id 0) "cleared" (format "set to %d" surface-id))))

(defun ewwm-vr-scene-move (surface-id x y z)
  "Move SURFACE-ID to position X Y Z (in centimeters)."
  (interactive "nSurface ID: \nnX (cm): \nnY (cm): \nnZ (cm): ")
  (ewwm-vr-scene--send
   `(:type :vr-scene-move
     :surface-id ,surface-id
     :x ,x :y ,y :z ,z))
  (message "ewwm-vr-scene: moved surface %d to (%d, %d, %d) cm"
           surface-id x y z))

;; ── IPC event handlers ───────────────────────────────────────

(defun ewwm-vr-scene--on-layout-changed (msg)
  "Handle :vr-scene-layout-changed event MSG."
  (let ((layout (plist-get msg :layout)))
    (setq ewwm-vr-scene-layout layout)
    (run-hooks 'ewwm-vr-scene-layout-hook)))

(defun ewwm-vr-scene--on-surface-added (_msg)
  "Handle :vr-scene-surface-added event _MSG."
  (run-hooks 'ewwm-vr-scene-surface-hook))

(defun ewwm-vr-scene--on-surface-removed (_msg)
  "Handle :vr-scene-surface-removed event _MSG."
  (run-hooks 'ewwm-vr-scene-surface-hook))

;; ── Hooks ────────────────────────────────────────────────────

(defvar ewwm-vr-scene-layout-hook nil
  "Hook run when VR scene layout changes.")

(defvar ewwm-vr-scene-surface-hook nil
  "Hook run when a VR scene surface is added or removed.")

;; ── Event registration ───────────────────────────────────────

(defun ewwm-vr-scene--register-events ()
  "Register VR scene event handlers with IPC dispatch."
  (ewwm-ipc-register-events
   '((:vr-scene-layout-changed  . ewwm-vr-scene--on-layout-changed)
     (:vr-scene-surface-added   . ewwm-vr-scene--on-surface-added)
     (:vr-scene-surface-removed . ewwm-vr-scene--on-surface-removed))))

;; ── Initialization ───────────────────────────────────────────

(defun ewwm-vr-scene-init ()
  "Initialize VR scene management."
  (ewwm-vr-scene--register-events)
  (setq ewwm-vr-scene-layout ewwm-vr-scene-default-layout
        ewwm-vr-scene-ppu ewwm-vr-scene-default-ppu
        ewwm-vr-scene-background ewwm-vr-scene-default-background))

(defun ewwm-vr-scene-teardown ()
  "Clean up VR scene state."
  (setq ewwm-vr-scene-layout nil
        ewwm-vr-scene-ppu nil
        ewwm-vr-scene-background nil
        ewwm-vr-scene-surfaces nil))

(provide 'ewwm-vr-scene)
;;; ewwm-vr-scene.el ends here
