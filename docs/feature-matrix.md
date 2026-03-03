# XoxdWM (EXWM-VR) Feature Matrix

Comprehensive reference for all IPC commands, subsystems, platform support,
hardware requirements, and module inventory as of v0.1.0.

---

## 1. IPC Command Reference

Every command recognized by `compositor/src/ipc/dispatch.rs` is listed below,
grouped by subsystem.  The match dispatch contains **131 commands** total.

### 1.1 Protocol & Core WM (Weeks 3-5)

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `hello` | dispatch.rs | ewwm-ipc | none |
| `ping` | dispatch.rs | ewwm-ipc | none |
| `surface-list` | state.rs | ewwm-manage | none |
| `surface-focus` | state.rs | ewwm-manage | none |
| `surface-close` | state.rs | ewwm-manage | none |
| `surface-move` | state.rs | ewwm-floating | none |
| `surface-resize` | state.rs | ewwm-floating | none |
| `surface-fullscreen` | state.rs | ewwm-layout | none |
| `surface-float` | state.rs | ewwm-floating | none |
| `workspace-switch` | state.rs | ewwm-workspace | none |
| `workspace-list` | state.rs | ewwm-workspace | none |
| `workspace-move-surface` | state.rs | ewwm-workspace | none |
| `layout-set` | state.rs | ewwm-layout | none |
| `layout-cycle` | state.rs | ewwm-layout | none |
| `key-grab` | state.rs | ewwm-input | none |
| `key-ungrab` | state.rs | ewwm-input | none |

### 1.2 VR Core / OpenXR

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `vr-status` | openxr_state.rs / stub.rs | ewwm-vr | HMD |
| `vr-set-reference-space` | openxr_state.rs / stub.rs | ewwm-vr | HMD |
| `vr-restart` | openxr_state.rs / stub.rs | ewwm-vr | HMD |
| `vr-get-frame-timing` | frame_timing.rs | ewwm-vr | HMD |

### 1.3 VR Scene Graph

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `vr-scene-status` | scene.rs | ewwm-vr-scene | GPU |
| `vr-scene-set-layout` | scene.rs | ewwm-vr-scene | GPU |
| `vr-scene-set-ppu` | scene.rs | ewwm-vr-scene | GPU |
| `vr-scene-set-background` | scene.rs | ewwm-vr-scene | GPU |
| `vr-scene-set-projection` | scene.rs | ewwm-vr-scene | GPU |
| `vr-scene-focus` | scene.rs | ewwm-vr-scene | GPU |
| `vr-scene-move` | scene.rs | ewwm-vr-scene | GPU |

### 1.4 VR Display / DRM Lease

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `vr-display-info` | drm_lease.rs | ewwm-vr-display | HMD |
| `vr-display-set-mode` | drm_lease.rs | ewwm-vr-display | HMD |
| `vr-display-select-hmd` | drm_lease.rs | ewwm-vr-display | HMD |
| `vr-display-set-refresh-rate` | drm_lease.rs | ewwm-vr-display | HMD |
| `vr-display-auto-detect` | drm_lease.rs | ewwm-vr-display | HMD |
| `vr-display-list-connectors` | drm_lease.rs | ewwm-vr-display | HMD |

### 1.5 VR Interaction / Pointer

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `vr-pointer-state` | vr_interaction.rs | ewwm-vr-input | HMD |
| `vr-click` | vr_interaction.rs | ewwm-vr-input | HMD |
| `vr-grab` | vr_interaction.rs | ewwm-vr-input | HMD |
| `vr-grab-release` | vr_interaction.rs | ewwm-vr-input | HMD |
| `vr-adjust-depth` | vr_interaction.rs | ewwm-vr-input | HMD |
| `vr-set-follow` | vr_interaction.rs | ewwm-vr-input | HMD |
| `vr-set-gaze-offset` | vr_interaction.rs | ewwm-vr-input | HMD |
| `vr-calibrate-confirm` | vr_interaction.rs | ewwm-vr-input | HMD |

