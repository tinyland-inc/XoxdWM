# R20.3: Post-v0.1.0 Development Roadmap

## Overview

This document outlines the development roadmap for EWWM after the v0.1.0
release. Each milestone adds a major capability while maintaining backward
compatibility with v0.1.0 configurations and extensions. The roadmap
prioritizes features based on user impact, technical feasibility, and
alignment with the project's vision of a multi-modal, privacy-first VR
window manager.

Total timeline: 12 months from v0.1.0 to v1.0.0 production release.

---

## Timeline Diagram

```
Month:  1    2    3    4    5    6    7    8    9    10   11   12
        |    |    |    |    |    |    |    |    |    |    |    |
v0.1.0 -+
        |--- v0.1.x bugfixes ----------------------------------|
        |         |                                             |
        |         +--- v0.2.0 Voice + EMG ---+                  |
        |                                    |                  |
        |              +--- v0.3.0 Foveated -+--+               |
        |                                       |               |
        |                    +--- v0.4.0 Multi-User ---+        |
        |                                              |        |
        |                         +--- v0.5.0 AI ------+--+     |
        |                                                 |     |
        |                              +--- v1.0.0 Prod --+-----+
```

---

## v0.1.x -- Bugfix Series (Months 1-12, continuous)

Parallel to all milestone development. Backports critical fixes only.

**Scope**:
- Crash fixes in compositor and IPC
- Eye tracking calibration regressions
- Packaging fixes (NixOS module, RPM spec)
- Security patches for biometric data handling
- Performance regressions

**Release cadence**: As needed, targeting no more than 2 weeks from
bug report to fix release.

**Branch model**: `release/v0.1.x` branch from v0.1.0 tag. Cherry-pick
fixes from `dev`. No new features.

---

## v0.2.0 -- Voice Control & EMG (Months 3-4)

### Motivation

Keyboard text entry in VR is awkward. Virtual keyboards are slow.
Voice provides a natural hands-free text input channel, and EMG
wristbands enable silent gesture input without visible hand movement.
Together they fill the last major input gap in EWWM.

### Voice Recognition: Vosk Integration

