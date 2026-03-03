# R20.1: Competitive Analysis -- VR Desktop Environments

## Overview

This document compares EXWM-VR (EWWM) against the four most relevant
competitors in the VR desktop compositor space. The goal is to identify
where EWWM occupies a unique niche, where competitors have advantages
we should learn from, and where our architecture decisions create
durable differentiation that justifies the 20-week investment.

The competitors analyzed:
1. **wxrd** -- Collabora's wlroots-based standalone VR compositor
2. **KWin VR MR** -- KDE's merge request adding VR support to KWin
3. **Simula** -- Haskell + Godot VR window manager
4. **immersed.io** -- proprietary commercial VR desktop app

---

## 1. wxrd (Collabora / xrdesktop)

**Repository**: https://gitlab.freedesktop.org/xrdesktop/wxrd
**License**: MIT
**Language**: C (wlroots + gulkan + gxr + xrdesktop)
**Status**: Experimental, intermittent development

### Architecture

wxrd is a standalone Wayland compositor built on wlroots. Its stack:
```
OpenXR Runtime (Monado / SteamVR)
    |
    v
  gxr          (XR runtime abstraction, GLib-based)
    |
  xrdesktop    (3D window management library)
    |
  gulkan       (Vulkan abstraction, DMA-BUF import)
    |
  wxrd         (wlroots compositor, Wayland clients)
```

wxrd takes Wayland client buffers, imports them as Vulkan textures via
DMA-BUF, and renders them onto flat planes in 3D space. The user can
grab windows with VR controllers and reposition them.

### Comparison with EWWM

**Compositor foundation: C/wlroots vs Rust/Smithay**

wxrd inherits wlroots' mature Wayland protocol support but also its C
memory safety risks. wlroots is battle-tested (used by Sway, Hyprland)
but wxrd layers four additional C libraries on top, creating a deep
dependency chain. EWWM uses Smithay (Rust), gaining memory safety and
type-checked Wayland protocol handling. Smithay is less mature than
wlroots but niri has proven it production-viable.

**Window management: basic placement vs scene graph**

wxrd provides basic grab-and-place 3D positioning through the xrdesktop
library. Windows are flat planes with no curvature, no layout algorithms,
no automatic tiling in 3D space. EWWM implements a full scene graph
(scene.rs) with curved surfaces, multiple layout strategies (cylinder,
sphere, flat grid), per-window PPU (pixels per unit) control, and
Elisp-driven layout policies. EWWM's layout system is programmable;
wxrd's is fixed.

**Input modalities: controllers only vs multi-modal**

wxrd supports VR controller input (grab, point, click) and basic
keyboard/mouse passthrough. No eye tracking, no hand tracking integration,
no BCI. EWWM supports keyboard, gaze (Pupil Labs + OpenXR eye gaze
extension), wink, hand tracking (OpenXR hand tracking extension), pinch
gestures, and BCI (OpenBCI via BrainFlow). This is the widest input
modality range of any VR desktop environment.

**Extensibility: none vs Emacs Lisp**

wxrd has no extension system. Configuration is compile-time. EWWM
inherits Emacs's infinite extensibility: users can write Elisp to
define custom layouts, input behaviors, window rules, keybindings,
and automation. The IPC protocol exposes the full compositor state to
Emacs, making EWWM the only VR compositor where the user can redefine
window management behavior at runtime without recompilation.

**Monado integration**

Both wxrd and EWWM use OpenXR to communicate with Monado. wxrd goes
through gxr (a GLib OpenXR abstraction), while EWWM uses openxrs
(Rust OpenXR bindings) directly. wxrd's gxr layer also supports
OpenVR/SteamVR as a fallback. EWWM targets OpenXR exclusively,
relying on Monado or SteamVR's OpenXR layer.

---

## 2. KWin VR MR (KDE)

**Reference**: KDE MR for VR output support in KWin
**License**: GPL-2.0+
**Language**: C++ (Qt/KDE Frameworks)
**Status**: Merge request, not yet merged to main

### Architecture

The KWin VR approach mirrors an existing KWin output to a VR headset.
Rather than creating a new compositor, it adds a new output backend
to KWin that submits frames to an OpenXR session. The existing 2D
desktop is projected into VR as a flat plane (or curved surface).