### 1.6 Eye Tracking

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `gaze-status` | eye_tracking.rs | ewwm-vr-eye | eye tracker |
| `gaze-set-source` | eye_tracking.rs | ewwm-vr-eye | eye tracker |
| `gaze-calibrate-start` | eye_tracking.rs | ewwm-vr-eye | eye tracker |
| `gaze-calibrate-point` | eye_tracking.rs | ewwm-vr-eye | eye tracker |
| `gaze-set-visualization` | eye_tracking.rs | ewwm-vr-eye | eye tracker |
| `gaze-set-smoothing` | eye_tracking.rs | ewwm-vr-eye | eye tracker |
| `gaze-simulate` | eye_tracking.rs | ewwm-vr-eye | none |
| `gaze-health` | eye_tracking.rs | ewwm-vr-eye | eye tracker |

### 1.7 Gaze Focus

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `gaze-focus-config` | gaze_focus.rs | ewwm-vr-eye | eye tracker |
| `gaze-focus-status` | gaze_focus.rs | ewwm-vr-eye | eye tracker |
| `gaze-focus-set-policy` | gaze_focus.rs | ewwm-vr-eye | eye tracker |
| `gaze-focus-set-dwell` | gaze_focus.rs | ewwm-vr-eye | eye tracker |
| `gaze-focus-set-cooldown` | gaze_focus.rs | ewwm-vr-eye | eye tracker |
| `gaze-focus-analytics` | gaze_focus.rs | ewwm-vr-eye | eye tracker |
| `gaze-focus-back` | gaze_focus.rs | ewwm-vr-eye | eye tracker |

### 1.8 Blink / Wink Detection

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `wink-status` | blink_wink.rs | ewwm-vr-wink | eye tracker |
| `wink-config` | blink_wink.rs | ewwm-vr-wink | eye tracker |
| `wink-calibrate-start` | blink_wink.rs | ewwm-vr-wink | eye tracker |
| `wink-set-confidence` | blink_wink.rs | ewwm-vr-wink | eye tracker |

### 1.9 Gaze Zones

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `gaze-zone-status` | gaze_zone.rs | ewwm-vr-gaze-zone | eye tracker |
| `gaze-zone-config` | gaze_zone.rs | ewwm-vr-gaze-zone | eye tracker |
| `gaze-zone-set-dwell` | gaze_zone.rs | ewwm-vr-gaze-zone | eye tracker |

### 1.10 Eye Fatigue Monitoring

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `fatigue-status` | fatigue.rs | ewwm-vr-fatigue | eye tracker |
| `fatigue-config` | fatigue.rs | ewwm-vr-fatigue | eye tracker |
| `fatigue-metrics` | fatigue.rs | ewwm-vr-fatigue | eye tracker |
| `fatigue-reset` | fatigue.rs | ewwm-vr-fatigue | eye tracker |

### 1.11 Auto-Type & Secure Input

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `autotype` | autotype.rs | ewwm-secrets-autotype | none |
| `autotype-status` | autotype.rs | ewwm-secrets-autotype | none |
| `autotype-abort` | autotype.rs | ewwm-secrets-autotype | none |
| `autotype-pause` | autotype.rs | ewwm-secrets-autotype | none |
| `autotype-resume` | autotype.rs | ewwm-secrets-autotype | none |
| `secure-input-mode` | secure_input.rs | ewwm-vr-secure-input | none |
| `secure-input-status` | secure_input.rs | ewwm-vr-secure-input | none |
| `gaze-away-monitor` | secure_input.rs | ewwm-secrets-gaze-away | eye tracker |

### 1.12 Headless Backend

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `headless-status` | backend/headless.rs | ewwm-headless | none |
| `headless-set-resolution` | backend/headless.rs | ewwm-headless | none |
| `headless-add-output` | backend/headless.rs | ewwm-headless | none |
| `headless-remove-output` | backend/headless.rs | ewwm-headless | none |

