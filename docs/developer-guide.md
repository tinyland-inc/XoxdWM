# EXWM-VR: Developer Guide

**Version 0.1.0** | Architecture, building, extending, and contributing

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Building from Source](#building-from-source)
3. [Project Structure](#project-structure)
4. [IPC Protocol Reference](#ipc-protocol-reference)
5. [Writing Elisp Extensions](#writing-elisp-extensions)
6. [Writing Rust Modules](#writing-rust-modules)
7. [Adding Gestures](#adding-gestures)
8. [Adding BCI Paradigms](#adding-bci-paradigms)
9. [Testing Guide](#testing-guide)
10. [Pre-Commit Hooks](#pre-commit-hooks)
11. [CI Pipeline](#ci-pipeline)
12. [Contributing Guidelines](#contributing-guidelines)

---

## Architecture Overview

EWWM-VR is a split-brain architecture: Emacs is the window management
brain (layout, policy, keybinds), and a Rust compositor (Smithay) is the
pixel engine. They communicate over a Unix domain socket using
length-prefixed s-expressions.

```
+=======================+
|     Emacs (pgtk)      |  User's primary interface
|  ewwm.el (WM logic)  |  47 Elisp modules (layout/workspace/VR/BCI)
+-----------+-----------+
            |
    Unix socket IPC (s-expression, length-prefixed)
    $XDG_RUNTIME_DIR/ewwm-ipc.sock
            |
+-----------v-----------+
|  VR Compositor (Rust) |  Built on Smithay 0.7
|  +-- Wayland Server   |  xdg-shell, layer-shell, foreign-toplevel
|  +-- XWayland         |  X11 client support
|  +-- DRM Lease        |  wp_drm_lease_v1 for VR headset
|  +-- OpenXR Bridge    |  Monado runtime (eye/hand tracking)
|  +-- BCI Bridge       |  BrainFlow daemon (EEG acquisition)
|  +-- IPC Server       |  Multi-client, authenticated
|  +-- Headless Backend |  For s390x and CI
+-----------+-----------+
            |
    DRM/KMS | OpenXR/Monado | BrainFlow
            |
+-----------v-----------+
|   GPU + VR + EEG HW   |
+=======================+
```

### Key Design Decisions

1. **Emacs as policy, compositor as mechanism**: Emacs decides which
   surface goes where; the compositor executes it. This keeps Elisp
   hackability while maintaining rendering performance.

2. **Surface-as-buffer model**: Each Wayland surface becomes an Emacs
   buffer with `permanent-local` buffer-local variables. The central
   mapping is `ewwm--surface-buffer-alist`.

3. **S-expression IPC**: Native to Emacs (`read`/`prin1-to-string`),
   parsed in Rust via the `lexpr` crate. Length-prefixed framing avoids
   incremental parsing complexity.

4. **Feature flags**: The `vr` Cargo feature gates OpenXR dependencies.
   The `full-backend` feature (default) gates DRM/winit. Headless builds
   disable both.

5. **No openxrs in data modules**: Modules like `scene.rs`,
   `drm_lease.rs`, `gaze_focus.rs`, `blink_wink.rs`, `gaze_zone.rs`,
   `fatigue.rs`, `gaze_scroll.rs`, `link_hints.rs`, `hand_tracking.rs`,
   `gesture.rs`, `virtual_keyboard.rs`, and all BCI modules compile
   unconditionally (no openxrs dependency).

---

## Building from Source

### Prerequisites

- Nix with flakes enabled (recommended)
- Or: Rust nightly, Emacs 30+ (pgtk), Wayland development libraries

### Nix (Recommended)

```bash
# Enter development shell
nix develop

# Build compositor
cargo build --manifest-path compositor/Cargo.toml

# Byte-compile Elisp
just build

# Run tests
just test
```

### Manual (Without Nix)

```bash
# Install Rust nightly
rustup toolchain install nightly
rustup default nightly

# Install system dependencies (Fedora/Rocky)
sudo dnf install wayland-devel wayland-protocols-devel \
  libdrm-devel mesa-libEGL-devel libinput-devel \
  libxkbcommon-devel seatd-devel udev-devel \
  openxr-devel monado

# Build compositor
cd compositor
cargo build

# Build with headless-only (no GPU required)
cargo build --no-default-features

# Build with VR support
cargo build --features vr
```

### Cross-Compilation

```bash
# aarch64 (2D mode, no VR)
nix build .#packages.aarch64-linux.compositor

# s390x (headless only)
nix build .#packages.s390x-linux.compositor
```

### OCI Container Images

```bash
# Build container for headless deployment
nix build .#packages.x86_64-linux.oci-headless
```

---

## Project Structure

```
exwm/
+-- compositor/                  Rust compositor (Smithay 0.7)
|   +-- Cargo.toml
|   +-- src/
|       +-- main.rs              Entry point, CLI args
|       +-- state.rs             EwwmState (central state struct)
|       +-- input.rs             libinput handling
|       +-- render.rs            GLES2 renderer
|       +-- autotype.rs          Keystroke injection state machine
|       +-- secure_input.rs      Secure input mode state
|       +-- backend/
|       |   +-- mod.rs           Backend dispatch
|       |   +-- drm.rs           DRM/KMS backend
|       |   +-- winit.rs         Winit development backend
|       |   +-- headless.rs      Headless backend (multi-output)
|       +-- handlers/
|       |   +-- mod.rs           Handler trait impls
|       |   +-- compositor.rs    CompositorHandler
|       |   +-- xdg_shell.rs     XdgShellHandler
|       |   +-- xwayland.rs      XwmHandler
|       |   +-- seat.rs          SeatHandler
|       |   +-- layer_shell.rs   WlrLayerShellHandler
|       |   +-- foreign_toplevel.rs  ForeignToplevelListHandler
|       |   +-- shm.rs           ShmHandler
|       +-- ipc/
|       |   +-- mod.rs           IPC module root
|       |   +-- server.rs        Unix socket server, client management
|       |   +-- dispatch.rs      Message dispatch (176 match arms)
|       +-- vr/
|           +-- mod.rs           VR module root, feature gating
|           +-- openxr_state.rs  OpenXR session lifecycle (behind vr flag)
|           +-- stub.rs          VR stubs when vr flag is off
|           +-- scene.rs         3D scene graph (Vec3/Quat/Mat4)
|           +-- texture.rs       DMA-BUF texture import
|           +-- vr_renderer.rs   Stereo renderer
|           +-- vr_interaction.rs VR pointer, grab, depth
|           +-- frame_timing.rs  Frame timing statistics
|           +-- drm_lease.rs     DRM lease for HMD
|           +-- eye_tracking.rs  Gaze data pipeline
|           +-- gaze_focus.rs    Dwell-based focus switching
|           +-- blink_wink.rs    Blink/wink detection
|           +-- gaze_zone.rs     9-zone gaze regions
|           +-- fatigue.rs       Eye fatigue monitoring
|           +-- gaze_scroll.rs   Edge-zone gaze scrolling
|           +-- link_hints.rs    Link hint overlay
|           +-- hand_tracking.rs 26-joint hand skeleton
|           +-- gesture.rs       Gesture recognition
|           +-- virtual_keyboard.rs VR keyboard
|           +-- bci_state.rs     BCI state management
|           +-- attention.rs     Attention tracking
|           +-- ssvep.rs         SSVEP classification
|           +-- p300.rs          P300 detection
|           +-- motor_imagery.rs MI classification
|           +-- fatigue_eeg.rs   EEG fatigue monitoring
+-- lisp/
|   +-- core/                    Original EXWM modules (X11)
|   +-- vr/                      47 ewwm-* modules (Wayland/VR/BCI)
|   +-- ext/                     Extension framework
+-- test/                        63 ERT test files
+-- nix/
|   +-- modules/                 NixOS modules (exwm-vr.nix, monado.nix)
|   +-- home-manager/            Home Manager module
+-- packaging/
|   +-- rpm/                     RPM spec (7 subpackages)
|   +-- selinux/                 SELinux policy (3 domains)
|   +-- systemd/                 5 user units + target
|   +-- desktop/                 .desktop entry + session wrapper
|   +-- udev/                    udev rules
|   +-- userscripts/             JS userscripts for Qutebrowser
+-- docs/                        Documentation
+-- .github/workflows/           CI (multi-arch.yml, ert-tests.yml)
+-- flake.nix                    Nix flake
+-- justfile                     Task runner
+-- PLAN.md                      20-week implementation plan
```

---

## IPC Protocol Reference

Full specification: `docs/ipc-protocol.md`

### Transport

- Unix domain stream socket at `$XDG_RUNTIME_DIR/ewwm-ipc.sock`
- Wire format: 4-byte big-endian length prefix + UTF-8 s-expression
- Maximum message size: 1 MiB
- Multi-client support with per-client authentication

### Session Lifecycle

1. Client connects to Unix socket
2. Client sends `:hello` (version 1)
3. Server responds with `:hello` (version, features)
4. Client sends commands, receives responses
5. Server pushes events asynchronously

### Message Types by Subsystem

**Core (9 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `hello` | `:version :client` | Handshake (must be first) |
| `ping` | `:timestamp` | Latency measurement |
| `surface-list` | -- | Query all surfaces |
| `surface-focus` | `:surface-id` | Focus a surface |
| `surface-close` | `:surface-id` | Close a surface |
| `surface-move` | `:surface-id :x :y` | Move surface |
| `surface-resize` | `:surface-id :w :h` | Resize surface |
| `surface-fullscreen` | `:surface-id` | Toggle fullscreen |
| `surface-float` | `:surface-id` | Toggle floating |

**Workspace (3 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `workspace-switch` | `:workspace` | Switch workspace |
| `workspace-list` | -- | Query workspaces |
| `workspace-move-surface` | `:surface-id :workspace` | Move surface |

**Layout (2 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `layout-set` | `:layout` | Set layout algorithm |
| `layout-cycle` | -- | Cycle layout |

**Input (2 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `key-grab` | `:key` | Register global key grab |
| `key-ungrab` | `:key` | Release key grab |

**VR Core (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `vr-status` | -- | Query VR session state |
| `vr-set-reference-space` | `:space-type` | Set reference space |
| `vr-restart` | -- | Restart VR session |
| `vr-get-frame-timing` | -- | Frame timing stats |

**VR Scene (6 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `vr-scene-status` | -- | Scene graph state |
| `vr-scene-set-layout` | `:layout` | Set 3D layout |
| `vr-scene-set-ppu` | `:ppu` | Pixels per unit |
| `vr-scene-set-background` | `:color` | Background color |
| `vr-scene-set-projection` | `:type` | Projection type |
| `vr-scene-focus` | `:surface-id` | Focus surface in VR |

**VR Display (6 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `vr-display-info` | -- | Display info |
| `vr-display-set-mode` | `:mode` | Set display mode |
| `vr-display-select-hmd` | `:connector` | Select HMD |
| `vr-display-set-refresh-rate` | `:rate` | Set refresh rate |
| `vr-display-auto-detect` | -- | Auto-detect HMD |
| `vr-display-list-connectors` | -- | List connectors |

**VR Interaction (8 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `vr-pointer-state` | -- | Pointer state |
| `vr-click` | `:button` | Click |
| `vr-grab` | -- | Start grab |
| `vr-grab-release` | -- | Release grab |
| `vr-adjust-depth` | `:delta` | Adjust depth |
| `vr-set-follow` | `:enable` | Follow mode |
| `vr-set-gaze-offset` | `:x :y :z` | Gaze offset |
| `vr-calibrate-confirm` | -- | Confirm calibration |

**Eye Tracking (8 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `gaze-status` | -- | Gaze source status |
| `gaze-set-source` | `:source` | Set gaze source |
| `gaze-calibrate-start` | `:points` | Start calibration |
| `gaze-calibrate-point` | `:target-x :target-y :target-z` | Record point |
| `gaze-set-visualization` | `:type` | Set visualization |
| `gaze-set-smoothing` | `:alpha` | Set smoothing |
| `gaze-simulate` | `:x :y` | Simulate gaze |
| `gaze-health` | -- | Gaze health check |

**Gaze Focus (7 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `gaze-focus-config` | -- | Focus config |
| `gaze-focus-status` | -- | Focus status |
| `gaze-focus-set-policy` | `:policy` | Set focus policy |
| `gaze-focus-set-dwell` | `:dwell-ms` | Set dwell time |
| `gaze-focus-set-cooldown` | `:cooldown-ms` | Set cooldown |
| `gaze-focus-analytics` | -- | Focus analytics |
| `gaze-focus-back` | -- | Focus previous |

**Wink/Blink (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `wink-status` | -- | Wink status |
| `wink-config` | -- | Wink config |
| `wink-calibrate-start` | `:eye` | Start calibration |
| `wink-set-confidence` | `:confidence` | Set threshold |

**Gaze Zones (3 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `gaze-zone-status` | -- | Zone status |
| `gaze-zone-config` | -- | Zone config |
| `gaze-zone-set-dwell` | `:zone :dwell-ms` | Set zone dwell |

**Fatigue (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `fatigue-status` | -- | Fatigue level |
| `fatigue-config` | -- | Fatigue config |
| `fatigue-metrics` | -- | Detailed metrics |
| `fatigue-reset` | -- | Reset tracking |

**Headless (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `headless-status` | -- | Headless status |
| `headless-set-resolution` | `:w :h` | Set resolution |
| `headless-add-output` | -- | Add output |
| `headless-remove-output` | -- | Remove output |

**Auto-Type / Secure Input (7 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `autotype` | `:surface-id :text` | Inject keystrokes |
| `autotype-status` | -- | Auto-type status |
| `autotype-abort` | -- | Abort auto-type |
| `autotype-pause` | `:pause` | Pause auto-type |
| `autotype-resume` | -- | Resume auto-type |
| `secure-input-mode` | `:enable` | Toggle secure input |
| `secure-input-status` | -- | Secure input status |

**Gaze Scroll / Link Hints (7 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `gaze-scroll-status` | -- | Scroll status |
| `gaze-scroll-config` | `:top-zone :bottom-zone :max-speed` | Config |
| `gaze-scroll-set-speed` | `:speed` | Set speed |
| `link-hints-load` | `:url` | Load hints |
| `link-hints-confirm` | -- | Confirm hint |
| `link-hints-clear` | -- | Clear hints |
| `link-hints-status` | -- | Hints status |

**Hand Tracking (5 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `hand-tracking-status` | -- | Tracking status |
| `hand-tracking-config` | `:enable :min-confidence ...` | Config |
| `hand-tracking-joint` | `:hand :joint` | Query joint |
| `hand-tracking-skeleton` | `:hand` | Full skeleton |
| `hand-tracking-distance` | `:hand :joint-a :joint-b` | Joint distance |

**Gesture (5 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `gesture-status` | -- | Gesture status |
| `gesture-config` | `:pinch-threshold ...` | Config |
| `gesture-bind` | `:hand :gesture :action` | Bind gesture |
| `gesture-unbind` | `:hand :gesture` | Unbind gesture |
| `gesture-bindings` | -- | List bindings |

**Virtual Keyboard (5 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `keyboard-show` | -- | Show keyboard |
| `keyboard-hide` | -- | Hide keyboard |
| `keyboard-toggle` | -- | Toggle keyboard |
| `keyboard-layout` | `:layout` | Set layout |
| `keyboard-status` | -- | Keyboard status |

**BCI Core (9 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `bci-status` | -- | BCI status |
| `bci-start` | -- | Start acquisition |
| `bci-stop` | -- | Stop acquisition |
| `bci-restart` | -- | Restart |
| `bci-signal-quality` | -- | Signal quality |
| `bci-config` | `:board-id :sample-rate ...` | Config |
| `bci-inject-synthetic` | `:pattern` | Inject test data |
| `bci-data-list` | -- | List sessions |
| `bci-data-delete` | `:session-id` | Delete session |

**BCI Attention (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `bci-attention-status` | -- | Attention status |
| `bci-attention-config` | `:threshold ...` | Config |
| `bci-attention-calibrate-start` | -- | Start calibration |
| `bci-attention-calibrate-finish` | -- | Finish calibration |

**BCI SSVEP (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `bci-ssvep-status` | -- | SSVEP status |
| `bci-ssvep-config` | `:frequencies ...` | Config |
| `bci-ssvep-start` | -- | Start classification |
| `bci-ssvep-stop` | -- | Stop classification |

**BCI P300 (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `bci-p300-status` | -- | P300 status |
| `bci-p300-config` | `:repetitions :soa-ms ...` | Config |
| `bci-p300-start` | `:prompt :targets ...` | Start trial |
| `bci-p300-stop` | -- | Stop trial |

**BCI Motor Imagery (4 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `bci-mi-status` | -- | MI status |
| `bci-mi-config` | `:min-confidence ...` | Config |
| `bci-mi-calibrate-start` | -- | Start calibration |
| `bci-mi-calibrate-finish` | -- | Finish calibration |

**BCI Fatigue EEG (2 commands):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `bci-fatigue-eeg-status` | -- | EEG fatigue status |
| `bci-fatigue-eeg-config` | `:threshold ...` | Config |

**Gaze Away (1 command):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `gaze-away-monitor` | `:enable` | Toggle gaze-away |

**VR Scene Move (1 command):**

| Command | Parameters | Description |
|---------|-----------|-------------|
| `vr-scene-move` | `:surface-id :x :y :z` | Move in 3D |

---

## Writing Elisp Extensions

### Module Pattern

Every ewwm module follows this structure:

```elisp
;;; ewwm-my-feature.el --- Description  -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'ewwm-core)

;; Forward declarations for cross-module calls
(declare-function ewwm-ipc-send "ewwm-ipc")
(declare-function ewwm-ipc-connected-p "ewwm-ipc")

;; ── Customization ────────────────────────
(defgroup ewwm-my-feature nil
  "My feature settings."
  :group 'ewwm-vr)

(defcustom ewwm-my-feature-enabled t
  "Master switch."
  :type 'boolean
  :group 'ewwm-my-feature)

;; ── Internal state ───────────────────────
(defvar ewwm-my-feature--state nil
  "Internal state.")

;; ── Hooks ────────────────────────────────
(defvar ewwm-my-feature-hook nil
  "Hook run on events.")

;; ── IPC event handlers ──────────────────
(defun ewwm-my-feature--on-event (msg)
  "Handle :my-event from compositor."
  (when ewwm-my-feature-enabled
    ;; Process MSG
    ))

;; ── Interactive commands ────────────────
(defun ewwm-my-feature-status ()
  "Display status."
  (interactive)
  (message "status"))

;; ── Event registration ──────────────────
(defun ewwm-my-feature--register-events ()
  "Register IPC event handlers. Idempotent."
  (when (boundp 'ewwm-ipc--event-handlers)
    (let ((handlers
           '((:my-event . ewwm-my-feature--on-event))))
      (dolist (handler handlers)
        (unless (assq (car handler)
                      ewwm-ipc--event-handlers)
          (push handler ewwm-ipc--event-handlers))))))

;; ── Init / teardown ─────────────────────
(defun ewwm-my-feature-init ()
  "Initialize."
  (ewwm-my-feature--register-events))

(defun ewwm-my-feature-teardown ()
  "Clean up."
  (setq ewwm-my-feature--state nil))

(provide 'ewwm-my-feature)
;;; ewwm-my-feature.el ends here
```

### Key Conventions

- Use `lexical-binding: t` in all files
- Use `permanent-local` property on buffer-local variables that must
  survive `define-derived-mode`
- Use `declare-function` for cross-module function references
- Prefix internal variables with `ewwm-MODULE--` (double dash)
- Prefix defcustom variables with `ewwm-MODULE-` (single dash)
- Use `_prefix` for intentionally unused function arguments
- Wrap docstrings at 80 characters (byte-compile warns otherwise)
- Every module must have `init` and `teardown` functions
- Event registration must be idempotent (check before push)

### Sending IPC Commands

```elisp
;; Async (fire-and-forget)
(ewwm-ipc-send '(:type :my-command :param "value"))

;; Async with callback
(ewwm-ipc-send '(:type :my-command)
               (lambda (response)
                 (message "Got: %S" response)))

;; Synchronous (blocks for response)
(let ((resp (ewwm-ipc-send-sync '(:type :my-command))))
  (plist-get resp :result))
```

---

## Writing Rust Modules

### Adding a New VR Module

1. Create `compositor/src/vr/my_module.rs`
2. Add `pub mod my_module;` to `compositor/src/vr/mod.rs`
3. Add state to `VrState` in `openxr_state.rs` and `stub.rs`
4. Add IPC handlers to `compositor/src/ipc/dispatch.rs`

### Module Template

```rust
//! My module description.

/// Main state struct.
pub struct MyModuleState {
    enabled: bool,
    // ...
}

impl MyModuleState {
    pub fn new() -> Self {
        Self { enabled: false }
    }

    pub fn update(&mut self, /* params */) {
        // Processing logic
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new() {
        let state = MyModuleState::new();
        assert!(!state.enabled);
    }
}
```

### Adding IPC Handlers

In `dispatch.rs`, add to the match statement:

```rust
Some("my-command") => handle_my_command(state, msg_id, &value),
```

Then implement the handler:

```rust
fn handle_my_command(
    state: &mut EwwmState,
    msg_id: i64,
    value: &Value,
) -> Option<String> {
    let param = get_string(value, "param").unwrap_or_default();
    // Process command
    Some(ok_response(msg_id))
}
```

### Key Conventions

- Modules with no `openxrs` dependency compile unconditionally
- Use `#[cfg(feature = "vr")]` only for OpenXR-dependent code
- Use `#[cfg(feature = "full-backend")]` for DRM/winit code
- Include unit tests in each module with `#[cfg(test)]`
- Use `tracing::{debug, warn}` for logging
- Helper functions: `get_keyword`, `get_string`, `get_int`,
  `ok_response`, `error_response`, `escape_string`

---

## Adding Gestures

### Elisp Side

Bind gestures in `ewwm-vr-gesture.el`:

```elisp
;; Bind a custom gesture
(ewwm-vr-gesture-bind 'right 'pinch #'my-pinch-action)
(ewwm-vr-gesture-bind 'left 'swipe-up #'scroll-down-command)

;; Available gestures:
;; pinch, grab, point, swipe-left, swipe-right, swipe-up, swipe-down
```

### Rust Side

In `compositor/src/vr/gesture.rs`, add recognition logic for the new
gesture type. The gesture recognizer processes hand joint positions from
`hand_tracking.rs` and emits IPC events:

```elisp
;; Events emitted by the compositor:
(:type :event :event :gesture-started :hand right :gesture pinch)
(:type :event :event :gesture-swipe :hand left :direction up)
(:type :event :event :gesture-ended :hand right :gesture pinch)
```

### Configuration

```elisp
;; Tuning thresholds
(setq ewwm-vr-gesture-pinch-threshold 0.02)    ; meters
(setq ewwm-vr-gesture-grab-threshold 0.04)     ; meters
(setq ewwm-vr-gesture-swipe-min-velocity 0.5)  ; m/s
(setq ewwm-vr-gesture-debounce-ms 200)         ; ms
```

---

## Adding BCI Paradigms

### Pattern

1. Create `lisp/vr/ewwm-bci-PARADIGM.el` following the module pattern
2. Create `compositor/src/vr/PARADIGM.rs` for signal processing
3. Add IPC commands to `dispatch.rs`
4. Register events in your Elisp module's `--register-events`
5. Write tests in `test/ewwm-bci-PARADIGM-test.el`

### Event Flow

```
EEG Hardware -> BrainFlow Daemon -> Compositor (Rust)
    -> Signal Processing -> Classification -> IPC Event
    -> Emacs Event Handler -> Action Dispatch
```

### Key Considerations

- Always include a photosensitivity check for visual stimuli
- Default to disabled (`defcustom ... nil`) for safety
- Include confidence thresholds and cooldown timers
- Provide calibration flow when needed
- Export session data for offline analysis
- Pause during secure input mode

---

## Testing Guide

### Running Tests

```bash
# All ERT tests
just test

# Specific test file
emacs --batch -L lisp/core -L lisp/vr -L lisp/ext \
  -l test/run-tests.el -l test/ewwm-bci-core-test.el \
  -f ert-run-tests-batch-and-exit

# Rust unit tests
cargo test --manifest-path compositor/Cargo.toml

# Headless-only Rust tests (no GPU)
cargo test --manifest-path compositor/Cargo.toml \
  --no-default-features
```

### Test File Inventory

The project currently has 63 ERT test files in `test/`:

- **Core**: `ewwm-core-test.el`, `ewwm-ipc-test.el`,
  `ewwm-manage-test.el`, `exwm-core-test.el`,
  `exwm-input-test.el`, `exwm-workspace-test.el`
- **VR**: `ewwm-vr-test.el`, `ewwm-vr-scene-test.el`,
  `ewwm-vr-display-test.el`, `ewwm-vr-eye-test.el`,
  `ewwm-vr-eye-focus-test.el`, `ewwm-vr-wink-test.el`,
  `ewwm-vr-gaze-zone-test.el`, `ewwm-vr-fatigue-test.el`,
  `ewwm-vr-input-test.el`
- **Hand/Gesture**: `ewwm-hand-tracking-test.el`,
  `ewwm-gesture-test.el`, `ewwm-keyboard-test.el`
- **Secrets**: `ewwm-secrets-test.el`, `ewwm-keepassxc-browser-test.el`,
  `ewwm-secrets-autotype-test.el`, `ewwm-secrets-compositor-test.el`,
  `ewwm-secrets-gaze-away-test.el`, `ewwm-secrets-passkey-test.el`,
  `ewwm-secrets-totp-test.el`, `ewwm-secrets-ydotool-test.el`,
  `ewwm-vr-secure-input-test.el`
- **BCI**: `ewwm-bci-core-test.el`, `ewwm-bci-attention-test.el`,
  `ewwm-bci-ssvep-test.el`, `ewwm-bci-p300-test.el`,
  `ewwm-bci-mi-test.el`, `ewwm-bci-nfb-test.el`,
  `ewwm-bci-multimodal-test.el`
- **Qutebrowser**: `ewwm-qutebrowser-test.el`,
  `ewwm-qutebrowser-feature-test.el`
- **Infrastructure**: `ewwm-environment-test.el`,
  `ewwm-headless-test.el`, `compositor-test.el`,
  `ewwm-benchmark-test.el`
- **Integration**: feature integration test suites (one per subsystem)
- **E2E**: `e2e-flat-desktop-test.el`, `e2e-eye-tracking-test.el`,
  `e2e-bci-mode-test.el`, `e2e-vr-mode-test.el`,
  `e2e-full-stack-test.el`

### Writing ERT Tests

```elisp
(require 'ert)
(require 'ewwm-my-feature)

(ert-deftest ewwm-my-feature-test/init ()
  "Test initialization."
  (ewwm-my-feature-init)
  (should (boundp 'ewwm-my-feature--state)))

(ert-deftest ewwm-my-feature-test/event-handler ()
  "Test event handling."
  (let ((ewwm-my-feature-enabled t))
    (ewwm-my-feature--on-event '(:value 42))
    (should (equal ewwm-my-feature--state 42))))
```

### Common Test Pitfalls

- Use nested `let` (not same `let`) when a lambda captures a lexical
  variable and the hook is bound in the same `let` form
- `defvar` is needed in test files for dynamic variables checked via
  `boundp` (even with `lexical-binding: t`)
- Avoid unused `let` bindings -- byte-compile catches them
- Handler functions that check `--monitoring` state: tests must bind
  the monitoring variable to `t`
- Use `_prefix` for intentionally unused function arguments

---

## Pre-Commit Hooks

The pre-commit hook at `.githooks/pre-commit` performs:

1. **Byte-compilation** of modified `.el` files with load path
   `-L lisp/core -L lisp/vr -L lisp/ext`
2. **Secrets detection**: scans for API keys, passwords, private keys
3. **Trailing whitespace** check
4. **Large binary** rejection (> 1 MiB)

The commit-msg hook enforces conventional commit format.

Configure:

```bash
git config core.hooksPath .githooks
```

### Known Exclusions

- `.dir-locals.el` is excluded from byte-compilation
- Test files are compiled with the full load path

---

## CI Pipeline

### GitHub Actions Workflows

**`multi-arch.yml` (5 jobs):**

1. **lint-elisp**: byte-compile all `.el` files
2. **lint-rust**: `cargo clippy` on compositor
3. **test-ert**: run ERT test suite in Emacs batch mode
4. **test-rust**: `cargo test` (x86_64)
5. **cross-compile**: build for aarch64 and s390x

**`ert-tests.yml` (lightweight):**

- Runs on PRs targeting `main` or `dev`
- Emacs batch mode ERT execution
- Fast feedback loop

### Running CI Locally

```bash
# Full CI pipeline
just ci

# Lint only
just lint-all

# Tests only
just test
just test-compositor
```

---

## Contributing Guidelines

### Branch Model

Three-tier: `main` <- `dev` <- `feature/TOPIC`

- `main`: stable releases
- `dev`: integration branch
- `feature/*`: individual features

### Commit Style

Conventional commits with scoped types:

```
feat(bci): add alpha neurofeedback protocol
fix(ipc): handle oversized message gracefully
refactor(gaze): extract saccade detector into module
test(p300): add confidence threshold edge cases
docs(vr): update HMD compatibility table
```

### Pull Request Checklist

- [ ] All ERT tests pass (`just test`)
- [ ] Rust tests pass (`cargo test` in compositor/)
- [ ] Pre-commit hooks pass
- [ ] New features have corresponding test files
- [ ] New IPC commands documented in dispatch.rs comments
- [ ] Docstrings wrapped at 80 characters
- [ ] No secrets or credentials in staged files

### Code Review Focus Areas

1. **IPC consistency**: new commands follow existing patterns
2. **Event idempotency**: handler registration checks for duplicates
3. **Teardown completeness**: all state variables reset
4. **Feature flag correctness**: no unconditional openxrs imports
5. **Security**: no biometric data in logs or traces
