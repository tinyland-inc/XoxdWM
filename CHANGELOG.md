# Changelog

All notable changes to EXWM-VR will be documented in this file.

## [0.5.0] - 2026-03-04

### Bug Fixes

- **nix:** Regenerate Cargo.lock to include glow crate
- **vr:** Resolve 13 compilation errors in openxr_state.rs
- **vr:** Resolve remaining 3 compilation errors + add v0.5.0 roadmap
- **packaging:** Address installation audit — Rocky 10 + NixOS integration
- **ci:** Resolve 4 Smithay 0.7 compilation errors + 6 test failures
- **packaging:** Udev permissions, non_desktop rule, GPU tools, Beyond power-on
- **vr:** Correct Beyond HID report ID + auto power-on service

### Documentation

- **vr:** Beyond 2e bootstrap analysis and action plan
- **vr:** Update analysis with live DP-2 diagnostics + VFIO findings

### Features

- **vr:** Real GL renderer, OpenXR session lifecycle, texture management
- **ci:** Migrate to GloriousFlywheel ARC runners + VR hardware workflow
- **ext:** Add ewwm-ext extension framework
- **v0.5.0:** Phase 1 — 7 Wayland protocols, session mgmt, Beyond 2e support
- **v0.5.0:** DPMS output power, data-control stub, 40 Phase 1 tests
- **v0.5.0:** Phase 2 — audio, notifications, session packaging fixes
- **v0.5.0:** Phase 2 — screencopy, output mgmt, dark mode portal
- **vr:** Phase 3 — follow mode, gaze focus routing, passthrough
- **vr:** Phase 3 — transient chains, XR overlays, spatial anchors
- **v0.5.0:** Phase 3/4/5 — radial menu, capture visibility, GPU power, JSON config
- **ci:** GloriousFlywheel self-hosted runner workflows + compilation fix
- **packaging:** Beyond 2e bootstrap scripts + udev rule update
- **vr:** Beyond 2e HID control module + Emacs integration
- **vr:** Implement LinuxHidTransport for real Beyond HID control

### Refactoring

- **packaging:** Unified exwm-vr-setup entrypoint + Justfile restructure

## [0.5.0] - 2026-03-04

### Features

- **nix:** Rocky 10 first-class deployment — VM tests, home-manager systemd, SELinux (v0.5.0) (#7)

### Refactoring

- Repo cleanup — version sync, DRY IPC registration, archive sprint artifacts

## [0.4.1] - 2026-02-12

### Features

- **ipc:** Fullscreen, float, workspace-move & layout commands (v0.4.1)

## [0.4.0] - 2026-02-12

### Features

- **compositor:** Focus tracking, click-to-focus & surface metadata (v0.4.0)

## [0.3.1] - 2026-02-12

### Features

- **ipc:** SO_PEERCRED authentication and per-client rate limiting (v0.3.1)

## [0.3.0] - 2026-02-12

### Bug Fixes

- **ci:** Update tests for lib.rs refactor and Rocky Linux 9

### Features

- **compositor:** Surface correlation, DRM backend & render pipeline (v0.3.0)

## [0.2.0] - 2026-02-12

### Features

- **testing:** IO abstraction, integration tests, CI & docs (v0.2.0)

### Miscellaneous

- Remove PLAN.md from main (completed)

## [0.1.0] - 2026-02-11

### Bug Fixes

- **core:** Add declare-function and noninteractive guards

### Documentation

- Add anvil compositor patterns research
- Week 3 research — VR texture pipeline, wxrd, Space evaluation
- IPC encoding format benchmark research

### Features

- Initial EXWM fork (XoxdWM)
- Week 1 project scaffold and architecture validation
- **compositor:** Week 3 Smithay compositor scaffold
- **ipc:** Week 4 IPC protocol design and implementation
- **ewwm:** Week 5 Emacs window management layer
- **compositor:** Week 6 XWayland and application compatibility
- **vr:** Week 7 OpenXR runtime integration
- **vr:** Week 8 VR scene rendering
- **vr:** Week 9 DRM lease and HMD display management
- **vr:** Implement VR window interaction (week 10)
- **vr:** Implement eye tracking hardware integration (week 11)
- **vr:** Implement gaze-based window focus (week 12)
- **week13:** Blink/wink detection, gaze zones, fatigue monitoring
- **secrets:** Add KeePassXC & secrets integration (Week 14)
- **packaging:** NixOS module, RPM spec, systemd & SELinux (Week 15)
- **multiarch:** Headless compositor, cross-compilation & CI (Week 16)
- **qutebrowser:** Gaze browsing, tab management & deep integration (Week 17)
- **hand-tracking:** Hand tracking, gesture recognition & virtual keyboard (Week 18)
- **bci:** OpenBCI full harness & BCI integration (Week 19)
- **release:** Integration tests, docs, benchmarks & v0.1.0 prep (Week 20)

### Miscellaneous

- This isn't that anymore
- This is the plan, but its not the end
- Merge dev (week 14) into main
- Restore PLAN.md from git history

### Refactoring

- Week 2 codebase reorganization