### 1.13 Gaze Scroll & Link Hints

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `gaze-scroll-status` | gaze_scroll.rs | ewwm-qutebrowser-gaze | eye tracker |
| `gaze-scroll-config` | gaze_scroll.rs | ewwm-qutebrowser-gaze | eye tracker |
| `gaze-scroll-set-speed` | gaze_scroll.rs | ewwm-qutebrowser-gaze | eye tracker |
| `link-hints-load` | link_hints.rs | ewwm-qutebrowser-gaze | eye tracker |
| `link-hints-confirm` | link_hints.rs | ewwm-qutebrowser-gaze | eye tracker |
| `link-hints-clear` | link_hints.rs | ewwm-qutebrowser-gaze | eye tracker |
| `link-hints-status` | link_hints.rs | ewwm-qutebrowser-gaze | eye tracker |

### 1.14 Hand Tracking

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `hand-tracking-status` | hand_tracking.rs | ewwm-vr-hand | hand tracker |
| `hand-tracking-config` | hand_tracking.rs | ewwm-vr-hand | hand tracker |
| `hand-tracking-joint` | hand_tracking.rs | ewwm-vr-hand | hand tracker |
| `hand-tracking-skeleton` | hand_tracking.rs | ewwm-vr-hand | hand tracker |
| `hand-tracking-distance` | hand_tracking.rs | ewwm-vr-hand | hand tracker |

### 1.15 Gesture Recognition

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `gesture-status` | gesture.rs | ewwm-vr-gesture | hand tracker |
| `gesture-config` | gesture.rs | ewwm-vr-gesture | hand tracker |
| `gesture-bind` | gesture.rs | ewwm-vr-gesture | hand tracker |
| `gesture-unbind` | gesture.rs | ewwm-vr-gesture | hand tracker |
| `gesture-bindings` | gesture.rs | ewwm-vr-gesture | hand tracker |

### 1.16 Virtual Keyboard

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `keyboard-show` | virtual_keyboard.rs | ewwm-vr-keyboard | hand tracker |
| `keyboard-hide` | virtual_keyboard.rs | ewwm-vr-keyboard | hand tracker |
| `keyboard-toggle` | virtual_keyboard.rs | ewwm-vr-keyboard | hand tracker |
| `keyboard-layout` | virtual_keyboard.rs | ewwm-vr-keyboard | hand tracker |
| `keyboard-status` | virtual_keyboard.rs | ewwm-vr-keyboard | hand tracker |

### 1.17 BCI Core

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `bci-status` | bci_state.rs | ewwm-bci-core | EEG headset |
| `bci-start` | bci_state.rs | ewwm-bci-core | EEG headset |
| `bci-stop` | bci_state.rs | ewwm-bci-core | EEG headset |
| `bci-restart` | bci_state.rs | ewwm-bci-core | EEG headset |
| `bci-signal-quality` | bci_state.rs | ewwm-bci-core | EEG headset |
| `bci-config` | bci_state.rs | ewwm-bci-core | EEG headset |
| `bci-inject-synthetic` | bci_state.rs | ewwm-bci-core | none |
| `bci-data-list` | bci_state.rs | ewwm-bci-core | none |
| `bci-data-delete` | bci_state.rs | ewwm-bci-core | none |

### 1.18 BCI Attention

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `bci-attention-status` | attention.rs | ewwm-bci-attention | EEG headset |
| `bci-attention-config` | attention.rs | ewwm-bci-attention | EEG headset |
| `bci-attention-calibrate-start` | attention.rs | ewwm-bci-attention | EEG headset |
| `bci-attention-calibrate-finish` | attention.rs | ewwm-bci-attention | EEG headset |