```
KWin (existing compositor)
  |
  +-- DRM Backend (monitor)
  +-- VR Backend (new) --> OpenXR --> Monado/SteamVR --> HMD
```

### Comparison with EWWM

**Architectural philosophy: mirror vs native**

KWin VR mirrors a 2D desktop into VR. EWWM creates a VR-native
environment where windows exist in 3D space from the start. The mirror
approach means KWin VR inherits all KWin features immediately (window
rules, compositing effects, Activities) but windows are not individually
positioned in 3D. EWWM's approach requires building VR features from
scratch but produces a true 3D workspace.

**DMA-BUF zero-copy texture import**

Both KWin VR and EWWM use DMA-BUF for zero-copy texture import from
client buffers to the VR renderer. KWin's existing DMA-BUF pipeline
is mature (used for regular compositing). EWWM implements the same
pattern in texture.rs using Smithay's DMA-BUF support. Performance
should be comparable; both avoid copying pixel data through CPU memory.

**Qt/C++ vs Elisp extensibility**

KWin is extensible via KWin scripts (JavaScript) and QML effects.
This is more limited than EWWM's Elisp extensibility: KWin scripts
can manipulate window properties and respond to events, but cannot
redefine the compositor's core behavior. EWWM exposes the entire
window management policy layer to Elisp, including layout algorithms,
focus policies, input dispatch, and workspace management.

**Integration depth**

KWin VR is a thin layer on top of a mature desktop environment. It
gets Activities, virtual desktops, window rules, KDE Connect, and the
entire Plasma ecosystem for free. EWWM has deep integration with Emacs
(the editor), Qutebrowser (the browser), and KeePassXC (credentials)
but lacks a broader desktop ecosystem. For Emacs users, EWWM's
integration is deeper; for general desktop users, KWin VR is broader.

**Biometric input**

KWin VR has no eye tracking, hand tracking, or BCI integration. The
KWin VR MR focuses purely on rendering output to VR, not input. EWWM
treats multi-modal biometric input as a first-class concern.

---

## 3. Simula (Haskell VR WM)

**Repository**: https://github.com/SimulaVR/Simula
**License**: AGPL-3.0
**Language**: Haskell + GDScript (Godot Engine 3.x)
**Status**: Development paused/slow (last significant activity 2023)

### Architecture

Simula embeds a Wayland compositor inside the Godot game engine. Godot
handles VR rendering, input, and scene management. The Haskell layer
implements Wayland protocol handling and window management logic. Wayland
client buffers are imported into Godot as textures and rendered on 3D
surfaces (Sprite3D nodes).

```
Godot Engine (GDNative)
  |
  +-- VR rendering (OpenXR via Godot)
  +-- Scene management (Godot scene tree)
  |
  Haskell (via GDNative FFI)
  |
  +-- Wayland compositor (wlroots bindings)
  +-- Window management logic
```

### Comparison with EWWM

**Engine dependency: Godot vs custom**

Simula depends on Godot 3.x, a full game engine (~50MB binary, large
dependency tree). This provides excellent VR rendering capabilities
but adds significant complexity and a large attack surface. EWWM uses
a minimal Smithay compositor with targeted OpenGL/Vulkan rendering,
resulting in a smaller, more auditable codebase.

**Language: Haskell vs Rust + Elisp**

Simula's use of Haskell for Wayland protocol handling is unusual. Haskell
provides strong type safety and correctness guarantees but has a high
barrier to contribution. The FFI boundary between Haskell and Godot/C
adds complexity. EWWM's Rust compositor has comparable type safety with
a larger contributor pool, and Elisp has a massive existing community.

**VR-native approach**

Both Simula and EWWM are VR-native: windows exist in 3D space from the
start. Simula's Godot integration provides better VR rendering quality
(physically-based rendering, post-processing effects) at the cost of
higher GPU utilization. EWWM prioritizes lightweight rendering with
the option of enhanced visuals.

**Performance characteristics**

Simula's Godot dependency means a minimum ~200MB RSS and significant GPU
utilization even at idle. EWWM targets <100MB idle RSS and <50% GPU
utilization on mid-range hardware. For a tool that runs continuously as
a window manager, EWWM's resource efficiency matters.

**Community and activity**

Simula's development has slowed significantly. The project has 3k GitHub
stars but few recent commits. The Haskell + Godot + Wayland combination
makes it difficult for new contributors to onboard. EWWM benefits from
Emacs's massive existing community and the growing Rust/Smithay ecosystem.