**Vosk** (https://alphacephei.com/vosk/) is an offline speech recognition
toolkit supporting 20+ languages. Key properties for EWWM:
- Runs entirely offline (no cloud API, no audio leaves the machine)
- Small model sizes (50MB English, usable on resource-constrained systems)
- C API with Rust bindings (vosk-rs crate)
- Real-time streaming recognition (partial results as user speaks)
- Custom grammar support (restrict vocabulary for command recognition)

**Architecture**:
```
Microphone (PipeWire / PulseAudio)
    |
    v
vosk_recognizer (Rust, in compositor process)
    |
    v (partial result / final result)
VoiceCommandParser
    |
    v (structured command)
IPC -> Emacs -> execute
```

**Voice command grammar**:

Define a restricted grammar for window management commands. Vosk supports
JSGF (Java Speech Grammar Format) for constrained recognition, which
dramatically improves accuracy by limiting the vocabulary.

```
#JSGF V1.0;
grammar ewwm;

public <command> = <action> [<target>] [<modifier>];
<action> = switch | focus | move | close | open | tile | float
         | workspace | maximize | minimize | split;
<target> = window | buffer | terminal | browser | editor
         | workspace <number>;
<modifier> = left | right | up | down | next | previous;
<number> = one | two | three | four | five | six | seven | eight;
```

Examples:
- "switch workspace three" -> `(ewwm-workspace-switch 3)`
- "focus browser" -> `(ewwm-manage-focus-class "qutebrowser")`
- "tile left" -> `(ewwm-layout-set 'split-left)`
- "close window" -> `(ewwm-manage-close-surface (ewwm--current-surface))`
- "open terminal" -> `(ansi-term "/bin/bash")`

**Voice + Gaze: "look and say" interaction**:

Combine gaze targeting with voice confirmation. The user looks at a
window and says "focus" to switch to it. This eliminates dwell timing
ambiguity and is more natural than wink for users uncomfortable with
deliberate eye closure.

Priority: voice commands for actions, keyboard for text entry. Full
voice dictation (arbitrary text) is a stretch goal due to accuracy
limitations in noisy environments.

**Elisp integration**:
```elisp
(defcustom ewwm-voice-command-alist
  '(("switch workspace *" . ewwm-voice--switch-workspace)
    ("focus *" . ewwm-voice--focus-target)
    ("close window" . ewwm-voice--close-current))
  "Alist mapping voice command patterns to handler functions.")

(defun ewwm-voice-mode ()
  "Toggle voice command recognition.")
```

### EMG Wristband Integration

**Concept**: EMG (electromyography) wristbands detect electrical signals
from forearm muscles. Subtle finger movements and hand gestures can be
classified without visible motion. This enables input while hands rest
on a desk or lap -- no VR controller, no visible gesture.

**Target hardware**: Thalmic Myo (discontinued but available used),
or open-source sEMG boards (Myoware 2.0 sensor + Arduino). Long-term:
Meta's neural interface wristband (if publicly available).

**Gesture vocabulary**:
- Fist clench: confirm / enter
- Finger spread: cancel / escape
- Wrist flex (up): scroll up
- Wrist flex (down): scroll down
- Index tap (on surface): primary click
- Double tap: secondary click

**Architecture**: EMG board -> serial/BLE -> Rust EMG decoder in
compositor -> IPC events to Emacs. Signal processing: bandpass filter
(20-500 Hz), rectification, envelope detection, threshold classifier.

**Privacy**: All EMG processing local. Raw EMG data is ephemeral
(ring buffer, not logged). No muscle activation patterns stored.

### v0.2.0 Deliverables

| Deliverable                       | Priority | Effort |
|-----------------------------------|----------|--------|
| Vosk integration (Rust)           | P0       | 3 weeks|
| Voice command grammar             | P0       | 1 week |
| ewwm-voice.el                     | P0       | 1 week |
| Voice + gaze "look and say"       | P1       | 1 week |
| EMG board support (Myoware)       | P1       | 2 weeks|
| EMG gesture classifier            | P1       | 1 week |
| ewwm-emg.el                       | P2       | 1 week |
| Voice dictation (free text)       | P2       | 2 weeks|

---

## v0.3.0 -- Foveated Rendering & Performance (Months 5-6)

### Motivation

VR rendering is GPU-intensive: two full-resolution eye views at 90Hz.
Eye tracking enables foveated rendering -- high detail only where the
user is looking, reduced detail in the periphery. This can reduce GPU
load by 30-50%, enabling EWWM on mid-range hardware and improving
battery life on wireless setups.

### Eye-Tracking-Driven Foveated Rendering

**Fixed foveated rendering** (FFR) is already standard on Quest hardware
but uses fixed peripheral regions. **Dynamic foveated rendering** adjusts
the high-detail region based on real-time gaze position, achieving
better quality-to-performance ratios.

**Implementation approach**:

1. **Variable rate shading (VRS)**: If GPU supports VK_KHR_fragment_
   shading_rate, use gaze position to set per-tile shading rates.
   Foveal region (central 10 degrees): 1x1 shading. Parafoveal
   (10-30 degrees): 2x2 shading. Peripheral (>30 degrees): 4x4
   shading. GPU load reduction: ~40%.

2. **Radial density masking**: For GPUs without VRS, render to a lower-
   resolution framebuffer for peripheral regions and composite.
   Two render passes: full-resolution foveal circle + quarter-resolution
   peripheral. Blend at boundary. GPU load reduction: ~30%.

3. **Peripheral window simplification**: Windows outside the foveal
   region are rendered with reduced quality: no subpixel text rendering,
   solid color backgrounds instead of gradients, simplified borders.
   This is a compositor-level optimization, not a GPU feature.

### Dynamic Resolution Scaling

Adapt render resolution based on frame timing headroom. If frame time
exceeds budget (>11ms for 90Hz), reduce resolution by 10% increments.
If frame time has headroom (<8ms), increase resolution. Hysteresis
prevents oscillation. Target: maintain 90fps on GTX 1070-class hardware.

```
Frame budget: 11.1ms (90Hz)
  |
  If frame_time > 10.5ms: scale -= 0.05 (minimum 0.7)
  If frame_time < 8.0ms:  scale += 0.05 (maximum 1.0)
  |
  Apply to render target resolution
```

### Predictive Gaze Model

Use gaze velocity and saccade detection to predict where the user will
look 1-2 frames in the future. Pre-render the predicted foveal region
at full resolution. This reduces the perceptible quality transition
when the user's gaze moves to a new location.

Model: linear extrapolation from gaze velocity for smooth pursuit
(reading), saccade target prediction from gaze zone context for
saccades (known link positions in Qutebrowser provide targets).

### Performance Target

120fps on a mid-range GPU (RTX 3060 or equivalent) with 10 windows
visible, gaze-driven foveated rendering active, dynamic resolution
scaling as fallback.

### v0.3.0 Deliverables

| Deliverable                       | Priority | Effort |
|-----------------------------------|----------|--------|
| Variable rate shading (VRS path)  | P0       | 3 weeks|
| Radial density masking (fallback) | P0       | 2 weeks|
| Peripheral window simplification  | P1       | 1 week |
| Dynamic resolution scaling        | P1       | 1 week |
| Predictive gaze model             | P2       | 2 weeks|
| Benchmark: 120fps validation      | P0       | 1 week |

---

## v0.4.0 -- Multi-User VR (Months 7-8)

### Motivation

Remote collaboration in VR is more immersive than screen sharing. Seeing
a collaborator's hands pointing at code, their gaze indicating what
they're reading, and hearing their voice creates presence that video
calls cannot match. EWWM's existing multi-modal input tracking
(gaze, hands, voice) provides the data needed for avatar representation.

### Shared VR Workspace

Two or more EWWM users connect to a shared session. Each user runs
their own compositor locally. A session server synchronizes:
- Window placement (shared scene graph state)
- Cursor/hand positions (avatar representation)
- Gaze direction (optional, privacy-sensitive)
- Voice audio (WebRTC or Opus over UDP)

**Architecture**:
```
User A (EWWM compositor)        User B (EWWM compositor)
    |                               |
    +-- Session Client              +-- Session Client
    |       |                       |       |
    +-------+--- Session Server ---+--------+
                  (Rust, minimal)
                  |
                  State sync (scene graph deltas)
                  Audio relay (Opus/WebRTC)
```

The session server is intentionally minimal: it relays state and audio
but does not render, process biometrics, or store data. Screen contents
are NOT transmitted through the server (each user sees their own
windows). Shared visibility is opt-in per window.

### Screen Sharing via VR Window Placement

A user can "share" a window by publishing its texture to the session.
The shared window appears in other users' 3D space at a designated
"shared" position. Implementation: DMA-BUF export -> compress (H.264)
-> stream to session server -> decode on receivers -> render as texture.

**Bandwidth**: 1080p window at 30fps = ~3-5 Mbps per shared window.
Acceptable for LAN; marginal for WAN.

### Access Control

- Session creation requires explicit invitation (no public sessions)
- Per-window sharing permissions (owner must opt-in)
- Gaze sharing is off by default (privacy: others cannot see what you
  are reading)
- Voice is push-to-talk by default
- No persistent session recording

### v0.4.0 Deliverables

| Deliverable                       | Priority | Effort |
|-----------------------------------|----------|--------|
| Session protocol (Rust)           | P0       | 3 weeks|
| Session server                    | P0       | 2 weeks|
| Avatar representation (hands)     | P1       | 2 weeks|
| Window sharing (texture stream)   | P1       | 2 weeks|
| Voice chat (Opus)                 | P1       | 1 week |
| Access control model              | P0       | 1 week |
| ewwm-collab.el                    | P1       | 1 week |

---

## v0.5.0 -- AI Assistant Integration (Months 9-10)

### Motivation

Multi-modal input generates rich context about user intent: what they
are looking at (gaze), what they are thinking about (BCI attention),
what they are reaching for (hand tracking), and what they said (voice).
An AI assistant with access to this context can disambiguate vague
commands and proactively assist.

### LLM-Powered Command Disambiguation

Natural language commands are often ambiguous: "move this over there"
requires knowing what "this" is (gaze target) and where "there" is
(hand pointing direction or gaze shift target). An LLM resolves
ambiguity by combining:
- Voice transcript ("move this window over there")
- Current gaze target (window ID under gaze at utterance time)
- Hand pointing direction (ray from hand through 3D space)
- Workspace context (available targets in the scene)

**Architecture**: Voice transcript + context JSON -> local LLM ->
structured command -> execute.

```json
{
  "transcript": "move this over there",
  "gaze_target": {"surface_id": 42, "class": "qutebrowser"},
  "hand_ray_target": {"position": [1.2, 0.8, -2.0]},
  "visible_surfaces": [{"id": 42, ...}, {"id": 43, ...}],
  "current_workspace": 1
}
```

LLM output: `{"action": "move", "surface_id": 42, "position": [1.2, 0.8, -2.0]}`

### Local LLM (llama.cpp)

All inference runs locally via llama.cpp. No cloud API calls. Model:
a fine-tuned 7B parameter model (e.g., Mistral 7B or equivalent)
trained on window management command pairs. Model size: ~4GB GGUF
quantized (Q4_K_M). Inference latency: <500ms on GPU, <2s on CPU.

**Privacy guarantee**: user voice, gaze data, and screen context
never leave the machine. The LLM runs in the compositor process
(or a sidecar process) with no network access.

### BCI Intent Detection + AI Clarification

When BCI detects elevated attention directed at a specific window
(attention score > threshold + gaze on target), the AI assistant
can proactively offer actions:

"You seem focused on the terminal. Would you like to maximize it?"

This is opt-in and can be dismissed with a wink or voice "no."
The interaction model avoids being intrusive: suggestions appear
only when attention + gaze + dwell all converge on a single target
for >5 seconds.

### Adaptive UI

Track user behavior patterns over time (locally stored):
- Frequently used workspace layouts -> suggest auto-arrangement
- Common app launch sequences -> offer macros
- Fatigue patterns -> suggest break timing
- Error-prone interactions -> suggest alternative input modality

### v0.5.0 Deliverables

| Deliverable                       | Priority | Effort |
|-----------------------------------|----------|--------|
| llama.cpp integration (Rust FFI)  | P0       | 3 weeks|
| Context assembly (gaze+hand+voice)| P0       | 2 weeks|
| Command disambiguation prompt eng.| P0       | 1 week |
| ewwm-ai.el (Emacs interface)     | P1       | 1 week |
| BCI intent detection pipeline     | P2       | 1 week |
| Adaptive UI behavior tracking     | P2       | 2 weeks|
| Fine-tuning dataset + training    | P1       | 2 weeks|

---

## v1.0.0 -- Production Release (Month 12)

### Stability and Performance Guarantees

- Zero known crash bugs
- Frame timing p99 < 11ms on reference hardware (RTX 3060, Valve Index)
- IPC round-trip p99 < 1ms
- Memory: stable RSS over 8-hour sessions (no leaks)
- All biometric streams: graceful degradation on hardware disconnect
- Configuration migration from v0.1.0 -> v1.0.0 (automated)

### Multi-Platform Installer

- NixOS: `services.exwm-vr.enable = true;` (existing, polished)
- Rocky Linux 9/10: RPM repository with GPG-signed packages
- Arch Linux: AUR package (community-maintained)
- Debian/Ubuntu: .deb packages (stretch goal)
- Flatpak: compositor + Emacs bundle (stretch goal)

### Plugin Marketplace

Curated repository of community extensions:
- Custom layouts (radial, 3D scatter, focus-follows-reading)
- Input presets (one-hand mode, foot pedal, sip-and-puff)
- Theme packs (dark, light, high-contrast, color-blind)
- Application integrations (Firefox, Chromium, Zotero, Obsidian)

Marketplace is a Git repository of Elisp packages, installable via
`package.el` or `straight.el`. No centralized server required.

### Accessibility Certification

Pursue WCAG 2.1 AA compliance for the 2D flat desktop mode.
Document VR accessibility features against the XR Accessibility
User Requirements (W3C XAUR) draft. Produce an accessibility
conformance report (VPAT format) for enterprise adoption.

### Long-Term Support

- v1.0.x receives security and critical fixes for 24 months
- Smithay, OpenXR, and BrainFlow dependency updates backported
- NixOS module tracks stable NixOS releases (24.05, 24.11, 25.05)
- RPM spec tracks Rocky Linux 9 and 10

---

## Priority Matrix

Features ranked by user impact vs implementation effort:

```
High Impact |                        |
            | Voice Commands (v0.2)  | Multi-User VR (v0.4)
            | Foveated Render (v0.3) | AI Disambiguation (v0.5)
            |                        |
            |------------------------|------------------------
            |                        |
            | EMG Wristband (v0.2)   | Adaptive UI (v0.5)
            | Predictive Gaze (v0.3) | Plugin Marketplace (v1.0)
Low Impact  |                        |
            +------------------------+------------------------
              Low Effort               High Effort
```

**Quadrant priorities**:
- Top-left (high impact, low effort): voice commands, foveated rendering.
  Ship first, biggest user-visible improvement per engineering-week.
- Top-right (high impact, high effort): multi-user VR, AI disambiguation.
  High value but require significant infrastructure. Schedule for later
  milestones when foundation is stable.
- Bottom-left (low impact, low effort): EMG wristband, predictive gaze.
  Nice-to-have, include when engineering bandwidth allows.
- Bottom-right (low impact, high effort): adaptive UI, plugin marketplace.
  Defer or community-driven.

---

## Risk Assessment

| Risk                                    | Likelihood | Impact | Mitigation                            |
|-----------------------------------------|-----------|--------|---------------------------------------|
| Vosk accuracy insufficient for commands | Medium    | Medium | Constrained JSGF grammar, fallback to keyboard |
| EMG hardware fragmented / unavailable   | High      | Low    | EMG is P1/P2; voice is the primary v0.2 feature |
| Foveated rendering causes visual artifacts | Medium | Medium | Blend radius tuning, user-adjustable quality |
| Multi-user latency too high for collab  | Medium    | High   | LAN-first design, WAN as best-effort |
| LLM hallucination produces wrong actions| High      | Medium | Confirmation step before destructive actions |
| llama.cpp VRAM competes with VR rendering| Medium   | Medium | CPU inference path, model quantization |
| v1.0.0 scope creep delays release       | High      | High   | Strict feature freeze at month 10 |
| Community insufficient for marketplace  | Medium    | Low    | Marketplace is optional; core features standalone |

---

## Community Growth Strategy

### Month 1-3: Foundation
- Respond to all GitHub issues within 48 hours
- Monthly development blog post (progress, architecture decisions)
- Encourage first-time contributions via "good first issue" labels
- Document extension API thoroughly (v0.1.0 developer guide)

### Month 4-6: Outreach
- Submit talk proposal to EmacsConf (annual Emacs conference)
- Present at local Linux User Groups
- Write article for Linux Journal or lwn.net
- Cross-promote with Monado, BrainFlow, Pupil Labs communities

### Month 7-9: Ecosystem
- Host first community call (monthly, open agenda)
- Create Matrix/IRC channel for real-time support
- Identify and support 2-3 community extension developers
- Begin accessibility testing with disability advocacy organizations

### Month 10-12: Release
- Release candidate testing with 10+ external testers
- Professional documentation review (technical writer)
- Accessibility conformance testing
- Launch event (online, recorded)

---

## Non-Goals (Explicitly Deferred)

The following are intentionally excluded from the 12-month roadmap:

- **Mobile/Android port**: EWWM is a Linux compositor. Android would
  require a fundamentally different architecture.
- **Windows/macOS support**: Wayland is Linux-only. No plans for
  non-Linux platforms (Immersed fills this niche).
- **Game engine integration**: EWWM is a window manager, not a VR game
  platform. No Unity/Unreal/Godot integration.
- **Standalone headset mode**: EWWM requires a Linux PC. Quest standalone
  would require an Android port (see above).
- **Full desktop environment**: EWWM manages windows; it does not provide
  a file manager, settings app, notification center, or other DE
  components. Use existing Emacs packages or standalone tools.
- **Proprietary HMD SDKs**: EWWM uses OpenXR exclusively. No Oculus SDK,
  no SteamVR-specific features, no Apple Vision Pro support.