### 1.19 BCI SSVEP

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `bci-ssvep-status` | ssvep.rs | ewwm-bci-ssvep | EEG headset |
| `bci-ssvep-config` | ssvep.rs | ewwm-bci-ssvep | EEG headset |
| `bci-ssvep-start` | ssvep.rs | ewwm-bci-ssvep | EEG headset |
| `bci-ssvep-stop` | ssvep.rs | ewwm-bci-ssvep | EEG headset |

### 1.20 BCI P300

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `bci-p300-status` | p300.rs | ewwm-bci-p300 | EEG headset |
| `bci-p300-config` | p300.rs | ewwm-bci-p300 | EEG headset |
| `bci-p300-start` | p300.rs | ewwm-bci-p300 | EEG headset |
| `bci-p300-stop` | p300.rs | ewwm-bci-p300 | EEG headset |

### 1.21 BCI Motor Imagery

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `bci-mi-status` | motor_imagery.rs | ewwm-bci-mi | EEG headset |
| `bci-mi-config` | motor_imagery.rs | ewwm-bci-mi | EEG headset |
| `bci-mi-calibrate-start` | motor_imagery.rs | ewwm-bci-mi | EEG headset |
| `bci-mi-calibrate-finish` | motor_imagery.rs | ewwm-bci-mi | EEG headset |

### 1.22 BCI EEG Fatigue

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `bci-fatigue-eeg-status` | fatigue_eeg.rs | ewwm-bci-core | EEG headset |
| `bci-fatigue-eeg-config` | fatigue_eeg.rs | ewwm-bci-core | EEG headset |

### 1.23 IPC Recording (v0.2.0 preview)

| Command | Rust module | Elisp module | Hardware |
|---------|-------------|--------------|----------|
| `ipc-record-start` | recorder.rs | ewwm-ipc | none |
| `ipc-record-stop` | recorder.rs | ewwm-ipc | none |
| `ipc-record-status` | recorder.rs | ewwm-ipc | none |

---

## 2. Subsystem Overview

| Subsystem | Rust modules | Elisp modules | IPC commands | Rust unit tests |
|-----------|-------------|---------------|-------------|----------------|
| Core WM | state.rs, dispatch.rs | ewwm-core, ewwm-ipc, ewwm-manage, ewwm-floating, ewwm-workspace, ewwm-layout, ewwm-input, ewwm-launch | 16 | 0 |
| VR / OpenXR | openxr_state.rs, stub.rs, frame_timing.rs | ewwm-vr | 4 | 5 |
| VR Scene | scene.rs, texture.rs, vr_renderer.rs | ewwm-vr-scene | 7 | 21 |
| VR Display | drm_lease.rs | ewwm-vr-display | 6 | 14 |
| VR Interaction | vr_interaction.rs | ewwm-vr-input | 8 | 22 |
| Eye Tracking | eye_tracking.rs | ewwm-vr-eye | 8 | 16 |
| Gaze Focus | gaze_focus.rs | ewwm-vr-eye | 7 | 12 |
| Blink / Wink | blink_wink.rs | ewwm-vr-wink | 4 | 10 |
| Gaze Zones | gaze_zone.rs | ewwm-vr-gaze-zone | 3 | 9 |
| Eye Fatigue | fatigue.rs | ewwm-vr-fatigue | 4 | 9 |
| Auto-Type | autotype.rs, secure_input.rs | ewwm-secrets-autotype, ewwm-vr-secure-input, ewwm-secrets-gaze-away | 8 | 25 |
| Secrets | -- | ewwm-secrets, ewwm-keepassxc-browser, ewwm-secrets-compositor, ewwm-secrets-ydotool, ewwm-secrets-totp, ewwm-secrets-passkey | 0 | 0 |
| Headless | backend/headless.rs | ewwm-headless | 4 | 0 |
| Gaze Scroll | gaze_scroll.rs | ewwm-qutebrowser-gaze | 3 | 9 |
| Link Hints | link_hints.rs | ewwm-qutebrowser-gaze | 4 | 9 |
| Qutebrowser | -- | ewwm-qutebrowser, ewwm-qutebrowser-ipc, ewwm-qutebrowser-tabs, ewwm-qutebrowser-theme, ewwm-qutebrowser-consult, ewwm-qutebrowser-downloads, ewwm-qutebrowser-reader, ewwm-qutebrowser-adblock, ewwm-qutebrowser-userscript | 0 | 0 |
| Hand Tracking | hand_tracking.rs | ewwm-vr-hand | 5 | 15 |
| Gesture | gesture.rs | ewwm-vr-gesture | 5 | 15 |
| Virtual Keyboard | virtual_keyboard.rs | ewwm-vr-keyboard | 5 | 16 |
| BCI Core | bci_state.rs | ewwm-bci-core | 9 | 9 |
| BCI Attention | attention.rs | ewwm-bci-attention | 4 | 10 |
| BCI SSVEP | ssvep.rs | ewwm-bci-ssvep | 4 | 8 |
| BCI P300 | p300.rs | ewwm-bci-p300 | 4 | 9 |
| BCI Motor Imagery | motor_imagery.rs | ewwm-bci-mi | 4 | 8 |
| BCI EEG Fatigue | fatigue_eeg.rs | ewwm-bci-core | 2 | 9 |
| BCI Multimodal | -- | ewwm-bci-multimodal | 0 | 0 |
| BCI Neurofeedback | -- | ewwm-bci-nfb | 0 | 0 |
| Benchmark | -- | ewwm-benchmark | 0 | 0 |
| Environment | -- | ewwm-environment | 0 | 0 |
| IPC Recording | recorder.rs | ewwm-ipc | 3 | 7 |
| Extension Framework | -- | ewwm-ext | 0 | 0 |
| **Totals** | **25 VR + 7 compositor** | **48 ewwm-* + 1 ext** | **131** | **271** |

