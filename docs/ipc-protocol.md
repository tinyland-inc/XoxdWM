# EWWM IPC Protocol Specification v1

## Overview

The EWWM IPC protocol enables bidirectional communication between the Rust
compositor (`ewwm-compositor`) and Emacs (`ewwm-ipc.el`) over a Unix domain
socket. Emacs is the window management brain; the compositor is the pixel
engine. All layout policy decisions flow from Emacs to the compositor via
IPC commands; all state change notifications flow from the compositor to
Emacs via IPC events.

## Transport

- **Socket type:** Unix domain stream socket (`AF_UNIX`, `SOCK_STREAM`)
- **Socket path:** `$XDG_RUNTIME_DIR/ewwm-ipc.sock`
- **Permissions:** `0700` (owner-only, same as Wayland socket)
- **Stale socket:** Compositor removes existing socket file on startup
- **Multiple clients:** Supported (future: debug tools, multiple Emacs instances)

## Wire Format

Messages are **length-prefixed UTF-8 s-expressions**:

```
+-------------------+-----------------------------+
| Length (4 bytes)   | Payload (UTF-8 s-expression) |
| big-endian u32    |                              |
+-------------------+-----------------------------+
```

- **Length prefix:** 4-byte big-endian unsigned 32-bit integer, encoding the
  byte length of the payload (NOT including the 4-byte prefix itself).
- **Payload:** UTF-8 encoded s-expression. No trailing newline or null byte.
- **Maximum message size:** 1 MiB (1,048,576 bytes). Messages exceeding this
  are rejected with an error response.

### Why Length-Prefixed

S-expressions can contain nested parentheses, making delimiter-based framing
ambiguous without a full parser. Length-prefixed framing allows the receiver
to read exactly the right number of bytes before parsing, avoiding
incremental parsing complexity.

### Why S-Expressions

- **Native to Emacs:** `read` and `prin1-to-string` are built-in, zero
  dependency, ~1us per message.
- **Human-readable:** Easy to debug with `socat` or trace buffers.
- **Adequate performance:** `lexpr` crate in Rust benchmarks at ~5us per
  typical message.
- **Future:** Binary mode (msgpack) can be negotiated via hello handshake
  if s-expression overhead becomes a bottleneck for high-frequency data.

## Message Structure

### Request (Emacs -> Compositor)

```elisp
(:type MESSAGE-TYPE :id REQUEST-ID &rest PAYLOAD)
```

- `:type` — keyword symbol identifying the message type
- `:id` — monotonically increasing integer for request/response correlation
- Remaining fields are message-type-specific

### Response (Compositor -> Emacs)

```elisp
(:type :response :id REQUEST-ID :status :ok|:error &rest PAYLOAD)
```

- `:id` — matches the request that triggered this response
- `:status` — `:ok` for success, `:error` for failure
- On error: `:reason "human-readable error message"`

### Event (Compositor -> Emacs, unsolicited)

```elisp
(:type :event :event EVENT-TYPE &rest PAYLOAD)
```

- No `:id` field (events are not responses to requests)
- `:event` — keyword symbol identifying the event type

## Session Lifecycle

```
Client                              Server
  |                                    |
  |--- connect (Unix socket) --------->|
  |                                    |
  |--- :hello (version, client) ------>|
  |<-- :hello (version, server, features) ---|
  |                                    |
  |--- :key-grab (s-r) --------------->|
  |<-- :response :ok ------------------|
  |                                    |
  |--- :surface-list ----------------->|
  |<-- :response (surface data) -------|
  |                                    |
  |<-- :event :surface-created --------|  (unsolicited)
  |<-- :event :key-pressed ------------|  (unsolicited)
  |                                    |
  |--- :surface-focus :id 3 ---------->|
  |<-- :response :ok ------------------|
  |                                    |
  |--- disconnect -------------------->|
```

## Message Types

### Handshake

#### `:hello` (request)

First message from client. Required before any other message.

```elisp
(:type :hello :id 1 :version 1 :client "ewwm.el")
```

#### `:hello` (response)

```elisp
(:type :hello :id 1 :version 1 :server "ewwm-compositor"
 :features (:xwayland t :vr nil))
```

### Surface Management

#### `:surface-list`

Query all managed surfaces.

```elisp
;; Request
(:type :surface-list :id 2)

;; Response
(:type :response :id 2 :status :ok
 :surfaces ((:id 1 :app-id "foot" :title "foot" :geometry (:x 0 :y 0 :w 800 :h 600)
             :workspace 0 :focused t)
            (:id 2 :app-id "firefox" :title "Mozilla Firefox" :geometry (:x 800 :y 0 :w 800 :h 600)
             :workspace 0 :focused nil)))
```

#### `:surface-focus`

Focus a surface by ID (sets keyboard focus).

```elisp
(:type :surface-focus :id 3 :surface-id 2)
```

#### `:surface-close`

Request graceful close of a surface.

```elisp
(:type :surface-close :id 4 :surface-id 2)
```

#### `:surface-move`

Move a surface to absolute position.

```elisp
(:type :surface-move :id 5 :surface-id 1 :x 100 :y 200)
```

#### `:surface-resize`

Resize a surface.

```elisp
(:type :surface-resize :id 6 :surface-id 1 :w 1024 :h 768)
```

#### `:surface-fullscreen`

Toggle fullscreen state.

```elisp
(:type :surface-fullscreen :id 7 :surface-id 1)
```

#### `:surface-float`

Toggle floating state.

```elisp
(:type :surface-float :id 8 :surface-id 1)
```

