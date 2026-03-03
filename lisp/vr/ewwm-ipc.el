;;; ewwm-ipc.el --- IPC client for EWWM compositor  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;;; Commentary:
;; Bidirectional IPC client for communication with ewwm-compositor.
;; Wire format: 4-byte big-endian length prefix + UTF-8 s-expression payload.
;; See docs/ipc-protocol.md for the full protocol specification.

;;; Code:

(require 'cl-lib)
(require 'ewwm-core)

;; ── Customization ──────────────────────────────────────────

(defcustom ewwm-ipc-socket-path nil
  "Path to the IPC socket. Nil means auto-detect from XDG_RUNTIME_DIR."
  :type '(choice (const :tag "Auto-detect" nil) string)
  :group 'ewwm)

(defcustom ewwm-ipc-reconnect-max-delay 30
  "Maximum delay in seconds between reconnection attempts."
  :type 'integer
  :group 'ewwm)

(defcustom ewwm-ipc-sync-timeout 2
  "Timeout in seconds for synchronous IPC requests."
  :type 'number
  :group 'ewwm)

;; ── Internal state ─────────────────────────────────────────

(defvar ewwm-ipc--next-id 1
  "Next request ID for IPC messages.")

(defvar ewwm-ipc--pending-requests (make-hash-table :test 'eql)
  "Hash table of pending request callbacks, keyed by request ID.")

(defvar ewwm-ipc--event-handlers
  '((:surface-created   . ewwm-ipc--on-surface-created)
    (:surface-destroyed  . ewwm-ipc--on-surface-destroyed)
    (:surface-title-changed . ewwm-ipc--on-surface-title-changed)
    (:surface-focused    . ewwm-ipc--on-surface-focused)
    (:surface-geometry-changed . ewwm-ipc--on-surface-geometry-changed)
    (:workspace-changed  . ewwm-ipc--on-workspace-changed)
    (:key-pressed        . ewwm-ipc--on-key-pressed)
    (:output-usable-area-changed . ewwm-ipc--on-output-usable-area-changed))
  "Alist mapping event types to handler functions.")

(defvar ewwm-ipc--reconnect-timer nil
  "Timer for reconnection attempts.")

(defvar ewwm-ipc--reconnect-delay 1
  "Current reconnection delay in seconds (exponential backoff).")

(defvar ewwm-ipc--read-buffer ""
  "Accumulator for partial reads from the IPC socket.")

(defvar ewwm-ipc--trace nil
  "Non-nil to log all IPC messages to *ewwm-ipc-trace* buffer.")

(defvar ewwm-ipc--msg-count-sent 0
  "Number of messages sent since connection.")

(defvar ewwm-ipc--msg-count-recv 0
  "Number of messages received since connection.")

;; ── Hooks ──────────────────────────────────────────────────

(defvar ewwm-ipc-connected-hook nil
  "Hook run after IPC connection is established.")

(defvar ewwm-ipc-disconnected-hook nil
  "Hook run after IPC connection is lost.")

;; ── Connection management ──────────────────────────────────

(defun ewwm-ipc--socket-path ()
  "Return the IPC socket path."
  (or ewwm-ipc-socket-path
      ewwm--compositor-socket
      (expand-file-name "ewwm-ipc.sock"
                        (or (getenv "XDG_RUNTIME_DIR")
                            (format "/tmp/ewwm-%d" (user-uid))))))

(defun ewwm-ipc-connect (&optional socket-path)
  "Connect to the compositor IPC socket at SOCKET-PATH.
If SOCKET-PATH is nil, auto-detect from `ewwm-ipc--socket-path'."
  (interactive)
  (ewwm-ipc-disconnect)
  (let ((path (or socket-path (ewwm-ipc--socket-path))))
    (setq ewwm--compositor-socket path)
    (condition-case err
        (progn
          (setq ewwm--ipc-connection
                (make-network-process
                 :name "ewwm-ipc"
                 :family 'local
                 :service path
                 :coding 'binary
                 :filter #'ewwm-ipc--filter
                 :sentinel #'ewwm-ipc--sentinel
                 :noquery t))
          (setq ewwm-ipc--read-buffer ""
                ewwm-ipc--msg-count-sent 0
                ewwm-ipc--msg-count-recv 0
                ewwm-ipc--reconnect-delay 1)
          ;; Cancel any pending reconnect timer
          (when ewwm-ipc--reconnect-timer
            (cancel-timer ewwm-ipc--reconnect-timer)
            (setq ewwm-ipc--reconnect-timer nil))
          ;; Send hello handshake
          (ewwm-ipc-send '(:type :hello :version 1 :client "ewwm.el")
                         #'ewwm-ipc--on-hello-response)
          (message "ewwm-ipc: connected to %s" path)
          (run-hooks 'ewwm-ipc-connected-hook)
          ewwm--ipc-connection)
      (error
       (message "ewwm-ipc: connection failed: %s" (error-message-string err))
       nil))))

(defun ewwm-ipc-disconnect ()
  "Disconnect from the compositor IPC socket."
  (interactive)
  (when (and ewwm--ipc-connection
             (process-live-p ewwm--ipc-connection))
    (delete-process ewwm--ipc-connection))
  (setq ewwm--ipc-connection nil
        ewwm-ipc--read-buffer ""))

(defun ewwm-ipc-connected-p ()
  "Return non-nil if the IPC connection is alive."
  (and ewwm--ipc-connection
       (process-live-p ewwm--ipc-connection)))

;; ── Message framing ────────────────────────────────────────

(defun ewwm-ipc--encode-message (sexp)
  "Encode SEXP as a length-prefixed binary message.
Returns a unibyte string: 4-byte big-endian length + UTF-8 payload."
  (let* ((payload (encode-coding-string (prin1-to-string sexp) 'utf-8))
         (len (length payload)))
    (concat (unibyte-string
             (logand (ash len -24) #xff)
             (logand (ash len -16) #xff)
             (logand (ash len -8) #xff)
             (logand len #xff))
            payload)))

(defun ewwm-ipc--decode-length (bytes)
  "Decode 4-byte big-endian length from BYTES (a unibyte string)."
  (+ (ash (aref bytes 0) 24)
     (ash (aref bytes 1) 16)
     (ash (aref bytes 2) 8)
     (aref bytes 3)))

;; ── Send/receive ───────────────────────────────────────────

(defun ewwm-ipc-send (request &optional callback)
  "Send REQUEST to the compositor. Call CALLBACK with the response.
REQUEST is a plist like (:type :surface-list). An :id field is added
automatically. Returns the request ID."
  (unless (ewwm-ipc-connected-p)
    (error "ewwm-ipc: not connected"))
  (let ((id ewwm-ipc--next-id))
    (setq ewwm-ipc--next-id (1+ id))
    ;; Inject :id into the request
    (let ((msg (plist-put (copy-sequence request) :id id)))
      (when callback
        (puthash id callback ewwm-ipc--pending-requests))
      (let ((encoded (ewwm-ipc--encode-message msg)))
        (when ewwm-ipc--trace
          (ewwm-ipc--trace-log ">>" msg))
        (process-send-string ewwm--ipc-connection encoded)
        (cl-incf ewwm-ipc--msg-count-sent))
      id)))

(defun ewwm-ipc-send-sync (request &optional timeout)
  "Send REQUEST synchronously. Return the response or signal error.
TIMEOUT defaults to `ewwm-ipc-sync-timeout' seconds."
  (let* ((timeout (or timeout ewwm-ipc-sync-timeout))
         (response nil)
         (id (ewwm-ipc-send request
                            (lambda (resp) (setq response resp))))
         (deadline (+ (float-time) timeout)))
    (while (and (null response)
                (< (float-time) deadline)
                (ewwm-ipc-connected-p))
      (accept-process-output ewwm--ipc-connection 0.05))
    (remhash id ewwm-ipc--pending-requests)
    (cond
     (response response)
     ((not (ewwm-ipc-connected-p))
      (error "ewwm-ipc: disconnected during sync request"))
     (t (error "ewwm-ipc: timeout waiting for response (id=%d)" id)))))

;; ── Filter and sentinel ────────────────────────────────────

(defun ewwm-ipc--filter (_proc data)
  "Process filter: accumulate DATA and dispatch complete messages."
  (setq ewwm-ipc--read-buffer (concat ewwm-ipc--read-buffer data))
  ;; Extract complete framed messages
  (while (>= (length ewwm-ipc--read-buffer) 4)
    (let ((msg-len (ewwm-ipc--decode-length ewwm-ipc--read-buffer)))
      (when (> msg-len 1048576)
        ;; Protocol violation
        (message "ewwm-ipc: received oversized message (%d bytes)" msg-len)
        (setq ewwm-ipc--read-buffer "")
        (cl-return))
      (let ((total (+ 4 msg-len)))
        (if (< (length ewwm-ipc--read-buffer) total)
            (cl-return) ; Incomplete message, wait for more data
          ;; Extract complete message
          (let* ((payload-bytes (substring ewwm-ipc--read-buffer 4 total))
                 (payload-str (decode-coding-string payload-bytes 'utf-8))
                 (msg (condition-case nil
                          (read payload-str)
                        (error nil))))
            (setq ewwm-ipc--read-buffer (substring ewwm-ipc--read-buffer total))
            (when msg
              (cl-incf ewwm-ipc--msg-count-recv)
              (when ewwm-ipc--trace
                (ewwm-ipc--trace-log "<<" msg))
              (ewwm-ipc--dispatch msg))))))))

(defun ewwm-ipc--sentinel (_proc event)
  "Process sentinel: handle connection state changes."
  (let ((event-str (string-trim event)))
    (cond
     ((string-match-p "connection broken" event-str)
      (message "ewwm-ipc: connection lost")
      (setq ewwm--ipc-connection nil
            ewwm-ipc--read-buffer "")
      ;; Fail all pending requests
      (maphash (lambda (_id callback)
                 (funcall callback '(:status :error :reason "disconnected")))
               ewwm-ipc--pending-requests)
      (clrhash ewwm-ipc--pending-requests)
      (run-hooks 'ewwm-ipc-disconnected-hook)
      ;; Start reconnection
      (ewwm-ipc--start-reconnect))
     ((string-match-p "deleted" event-str)
      ;; Intentional disconnect, don't reconnect
      nil)
     (t
      (message "ewwm-ipc: sentinel: %s" event-str)))))

;; ── Message dispatch ───────────────────────────────────────

(defun ewwm-ipc--dispatch (msg)
  "Dispatch a decoded IPC message MSG."
  (let ((msg-type (plist-get msg :type))
        (msg-id (plist-get msg :id)))
    (cond
     ;; Response to a pending request
     ((and msg-id (gethash msg-id ewwm-ipc--pending-requests))
      (let ((callback (gethash msg-id ewwm-ipc--pending-requests)))
        (remhash msg-id ewwm-ipc--pending-requests)
        (funcall callback msg)))
     ;; Hello response (also has :id but handled via callback above)
     ((eq msg-type :hello)
      ;; Server hello — check version
      (let ((version (plist-get msg :version)))
        (unless (eql version 1)
          (message "ewwm-ipc: unsupported server version: %s" version))))
     ;; Event from compositor
     ((eq msg-type :event)
      (let* ((event-type (plist-get msg :event))
             (handler (alist-get event-type ewwm-ipc--event-handlers)))
        (if handler
            (funcall handler msg)
          (message "ewwm-ipc: unhandled event: %s" event-type))))
     ;; Unknown
     (t
      (message "ewwm-ipc: unexpected message: %S" msg)))))

;; ── Event handlers ─────────────────────────────────────────

(defun ewwm-ipc--on-hello-response (msg)
  "Handle hello handshake response MSG."
  (let ((status (plist-get msg :status)))
    (if (eq status :ok)
        (message "ewwm-ipc: handshake complete (server: %s)"
                 (plist-get msg :server))
      ;; Hello response is the hello message itself (not a :response)
      (let ((server (plist-get msg :server)))
        (message "ewwm-ipc: connected to %s" (or server "compositor"))))))

(defun ewwm-ipc--on-surface-created (msg)
  "Handle :surface-created event MSG."
  (let ((id (plist-get msg :id))
        (app-id (plist-get msg :app-id))
        (title (plist-get msg :title)))
    (message "ewwm: surface created: %s (id=%d)" (or title app-id "?") id)))

(defun ewwm-ipc--on-surface-destroyed (msg)
  "Handle :surface-destroyed event MSG."
  (let ((id (plist-get msg :id)))
    (message "ewwm: surface destroyed: id=%d" id)))

(defun ewwm-ipc--on-surface-title-changed (msg)
  "Handle :surface-title-changed event MSG."
  (let ((id (plist-get msg :id))
        (title (plist-get msg :title)))
    (message "ewwm: surface %d title: %s" id title)))

(defun ewwm-ipc--on-surface-focused (msg)
  "Handle :surface-focused event MSG."
  (let ((id (plist-get msg :id)))
    (message "ewwm: surface focused: id=%d" id)))

(defun ewwm-ipc--on-surface-geometry-changed (_msg)
  "Handle :surface-geometry-changed event MSG."
  ;; Silent — high frequency
  nil)

(defun ewwm-ipc--on-workspace-changed (msg)
  "Handle :workspace-changed event MSG."
  (let ((workspace (plist-get msg :workspace)))
    (message "ewwm: workspace changed: %d" workspace)))

(defun ewwm-ipc--on-key-pressed (msg)
  "Handle :key-pressed event MSG."
  (let ((key (plist-get msg :key)))
    (message "ewwm: key pressed: %s" key)))

(defun ewwm-ipc--on-output-usable-area-changed (msg)
  "Handle :output-usable-area-changed event MSG.
Updates layout usable area when layer-shell exclusive zones change."
  (message "ewwm: usable area changed: %S" msg))

;; ── Reconnection ───────────────────────────────────────────

(defun ewwm-ipc--start-reconnect ()
  "Start reconnection with exponential backoff."
  (unless ewwm-ipc--reconnect-timer
    (setq ewwm-ipc--reconnect-delay 1)
    (ewwm-ipc--schedule-reconnect)))

(defun ewwm-ipc--schedule-reconnect ()
  "Schedule a reconnection attempt."
  (setq ewwm-ipc--reconnect-timer
        (run-at-time ewwm-ipc--reconnect-delay nil
                     #'ewwm-ipc--try-reconnect)))

(defun ewwm-ipc--try-reconnect ()
  "Attempt to reconnect to the compositor."
  (setq ewwm-ipc--reconnect-timer nil)
  (if (ewwm-ipc-connect)
      (progn
        (message "ewwm-ipc: reconnected")
        (setq ewwm-ipc--reconnect-delay 1))
    ;; Exponential backoff
    (setq ewwm-ipc--reconnect-delay
          (min (* ewwm-ipc--reconnect-delay 2)
               ewwm-ipc-reconnect-max-delay))
    (message "ewwm-ipc: reconnect failed, retrying in %ds"
             ewwm-ipc--reconnect-delay)
    (ewwm-ipc--schedule-reconnect)))

;; ── Convenience wrappers ───────────────────────────────────

(defun ewwm-surface-list ()
  "Query the compositor for all managed surfaces."
  (interactive)
  (let ((resp (ewwm-ipc-send-sync '(:type :surface-list))))
    (if (eq (plist-get resp :status) :ok)
        (plist-get resp :surfaces)
      (error "ewwm: surface-list failed: %s" (plist-get resp :reason)))))

(defun ewwm-surface-focus (surface-id)
  "Focus the surface with SURFACE-ID."
  (ewwm-ipc-send `(:type :surface-focus :surface-id ,surface-id)))

(defun ewwm-surface-close (surface-id)
  "Close the surface with SURFACE-ID."
  (ewwm-ipc-send `(:type :surface-close :surface-id ,surface-id)))

(defun ewwm-surface-move (surface-id x y)
  "Move SURFACE-ID to position (X, Y)."
  (ewwm-ipc-send `(:type :surface-move :surface-id ,surface-id :x ,x :y ,y)))

(defun ewwm-surface-resize (surface-id w h)
  "Resize SURFACE-ID to dimensions (W, H)."
  (ewwm-ipc-send `(:type :surface-resize :surface-id ,surface-id :w ,w :h ,h)))

(defun ewwm-workspace-switch (n)
  "Switch to workspace N."
  (interactive "nWorkspace: ")
  (ewwm-ipc-send `(:type :workspace-switch :workspace ,n)))

(defun ewwm-workspace-list ()
  "Query the compositor for workspace state."
  (interactive)
  (let ((resp (ewwm-ipc-send-sync '(:type :workspace-list))))
    (if (eq (plist-get resp :status) :ok)
        (plist-get resp :workspaces)
      (error "ewwm: workspace-list failed: %s" (plist-get resp :reason)))))

(defun ewwm-key-grab (key)
  "Register a global key grab for KEY (Emacs key description)."
  (ewwm-ipc-send `(:type :key-grab :key ,key)))

(defun ewwm-key-ungrab (key)
  "Release a global key grab for KEY."
  (ewwm-ipc-send `(:type :key-ungrab :key ,key)))

(defun ewwm-ipc-ping ()
  "Send a ping and report round-trip latency."
  (interactive)
  (let* ((start (float-time))
         (_resp (ewwm-ipc-send-sync
                 `(:type :ping :timestamp ,(truncate (* start 1000)))))
         (elapsed (* (- (float-time) start) 1000.0)))
    (message "ewwm-ipc: ping %.2fms" elapsed)))

;; ── Trace mode ─────────────────────────────────────────────

(define-minor-mode ewwm-ipc-trace-mode
  "Toggle IPC message tracing in *ewwm-ipc-trace* buffer."
  :global t
  :lighter " IPC-Trace"
  :group 'ewwm
  (setq ewwm-ipc--trace ewwm-ipc-trace-mode)
  (when ewwm-ipc-trace-mode
    (get-buffer-create "*ewwm-ipc-trace*")))

(defun ewwm-ipc--trace-log (direction msg)
  "Log a trace entry with DIRECTION (>> or <<) and MSG."
  (let ((buf (get-buffer "*ewwm-ipc-trace*")))
    (when buf
      (with-current-buffer buf
        (goto-char (point-max))
        (insert (format "[%s] %s %S\n"
                        (format-time-string "%H:%M:%S.%3N")
                        direction
                        msg))))))

;; ── Status ─────────────────────────────────────────────────

(defun ewwm-ipc-status ()
  "Display IPC connection status."
  (interactive)
  (message "ewwm-ipc: %s | sent: %d | recv: %d | pending: %d"
           (if (ewwm-ipc-connected-p) "connected" "disconnected")
           ewwm-ipc--msg-count-sent
           ewwm-ipc--msg-count-recv
           (hash-table-count ewwm-ipc--pending-requests)))

;; ── Benchmark ──────────────────────────────────────────────

(defun ewwm-ipc-benchmark (&optional count)
  "Benchmark IPC round-trip latency with COUNT ping messages (default 1000)."
  (interactive "P")
  (let* ((count (or count 1000))
         (times nil))
    (dotimes (_ count)
      (let ((start (float-time)))
        (ewwm-ipc-send-sync
         `(:type :ping :timestamp ,(truncate (* start 1000))))
        (push (* (- (float-time) start) 1000.0) times)))
    (setq times (sort times #'<))
    (let ((min-t (car times))
          (max-t (car (last times)))
          (mean-t (/ (apply #'+ times) (float count)))
          (p50 (nth (truncate (* count 0.5)) times))
          (p95 (nth (truncate (* count 0.95)) times))
          (p99 (nth (truncate (* count 0.99)) times)))
      (message (concat "ewwm-ipc benchmark (%d msgs):\n"
                       "  min=%.2fms max=%.2fms mean=%.2fms\n"
                       "  p50=%.2fms p95=%.2fms p99=%.2fms")
               count min-t max-t mean-t p50 p95 p99))))

;; ── Event registration helper ─────────────────────────────

(defun ewwm-ipc-register-events (handlers)
  "Register HANDLERS alist with IPC dispatch.  Idempotent.
Each element of HANDLERS is (EVENT-KEY . HANDLER-FN)."
  (when (boundp 'ewwm-ipc--event-handlers)
    (dolist (h handlers)
      (unless (assq (car h) ewwm-ipc--event-handlers)
        (push h ewwm-ipc--event-handlers)))))

(provide 'ewwm-ipc)
;;; ewwm-ipc.el ends here