---

## 3. Platform Support Matrix

| Platform | GPU compositor | Headless | VR (OpenXR) | Eye tracking | Hand tracking | BCI |
|----------|---------------|----------|-------------|-------------|--------------|-----|
| x86_64 NixOS | Full | Full | Full | Full | Full | Full |
| x86_64 Rocky 9/10 | Full | Full | Full | Full | Full | Full |
| aarch64 NixOS | Full | Full | Limited (1) | Full | Full | Full |
| aarch64 Rocky | Full | Full | Limited (1) | Full | Full | Full |
| s390x Rocky | -- | Full | -- | -- | -- | -- |
| macOS (dev only) | -- | -- | -- | -- | -- | -- |

Notes:
1. aarch64 VR is limited because Monado/OpenXR runtime support for ARM HMDs
   is less mature; WiVRn streaming is the primary path.
2. s390x targets headless-only operation (CI, testing, remote Emacs).
3. macOS cannot compile the Wayland compositor; used only for Elisp
   development and ERT testing.

---

## 4. Hardware Requirements

| Hardware | Required by | Can be simulated via IPC | Notes |
|----------|------------|--------------------------|-------|
| GPU (OpenGL/Vulkan) | VR scene, compositor rendering | No (headless backend available) | Mesa or proprietary; see `docs/gpu-compatibility.md` |
| HMD (VR headset) | OpenXR session, VR display, VR interaction | Partially (`vr-status` returns stub data) | Valve Index, Quest via WiVRn, any OpenXR-compatible |
| Eye tracker | Gaze, focus, wink, zones, fatigue, gaze scroll, link hints, gaze-away | Yes (`gaze-simulate` IPC command) | Built-in HMD eye tracking or Tobii |
| Hand tracking controller | Hand tracking, gestures, virtual keyboard | Yes (IPC inject) | Leap Motion, Quest hand tracking, Ultraleap |
| EEG headset | All BCI subsystems | Yes (`bci-inject-synthetic` IPC command) | OpenBCI (8/16ch), Muse, any LSL-compatible |
| D-Bus | Secret Service, KeePassXC browser protocol | No | Standard on Linux desktops |
| ydotool | ydotool auto-type backend | No | Wayland-compatible input injection |
| qutebrowser | All qutebrowser-* modules | No | QtWebEngine-based browser |