---

## 4. immersed.io (Proprietary)

**Website**: https://immersed.com
**License**: Proprietary (closed source)
**Platform**: Quest 2/3/Pro native, Windows/macOS/Linux streaming agent
**Status**: Active commercial product, funded startup

### Architecture

Immersed is a cloud-connected virtual monitor application. A desktop
agent captures the screen, compresses it (H.264/H.265), and streams
it to the Quest headset over Wi-Fi. On the Quest, the stream is decoded
and rendered as virtual monitors in 3D space. The user can configure
multiple virtual monitors of arbitrary size and position.

```
Desktop (Windows/macOS/Linux)
  |
  Screen capture agent (proprietary)
  |
  Compressed video stream (Wi-Fi / USB)
  |
  Quest headset (Android, proprietary app)
  |
  Virtual monitors (flat planes in 3D)
```

### Comparison with EWWM

**Multi-monitor emulation vs native compositor**

Immersed emulates traditional monitors: it captures a screen image and
projects it. This adds one full encode-decode cycle of latency (20-50ms)
on top of normal display latency. EWWM runs as the actual compositor,
receiving client buffers via DMA-BUF with zero-copy import. Latency is
fundamentally lower.

**Quest native vs Linux compositor**

Immersed runs on Quest hardware (Qualcomm SoC, Android). This provides
portability and wireless freedom. EWWM requires a Linux PC with a
tethered or WiVRn-connected headset. For users already at a Linux
workstation, EWWM eliminates the streaming bottleneck. For mobile
use, Immersed wins.

**Privacy model: cloud vs local**

Immersed requires an account, connects to cloud services for licensing,
and the streaming agent has access to the entire screen contents. EWWM
processes everything locally: gaze data, EEG data, screen contents,
credentials. No network connection required. No account. No telemetry.
For security-sensitive work (credentials, proprietary code), EWWM's
privacy model is categorically superior.

**Commercial vs open-source**

Immersed is a subscription product (~$10/month for multi-monitor).
EWWM is GPL-3.0+, free forever. Immersed has a full-time team, polished
UX, and customer support. EWWM has a small community and rough edges.
The tradeoff is typical: polish vs freedom.

**Input modalities**

Immersed supports hand tracking (Quest native) and passthrough keyboard.
No eye tracking integration, no BCI. EWWM supports the widest range
of input modalities. Immersed's hand tracking is limited to window
manipulation (grab, resize); it cannot drive text input or replace
a keyboard.

---

## Comparison Matrix

| Criterion                    | EWWM        | wxrd        | KWin VR     | Simula      | Immersed    |
|------------------------------|-------------|-------------|-------------|-------------|-------------|
| **License**                  | GPL-3.0+    | MIT         | GPL-2.0+    | AGPL-3.0    | Proprietary |
| **Language**                 | Rust+Elisp  | C           | C++/Qt      | Haskell+GD  | Proprietary |
| **Compositor base**         | Smithay     | wlroots     | KWin        | wlroots+Godot| Android    |
| **VR approach**             | Native 3D   | Native 3D   | Mirror 2D   | Native 3D   | Stream 2D   |
| **Scene graph**             | Full        | None        | N/A         | Godot tree  | None        |
| **Eye tracking**            | Yes (5 modes)| No         | No          | No          | No          |
| **Hand tracking**           | Yes (OpenXR) | No         | No          | No          | Yes (Quest) |
| **BCI integration**         | Yes (EEG)   | No          | No          | No          | No          |
| **Extensibility**           | Elisp       | None        | JS/QML      | Haskell     | None        |
| **DMA-BUF zero-copy**       | Yes         | Yes         | Yes         | Yes         | N/A         |
| **Credential management**   | KeePassXC   | None        | KDE Wallet  | None        | None        |
| **Browser integration**     | Qutebrowser | None        | KDE/Firefox | None        | Any         |
| **Foveated rendering**      | Planned     | No          | No          | No          | Quest HW    |
| **Privacy model**           | Local only  | Local only  | Local only  | Local only  | Cloud req.  |
| **NixOS packaging**         | Full module | None        | Nixpkgs     | Nix flake   | None        |
| **RPM packaging**           | 7 subpkgs   | None        | Fedora/COPR | None        | None        |
| **Headless mode**           | Yes (s390x) | No          | No          | No          | No          |
| **Target idle RSS**         | <100MB      | ~150MB      | ~300MB      | ~200MB      | ~100MB HMD  |
| **Community size**          | Small       | Tiny        | Large (KDE) | Small       | Medium      |
| **Development activity**    | Active      | Sporadic    | Active MR   | Paused      | Active      |
| **Multi-user support**      | Planned     | No          | No          | No          | Yes         |
| **Accessibility features**  | Extensive   | None        | KDE a11y    | None        | Basic       |