### Workspace Management

#### `:workspace-switch`

Switch to workspace by index.

```elisp
(:type :workspace-switch :id 9 :workspace 2)
```

#### `:workspace-list`

Query workspace state.

```elisp
;; Request
(:type :workspace-list :id 10)

;; Response
(:type :response :id 10 :status :ok
 :workspaces ((:index 0 :name "1" :surfaces (1 2) :active t)
              (:index 1 :name "2" :surfaces (3) :active nil)
              (:index 2 :name "3" :surfaces () :active nil)
              (:index 3 :name "4" :surfaces () :active nil)))
```

#### `:workspace-move-surface`

Move surface to a different workspace.

```elisp
(:type :workspace-move-surface :id 11 :surface-id 1 :workspace 2)
```

### Layout

#### `:layout-set`

Set layout algorithm for current workspace.

```elisp
(:type :layout-set :id 12 :layout :tiling)  ; :tiling, :floating, :monocle
```

#### `:layout-cycle`

Cycle to next layout algorithm.

```elisp
(:type :layout-cycle :id 13)
```

### Input

#### `:key-grab`

Register a global key grab. Compositor intercepts matching key events
before forwarding to focused surface.

```elisp
(:type :key-grab :id 14 :key "s-r")
```

Key format uses Emacs key description syntax:
- `s-r` = Super+r
- `C-M-x` = Ctrl+Alt+x
- `s-S-2` = Super+Shift+2
- `s-RET` = Super+Return

#### `:key-ungrab`

Release a previously registered key grab.

```elisp
(:type :key-ungrab :id 15 :key "s-r")
```

#### `:autotype` (stub)

Inject keystrokes into a surface.

```elisp
(:type :autotype :id 16 :surface-id 1 :text "password123")
```

### VR (stubs)

#### `:vr-status`

Query VR session state.

```elisp
(:type :vr-status :id 17)
;; Response: (:type :response :id 17 :status :ok :session :idle :runtime "monado")
```

#### `:vr-surface-position`

Set 3D position of a surface in VR space.

```elisp
(:type :vr-surface-position :id 18 :surface-id 1
 :position (:x 0.0 :y 1.5 :z -2.0)
 :rotation (:yaw 0.0 :pitch 0.0 :roll 0.0))
```

#### `:gaze-data` (stub)

Query current gaze coordinates.

```elisp
(:type :gaze-data :id 19)
```

### Utility

#### `:ping`

Latency measurement. Compositor responds immediately.

```elisp
(:type :ping :id 20 :timestamp 1705312345123)
;; Response: (:type :response :id 20 :status :ok :client-timestamp 1705312345123 :server-timestamp 1705312345124)
```

## Event Types (Compositor -> Emacs)

Events are pushed to all connected clients. No acknowledgment required.

#### `:surface-created`

```elisp
(:type :event :event :surface-created :id 1 :app-id "foot" :title "foot")
```

#### `:surface-destroyed`

```elisp
(:type :event :event :surface-destroyed :id 1)
```

#### `:surface-title-changed`

```elisp
(:type :event :event :surface-title-changed :id 1 :title "foot — ~/src")
```

#### `:surface-focused`

```elisp
(:type :event :event :surface-focused :id 2)
```

#### `:surface-geometry-changed`

```elisp
(:type :event :event :surface-geometry-changed :id 1
 :geometry (:x 0 :y 0 :w 1920 :h 1080))
```

#### `:workspace-changed`

```elisp
(:type :event :event :workspace-changed :workspace 2)
```

#### `:key-pressed`

Delivered when a grabbed key is pressed.

```elisp
(:type :event :event :key-pressed :key "s-r"
 :modifiers (:super t :ctrl nil :alt nil :shift nil)
 :timestamp 1705312345123)
```

## Error Handling

### Malformed Message

```elisp
(:type :response :id 0 :status :error :reason "malformed s-expression")
```

### Unknown Message Type

```elisp
(:type :response :id 42 :status :error :reason "unknown message type: :bogus")
```

### Version Mismatch

```elisp
(:type :response :id 1 :status :error :reason "unsupported protocol version: 99")
```

### Not Authenticated

If a message other than `:hello` is sent before handshake:

```elisp
(:type :response :id 0 :status :error :reason "hello handshake required")
```

## Backpressure

If a client's write buffer exceeds 64 KiB, the compositor drops the oldest
**events** (not command responses) from that client's buffer. This prevents
a slow client from causing compositor memory growth.

## Security

- **Authentication:** None. Socket permissions (`0700`) restrict access to
  the same user. This is the same security model as `$WAYLAND_DISPLAY`.
- **Encryption:** None. Local-only transport; encryption adds latency with
  no benefit.
- **Authorization:** All connected clients have full access. Future:
  capability-based access control.

## Performance Targets

- Round-trip latency (ping/pong): p99 < 1ms
- S-expression parse time (Rust): < 50us per message
- S-expression encode time (Emacs): < 10us per message
- Maximum sustained throughput: > 1000 msg/s
- Event emission overhead: < 100us per event per client

## Future Extensions

- **Binary mode:** Negotiate msgpack encoding via hello handshake for
  high-frequency data (gaze at 200Hz, EEG at 250Hz)
- **Multi-socket:** Separate socket for high-frequency biometric data
  to avoid head-of-line blocking
- **Protocol versioning:** Version field in hello allows backward-compatible
  additions; breaking changes increment version
- **Event filtering:** Client subscribes to specific event types to reduce
  unnecessary traffic