---

## 5. Elisp Module Inventory

### 5.1 EWWM Modules (Wayland / VR)

| Module | Description | Week |
|--------|------------|------|
| ewwm-core | Core definitions for EWWM | 5 |
| ewwm-ipc | IPC client for EWWM compositor | 4 |
| ewwm-launch | Application launcher for EWWM | 5 |
| ewwm-manage | Surface lifecycle for EWWM | 5 |
| ewwm-floating | Floating window support for EWWM | 5 |
| ewwm-workspace | Workspace management for EWWM | 5 |
| ewwm-layout | Layout management for EWWM | 5 |
| ewwm-input | Input handling for EWWM | 5 |
| ewwm-vr | VR subsystem for EWWM | 7 |
| ewwm-vr-scene | VR scene management for EWWM | 8 |
| ewwm-vr-display | VR display and HMD management | 9 |
| ewwm-vr-input | VR input handling | 10 |
| ewwm-vr-eye | Eye tracking integration | 11-12 |
| ewwm-vr-wink | Wink-based interaction for EWWM | 13 |
| ewwm-vr-gaze-zone | Gaze zone modifier system | 13 |
| ewwm-vr-fatigue | Eye fatigue monitoring | 13 |
| ewwm-secrets | D-Bus Secret Service backend for EWWM | 14 |
| ewwm-keepassxc-browser | KeePassXC Browser Protocol for EWWM | 14 |
| ewwm-secrets-autotype | Auto-type dispatcher for EWWM secrets | 14 |
| ewwm-secrets-compositor | Compositor auto-type backend | 14 |
| ewwm-secrets-ydotool | Ydotool auto-type backend for EWWM | 14 |
| ewwm-secrets-gaze-away | Gaze-away detection during auto-type | 14 |
| ewwm-secrets-totp | TOTP integration for EWWM secrets management | 14 |
| ewwm-secrets-passkey | WebAuthn/FIDO2 passkey support for EWWM via KeePassXC | 14 |
| ewwm-vr-secure-input | Secure input mode for EWWM | 14 |
| ewwm-environment | Environment validation for EXWM-VR | 15 |
| ewwm-headless | Headless mode for EWWM | 16 |
| ewwm-qutebrowser | Qutebrowser integration for EWWM | 17 |
| ewwm-qutebrowser-ipc | Qutebrowser IPC layer for EWWM | 17 |
| ewwm-qutebrowser-tabs | Tab-as-buffer for qutebrowser | 17 |
| ewwm-qutebrowser-theme | Theme sync for qutebrowser | 17 |
| ewwm-qutebrowser-consult | Consult sources for qutebrowser | 17 |
| ewwm-qutebrowser-downloads | Download manager for qutebrowser | 17 |
| ewwm-qutebrowser-reader | Reader mode for qutebrowser | 17 |
| ewwm-qutebrowser-adblock | Ad blocker for qutebrowser | 17 |
| ewwm-qutebrowser-userscript | Userscript bridge for qutebrowser | 17 |
| ewwm-qutebrowser-gaze | Gaze-driven browsing for qutebrowser | 17 |
| ewwm-vr-hand | Hand tracking integration | 18 |
| ewwm-vr-gesture | Gesture recognition for EWWM | 18 |
| ewwm-vr-keyboard | VR virtual keyboard for EWWM | 18 |
| ewwm-bci-core | BCI lifecycle and daemon management | 19 |
| ewwm-bci-attention | Attention state tracking | 19 |
| ewwm-bci-ssvep | SSVEP workspace selection | 19 |
| ewwm-bci-p300 | P300 confirmation system | 19 |
| ewwm-bci-mi | Motor imagery classification | 19 |
| ewwm-bci-nfb | Neurofeedback training mode | 19 |
| ewwm-bci-multimodal | Multi-modal fusion | 19 |
| ewwm-benchmark | Benchmark harness for EWWM | 20 |

