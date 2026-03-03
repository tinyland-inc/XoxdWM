;;; ewwm-notify.el --- Desktop notifications for EWWM  -*- lexical-binding: t -*-

;;; Commentary:
;; Implements org.freedesktop.Notifications D-Bus interface so EWWM
;; can receive desktop notifications without an external daemon.
;; Notifications are displayed in the minibuffer and optionally logged
;; to a buffer.

;;; Code:

(require 'cl-lib)
(require 'dbus)

;; ── Customization ────────────────────────────────────────────

(defgroup ewwm-notify nil
  "Desktop notification daemon for EWWM."
  :group 'ewwm)

(defcustom ewwm-notify-max-history 100
  "Maximum number of notifications to keep in history."
  :type 'integer
  :group 'ewwm-notify)

(defcustom ewwm-notify-timeout-default 5000
  "Default notification timeout in milliseconds.
Used when the application specifies 0 (server decides)."
  :type 'integer
  :group 'ewwm-notify)

(defcustom ewwm-notify-show-in-minibuffer t
  "Show notifications in the minibuffer."
  :type 'boolean
  :group 'ewwm-notify)

(defcustom ewwm-notify-log-buffer "*ewwm-notifications*"
  "Buffer name for notification log.  nil to disable logging."
  :type '(choice string (const nil))
  :group 'ewwm-notify)

(defcustom ewwm-notify-urgency-format
  '((0 . "[low] %s: %s")
    (1 . "%s: %s")
    (2 . "[!] %s: %s"))
  "Format strings per urgency level (0=low, 1=normal, 2=critical).
First %s is summary, second is body."
  :type '(alist :key-type integer :value-type string)
  :group 'ewwm-notify)

(defcustom ewwm-notify-hook nil
  "Hook run when a notification is received.
Each function receives (ID APP-NAME SUMMARY BODY URGENCY)."
  :type 'hook
  :group 'ewwm-notify)

;; ── Internal state ───────────────────────────────────────────

(defvar ewwm-notify--next-id 1
  "Next notification ID to assign.")

(defvar ewwm-notify--history nil
  "List of recent notifications (newest first).
Each entry: (ID TIMESTAMP APP-NAME SUMMARY BODY URGENCY).")

(defvar ewwm-notify--registration nil
  "D-Bus service registration object.")

(defvar ewwm-notify--active-timers (make-hash-table :test 'eql)
  "Map of notification ID -> expiry timer.")

;; ── D-Bus interface ──────────────────────────────────────────

(defconst ewwm-notify--service "org.freedesktop.Notifications")
(defconst ewwm-notify--path "/org/freedesktop/Notifications")
(defconst ewwm-notify--interface "org.freedesktop.Notifications")

(defun ewwm-notify--get-capabilities ()
  "Return list of supported capabilities."
  '("body" "persistence" "actions"))

(defun ewwm-notify--get-server-information ()
  "Return server name, vendor, version, spec-version."
  (list "ewwm-notify" "EXWM-VR" "0.5.0" "1.2"))

(defun ewwm-notify--notify (app-name replaces-id _app-icon
                            summary body _actions hints
                            expire-timeout)
  "Handle a Notify call.  Returns the notification ID.
APP-NAME, REPLACES-ID, SUMMARY, BODY, HINTS, EXPIRE-TIMEOUT
are per the spec."
  (let* ((id (if (and replaces-id (> replaces-id 0))
                 replaces-id
               (prog1 ewwm-notify--next-id
                 (setq ewwm-notify--next-id (1+ ewwm-notify--next-id)))))
         (urgency (or (cdr (assoc "urgency" hints)) 1))
         (timeout (if (or (null expire-timeout) (= expire-timeout 0))
                      ewwm-notify-timeout-default
                    (if (= expire-timeout -1) nil expire-timeout)))
         (entry (list id (current-time) app-name summary body urgency)))

    ;; Store in history
    (push entry ewwm-notify--history)
    (when (> (length ewwm-notify--history) ewwm-notify-max-history)
      (setq ewwm-notify--history
            (seq-take ewwm-notify--history ewwm-notify-max-history)))

    ;; Display
    (ewwm-notify--display id app-name summary body urgency)

    ;; Log
    (ewwm-notify--log entry)

    ;; Auto-close timer
    (when timeout
      (let ((old-timer (gethash id ewwm-notify--active-timers)))
        (when old-timer (cancel-timer old-timer)))
      (puthash id
               (run-with-timer (/ timeout 1000.0) nil
                               #'ewwm-notify--close-notification id 1)
               ewwm-notify--active-timers))

    ;; Run hooks
    (run-hook-with-args 'ewwm-notify-hook id app-name summary body urgency)

    ;; Return the ID (must be :uint32 for D-Bus)
    id))

(defun ewwm-notify--close-notification (id reason)
  "Close notification ID with REASON (1=expired, 2=dismissed, 3=closed)."
  (let ((timer (gethash id ewwm-notify--active-timers)))
    (when timer
      (cancel-timer timer)
      (remhash id ewwm-notify--active-timers)))
  ;; Emit NotificationClosed signal
  (ignore-errors
    (dbus-send-signal :session
                      ewwm-notify--service
                      ewwm-notify--path
                      ewwm-notify--interface
                      "NotificationClosed"
                      :uint32 id
                      :uint32 (or reason 3))))

;; ── Display ──────────────────────────────────────────────────

(defun ewwm-notify--display (_id app-name summary body urgency)
  "Display notification from APP-NAME with SUMMARY, BODY, URGENCY."
  (when ewwm-notify-show-in-minibuffer
    (let* ((fmt (or (cdr (assoc urgency ewwm-notify-urgency-format))
                    "%s: %s"))
           (msg (format fmt summary (if (string-empty-p body) "" body))))
      (message "[%s] %s" app-name msg))))

(defun ewwm-notify--log (entry)
  "Log notification ENTRY to the log buffer."
  (when ewwm-notify-log-buffer
    (let ((buf (get-buffer-create ewwm-notify-log-buffer)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (let* ((id (nth 0 entry))
                 (time (nth 1 entry))
                 (app (nth 2 entry))
                 (summary (nth 3 entry))
                 (body (nth 4 entry))
                 (urgency (nth 5 entry))
                 (time-str (format-time-string "%H:%M:%S" time)))
            (insert (format "[%s] #%d %s (u=%d): %s"
                            time-str id app urgency summary))
            (unless (string-empty-p body)
              (insert (format " — %s" body)))
            (insert "\n")))))))

;; ── Interactive commands ─────────────────────────────────────

(defun ewwm-notify-show-history ()
  "Display notification history in a buffer."
  (interactive)
  (let ((buf (get-buffer-create "*ewwm-notify-history*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "EWWM Notification History\n")
        (insert (make-string 40 ?=) "\n\n")
        (if (null ewwm-notify--history)
            (insert "No notifications.\n")
          (dolist (entry ewwm-notify--history)
            (let* ((id (nth 0 entry))
                   (time (nth 1 entry))
                   (app (nth 2 entry))
                   (summary (nth 3 entry))
                   (body (nth 4 entry))
                   (urgency (nth 5 entry))
                   (time-str (format-time-string "%Y-%m-%d %H:%M:%S" time)))
              (insert (format "  #%d  [%s]  %s (urgency=%d)\n"
                              id time-str app urgency))
              (insert (format "       %s\n" summary))
              (unless (string-empty-p body)
                (insert (format "       %s\n" body)))
              (insert "\n")))))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buf)))

(defun ewwm-notify-clear-history ()
  "Clear all notification history."
  (interactive)
  (setq ewwm-notify--history nil)
  (message "ewwm-notify: history cleared"))

(defun ewwm-notify-dismiss (id)
  "Dismiss notification by ID."
  (interactive "nNotification ID: ")
  (ewwm-notify--close-notification id 2))

(defun ewwm-notify-dismiss-all ()
  "Dismiss all active notifications."
  (interactive)
  (maphash (lambda (id _timer)
             (ewwm-notify--close-notification id 2))
           ewwm-notify--active-timers)
  (clrhash ewwm-notify--active-timers)
  (message "ewwm-notify: all dismissed"))

(defun ewwm-notify-test ()
  "Send a test notification via D-Bus."
  (interactive)
  (dbus-call-method :session
                    ewwm-notify--service
                    ewwm-notify--path
                    ewwm-notify--interface
                    "Notify"
                    "ewwm-test"    ; app_name
                    :uint32 0      ; replaces_id
                    ""             ; app_icon
                    "Test Notification"  ; summary
                    "This is a test from ewwm-notify." ; body
                    '(:array :string)  ; actions (empty)
                    '(:array :signature "{sv}")  ; hints (empty)
                    :int32 3000))  ; timeout

;; ── Lifecycle ───────────────────────────────────────────────

(defun ewwm-notify-enable ()
  "Register as the desktop notification daemon on the session bus."
  (interactive)
  (when ewwm-notify--registration
    (ewwm-notify-disable))

  ;; Register the service name
  (dbus-register-service :session ewwm-notify--service)

  ;; Register methods
  (dbus-register-method :session
                        ewwm-notify--service
                        ewwm-notify--path
                        ewwm-notify--interface
                        "GetCapabilities"
                        #'ewwm-notify--get-capabilities)

  (dbus-register-method :session
                        ewwm-notify--service
                        ewwm-notify--path
                        ewwm-notify--interface
                        "GetServerInformation"
                        #'ewwm-notify--get-server-information)

  (dbus-register-method :session
                        ewwm-notify--service
                        ewwm-notify--path
                        ewwm-notify--interface
                        "Notify"
                        #'ewwm-notify--notify)

  (dbus-register-method :session
                        ewwm-notify--service
                        ewwm-notify--path
                        ewwm-notify--interface
                        "CloseNotification"
                        (lambda (id) (ewwm-notify--close-notification id 3)))

  (setq ewwm-notify--registration t)
  (message "ewwm-notify: registered as notification daemon"))

(defun ewwm-notify-disable ()
  "Unregister the notification daemon."
  (interactive)
  (ignore-errors
    (dbus-unregister-service :session ewwm-notify--service))
  ;; Cancel all timers
  (maphash (lambda (_id timer) (cancel-timer timer))
           ewwm-notify--active-timers)
  (clrhash ewwm-notify--active-timers)
  (setq ewwm-notify--registration nil)
  (message "ewwm-notify: unregistered"))

(provide 'ewwm-notify)
;;; ewwm-notify.el ends here