---

## Unique EWWM Differentiators

### 1. Emacs as WM Brain

No other VR desktop environment uses a programmable editor as its window
management engine. This means every aspect of window behavior -- layout
algorithms, focus policies, keybindings, automation -- is user-modifiable
at runtime via Elisp. A user can write `(defun my-vr-layout ...)` and
immediately change how windows are arranged in 3D space. This level of
customization is impossible in any competitor.

### 2. Multi-Modal Biometric Input (Gaze + Wink + Hand + BCI)

EWWM is the only VR desktop supporting four simultaneous biometric input
channels: eye tracking (gaze position, dwell, saccade filtering), wink
detection (blink classifier), hand tracking (pinch, grab, point), and
BCI (attention, SSVEP, P300, motor imagery). These modalities fuse to
provide input options for users with varying physical capabilities.

### 3. BCI Integration (First WM with EEG)

No window manager -- VR or otherwise -- has integrated EEG-based brain-
computer interface input. EWWM's BrainFlow integration allows attention-
modulated focus, SSVEP frequency-tagged workspace switching, P300 speller
input, and motor imagery cursor control. This is genuinely novel.

### 4. Privacy-First Architecture

All biometric data processing occurs locally. Gaze coordinates, EEG
signals, hand skeleton data, and wink events never leave the local
machine. There are no cloud services, no accounts, no telemetry. In
secure input mode, all biometric streams are paused to prevent side-
channel leakage during credential entry. Combined with KeePassXC's
NaCl encryption, this is the most privacy-conscious VR desktop.

### 5. KeePassXC Deep Integration

EWWM is the only VR desktop with native credential management:
KeePassXC browser protocol (NaCl X25519-XSalsa20-Poly1305), auto-type
via compositor wl_keyboard injection or ydotool, TOTP integration with
mode-line countdown, gaze-away safety detection, and secure input mode
that pauses all biometric monitoring during credential entry.

### 6. NixOS Reproducible Deployment

Full NixOS module (`services.exwm-vr`), home-manager integration with
Nix-to-Elisp config generation, OCI container images, and Cachix binary
cache. No other VR desktop offers this level of reproducible deployment.

### 7. Accessibility-First Design

Progressive enhancement: keyboard-only baseline works fully, each
biometric modality adds capability without requiring previous ones.
Fatigue monitoring automatically suggests breaks. Gaze zone layouts
adapt to user capabilities. This design philosophy ensures EWWM is
usable by people with varying physical abilities, not just the
able-bodied VR enthusiast demographic.

### 8. Headless Mode (s390x / Mainframe)

EWWM can run in headless mode on s390x mainframes, providing logical
workspace management via terminal Emacs. No other VR desktop even
considers non-graphical platforms. This enables EWWM's workspace and
window management concepts to be used on servers and headless systems.

---

## Competitive Positioning Summary

EWWM occupies a unique position at the intersection of:
- **Power users** (Emacs users who want maximum customization)
- **Accessibility** (users who need alternative input modalities)
- **Privacy** (users who refuse cloud-connected biometric processing)
- **Research** (BCI/eye tracking researchers who want an extensible platform)

The closest competitor in spirit is Simula (VR-native, open-source,
alternative language choice), but Simula's paused development and Godot
dependency limit its viability. wxrd is the closest in architecture
(standalone Wayland compositor for VR) but lacks extensibility and
biometric input. KWin VR would be the most practical for general users
but its mirror approach is fundamentally limited. Immersed is the most
polished but its proprietary, cloud-connected nature disqualifies it
for privacy-sensitive use.

EWWM's risk is scope: supporting five input modalities, three packaging
systems, and four architectures is ambitious for a small project. The
mitigation is progressive enhancement: each modality is optional, and
the keyboard-only flat desktop mode works as a conventional tiling WM.