### 5.2 Extension Framework

| Module | Description |
|--------|------------|
| ewwm-ext | Extension framework for EWWM plugins |

### 5.3 Legacy EXWM Modules (X11)

| Module | Description |
|--------|------------|
| exwm-core | Core definitions |
| exwm-background | X Background Module for EXWM |
| exwm-floating | Floating Module for EXWM |
| exwm-input | Input Module for EXWM |
| exwm-layout | Layout Module for EXWM |
| exwm-manage | Window Management Module for EXWM |
| exwm-randr | RandR Module for EXWM |
| exwm-systemtray | System Tray Module for EXWM |
| exwm-workspace | Workspace Module for EXWM |
| exwm-xim | XIM Module for EXWM |
| exwm-xsettings | XSETTINGS Module for EXWM |

---

## 6. Test Coverage Summary

### ERT Tests (Emacs Lisp)

| Category | Test files | Approx. tests |
|----------|-----------|---------------|
| Core WM | ewwm-core-test, ewwm-ipc-test, ewwm-manage-test | ~80 |
| VR | ewwm-vr-test, ewwm-vr-scene-test, ewwm-vr-display-test | ~60 |
| VR Input | ewwm-vr-input-test | ~30 |
| Eye Tracking | ewwm-vr-eye-test, ewwm-vr-eye-focus-test | ~77 |
| Wink / Zones / Fatigue | ewwm-vr-wink-test, ewwm-vr-gaze-zone-test, ewwm-vr-fatigue-test | ~130 |
| Secrets / Auto-type | ewwm-secrets-test, ewwm-keepassxc-browser-test, ewwm-secrets-autotype-test, ewwm-secrets-compositor-test, ewwm-secrets-ydotool-test, ewwm-secrets-totp-test, ewwm-secrets-passkey-test, ewwm-secrets-gaze-away-test, ewwm-vr-secure-input-test | ~228 |
| Headless | ewwm-headless-test | ~96 |
| Qutebrowser | ewwm-qutebrowser-test, ewwm-qutebrowser-feature-test | ~80 |
| Hand / Gesture / Keyboard | ewwm-hand-tracking-test, ewwm-gesture-test, ewwm-keyboard-test | ~93 |
| BCI | ewwm-bci-core-test, ewwm-bci-attention-test, ewwm-bci-ssvep-test, ewwm-bci-p300-test, ewwm-bci-mi-test, ewwm-bci-multimodal-test, ewwm-bci-nfb-test | ~185 |
| Benchmark / Environment | ewwm-benchmark-test, ewwm-environment-test | ~39 |
| Legacy EXWM | exwm-core-test, exwm-input-test, exwm-workspace-test | ~30 |
| Integration (weekly) | week1 through week20-integration-test | ~200 |
| E2E suites | e2e-flat-desktop-test, e2e-vr-mode-test, e2e-eye-tracking-test, e2e-bci-mode-test, e2e-full-stack-test | 123 |
| **Total** | **63 test files** | **1554** |

### Rust Unit Tests

| Module | Tests |
|--------|-------|
| vr_interaction.rs | 22 |
| eye_tracking.rs | 16 |
| virtual_keyboard.rs | 16 |
| hand_tracking.rs | 15 |
| gesture.rs | 15 |
| autotype.rs | 14 |
| scene.rs | 14 |
| drm_lease.rs | 14 |
| gaze_focus.rs | 12 |
| secure_input.rs | 11 |
| attention.rs | 10 |
| blink_wink.rs | 10 |
| bci_state.rs | 9 |
| fatigue.rs | 9 |
| fatigue_eeg.rs | 9 |
| gaze_zone.rs | 9 |
| gaze_scroll.rs | 9 |
| link_hints.rs | 9 |
| p300.rs | 9 |
| motor_imagery.rs | 8 |
| ssvep.rs | 8 |
| recorder.rs | 7 |
| frame_timing.rs | 5 |
| clock.rs | 4 |
| vr_renderer.rs | 4 |
| texture.rs | 3 |
| **Total** | **271** |

### E2E Integration Test Suites

| Suite | Tests | Scope |
|-------|-------|-------|
| Flat desktop | 27 | Core WM, workspaces, layout, input |
| VR mode | 25 | OpenXR session, scene, display, interaction |
| Eye tracking | 28 | Gaze, focus, wink, zones, fatigue |
| BCI mode | 20 | EEG session, attention, SSVEP, P300, MI |
| Full stack | 23 | Boot sequence, multi-subsystem coordination |
| **Total** | **123** | |

---

## 7. Compositor Rust Module Map

```
compositor/src/
  main.rs              -- Entry point, CLI, calloop event loop
  state.rs             -- EwwmState: central compositor state
  clock.rs             -- Monotonic clock abstraction
  input.rs             -- Keyboard/pointer input dispatch
  render.rs            -- Frame rendering pipeline
  autotype.rs          -- AutoTypeManager state machine
  secure_input.rs      -- SecureInputState for credential entry
  backend/
    mod.rs             -- Backend trait and selection
    drm.rs             -- DRM/KMS backend (full-backend feature)
    winit.rs           -- Winit backend (full-backend feature)
    headless.rs        -- Headless backend (always compiled)
  handlers/
    mod.rs             -- Handler trait implementations
    compositor.rs      -- wl_compositor
    xdg_shell.rs       -- xdg_shell (toplevel, popup)
    xwayland.rs        -- XWayland bridge (XwmHandler)
    seat.rs            -- wl_seat (keyboard, pointer)
    shm.rs             -- wl_shm buffer management
    layer_shell.rs     -- wlr-layer-shell protocol
    foreign_toplevel.rs -- foreign-toplevel-list protocol
  ipc/
    mod.rs             -- IPC module root
    server.rs          -- Unix domain socket server
    dispatch.rs        -- S-expression parser & 131-command router
    recorder.rs        -- IPC session recording/replay
  vr/
    mod.rs             -- VR module root, feature-gated re-exports
    openxr_state.rs    -- OpenXR session lifecycle (vr feature)
    stub.rs            -- Stub VrState (non-vr builds)
    frame_timing.rs    -- Frame timing statistics (vr feature)
    texture.rs         -- DMA-BUF texture import (vr feature)
    vr_renderer.rs     -- Stereo renderer (vr feature)
    scene.rs           -- 3D scene graph (Vec3, Quat, Mat4, SceneNode)
    drm_lease.rs       -- DRM lease / HMD connector management
    vr_interaction.rs  -- VR pointer, grab, depth, follow
    eye_tracking.rs    -- Eye tracking core pipeline
    gaze_focus.rs      -- Dwell focus, saccade detection, reading detection
    blink_wink.rs      -- Blink detector, wink classifier, calibration
    gaze_zone.rs       -- 9-zone gaze region detection
    fatigue.rs         -- Eye fatigue monitoring
    gaze_scroll.rs     -- Edge-zone gaze scrolling
    link_hints.rs      -- Link hint overlay with dwell confirm
    hand_tracking.rs   -- 26-joint hand skeleton, EMA smoothing
    gesture.rs         -- Pinch/grab/point/palm/swipe recognition
    virtual_keyboard.rs -- QWERTY/Dvorak/Colemak VR keyboard
    bci_state.rs       -- BCI board connection, session lifecycle
    attention.rs       -- Attention levels from alpha/beta/theta bands
    ssvep.rs           -- SSVEP classifier (Goertzel algorithm)
    p300.rs            -- P300 detector (oddball paradigm)
    motor_imagery.rs   -- Motor imagery (ERD at C3/C4/Cz)
    fatigue_eeg.rs     -- EEG-based fatigue (5 weighted indicators)
```
