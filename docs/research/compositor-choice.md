# Host Compositor Choice for VR Development

Architectural decision record for selecting a host Wayland compositor on the
honey server (Rocky Linux 10, headless VR workstation).

---

## 1. Problem Statement

The honey server runs Rocky Linux 10 with no desktop environment. It hosts:

- **AMD RX 9070 XT** (Navi 48 / GFX1201) driving a Dell S2721QS on DP-1
- **Bigscreen Beyond 2e** HMD on DP-2 (3840x1920, non-desktop connector)
- **Monado** as the OpenXR runtime (Lighthouse driver, `STEAMVR_LH_ENABLE=1`)
- **Steam / SteamVR** for game compatibility

We need a Wayland compositor that:

1. Manages the desktop monitor (DP-1) for day-to-day use (terminal, Emacs, browser)
2. Detects the Beyond as a non-desktop connector and does NOT render to it
3. Serves `wp_drm_lease_device_v1` so Monado can lease DP-2 exclusively
4. Provides XWayland for Steam, SteamVR, and legacy X11 applications
5. Is available or buildable on Rocky Linux 10 (RHEL 10 / EL10)
6. Can be replaced later by ewwm once our compositor reaches feature parity

The compositor is a **bridge** — it holds the DRM master fd and parcels out
display resources. Monado gets the HMD via lease; everything else stays on the
desktop output.

---

## 2. Options Evaluated

### Sway 1.11 (wlroots 0.19)

Tiling Wayland compositor. The reference implementation for wlroots-based DRM
leasing. Mature, widely deployed, extensive documentation.

### Weston

Reference Wayland compositor from freedesktop.org. Primarily a test bed and
embedded target. Has wp_drm_lease_v1 support via Marius Vlad's work (Collabora).

### labwc

Lightweight stacking compositor (wlroots-based). Openbox-style configuration.
Growing adoption as a minimal desktop compositor.

### GNOME / Mutter

Full desktop environment compositor. Heavy dependency chain (GDM, GNOME Shell,
systemd integration). DRM lease support is incomplete.

### cage

Single-application kiosk compositor (wlroots-based). Designed to run one
full-screen application. No multi-window support.

### ewwm (our own Smithay compositor)

The ewwm compositor under development in `compositor/`. Smithay 0.7 based,
has `drm_lease.rs` with full DRM lease protocol implementation. Not yet
capable of daily-driver desktop use — missing session lock, idle notify,
screencopy, and several other P0 protocols (see v0.5.0 roadmap).

---

## 3. Comparison Matrix

| Criterion | Sway 1.11 | Weston | labwc | Mutter | cage | ewwm |
|-----------|-----------|--------|-------|--------|------|------|
| DRM lease (wp_drm_lease_v1) | Yes (native) | Yes (recent) | Yes (wlroots) | Partial | Yes (wlroots) | Yes (Smithay) |
| Non-desktop auto-filter | Yes | Manual config | Yes (wlroots) | No | N/A | Yes (planned) |
| XWayland | Yes | Yes | Yes | Yes | No | Yes (Smithay) |
| Multi-output | Yes | Yes | Yes | Yes | No | Partial |
| Weight (deps) | Light | Medium | Light | Heavy | Minimal | Medium |
| Rocky 10 availability | Build from src | EPEL (old ver) | Build from src | dnf (heavy) | Build from src | In-tree |
| Session lock | Yes | Limited | Yes | Yes | No | Missing |
| Clipboard mgmt | Yes | Yes | Yes | Yes | No | Missing |
| Tiling / layout | Yes (i3-like) | No | No (stacking) | No (stacking) | N/A | Emacs-driven |
| Community / docs | Excellent | Good | Growing | Excellent | Minimal | Internal |
| Hotplug handling | Yes | Yes | Yes | Yes | No | Partial |
| IPC / scripting | swaymsg + i3 | weston.ini | labwc-actions | D-Bus | None | s-expr IPC |

### Scoring

- **Must-have**: DRM lease, non-desktop filter, XWayland, multi-output
- **Should-have**: Light weight, available on Rocky 10, good IPC
- **Nice-to-have**: Tiling, session lock, clipboard

Only **Sway**, **labwc**, and **ewwm** meet all must-haves. ewwm is not ready
for daily use. labwc lacks tiling and has less documentation. Sway meets every
criterion and is the most battle-tested option for VR compositor hosting.

---

## 4. Decision

**Use Sway 1.11 (wlroots 0.19) as the host compositor on honey.**

### Rationale

1. **DRM lease is proven.** Sway's non-desktop detection and lease offering is
   the reference implementation that Monado, SteamVR, and WiVRn all test against.
   The code path is well-documented in our own `drm-lease-survey.md`.

2. **Zero configuration for VR.** Sway automatically detects `non_desktop=1`
   connectors, skips desktop rendering on them, and offers them for leasing.
   No manual output configuration needed — plug in the Beyond, Sway offers it.

3. **XWayland for Steam.** Steam, SteamVR, and Proton applications require
   XWayland. Sway's XWayland support is mature and handles focus, clipboard,
   and input correctly.

4. **Buildable on Rocky 10.** wlroots 0.19 and Sway 1.11 build from source
   with meson/ninja. Dependencies are available in base repos + EPEL:
   `wayland-devel`, `wayland-protocols-devel`, `libinput-devel`, `pixman-devel`,
   `libdrm-devel`, `mesa-libEGL-devel`, `json-c-devel`, `pango-devel`, `cairo-devel`.

5. **Familiar IPC.** `swaymsg` and i3 IPC protocol allow scripting output
   management, workspace control, and window rules from shell or Emacs.

6. **Clean migration path to ewwm.** Sway occupies the exact architectural
   slot that ewwm will eventually fill. Replacing Sway with ewwm requires no
   changes to Monado, Steam, or application configuration — only the compositor
   binary changes.

### What Sway does NOT provide

- Emacs-driven layout (ewwm's core value proposition)
- VR scene graph, gaze focus, hand tracking integration
- BCI / biometric input routing
- S-expression IPC protocol

These are ewwm-specific features that live above the compositor layer.

---

## 5. Architecture Diagram

```
                        ┌─────────────────────────────────────┐
                        │          honey (Rocky 10)           │
                        │                                     │
                        │  ┌───────────────────────────────┐  │
                        │  │         Sway 1.11             │  │
                        │  │      (DRM master fd)          │  │
                        │  │                               │  │
                        │  │  DP-1 ─── Dell S2721QS        │  │
                        │  │  (desktop output, 3840x2160)  │  │
                        │  │                               │  │
                        │  │  DP-2 ─── Beyond 2e           │  │
                        │  │  (non_desktop=1, NOT rendered) │  │
                        │  │  offered via wlr-drm-lease-v1 │  │
                        │  └────────┬──────────┬───────────┘  │
                        │           │          │              │
                        │    ┌──────┘          └──────┐       │
                        │    │ Wayland                │ DRM   │
                        │    │ clients               │ lease  │
                        │    │                        │ fd     │
                        │    ▼                        ▼       │
                        │  ┌──────────┐   ┌────────────────┐  │
                        │  │  Emacs   │   │    Monado      │  │
                        │  │  (pgtk)  │   │  (OpenXR RT)   │  │
                        │  │          │   │                │  │
                        │  │ ewwm-*.el│   │ STEAMVR_LH=1   │  │
                        │  │          │   │ Beyond on DP-2 │  │
                        │  └──────────┘   └───────┬────────┘  │
                        │                         │           │
                        │  ┌──────────┐   ┌───────┴────────┐  │
                        │  │  Steam   │   │   OpenXR app   │  │
                        │  │(XWayland)│   │   (SteamVR,    │  │
                        │  │          │   │    games)       │  │
                        │  └──────────┘   └────────────────┘  │
                        │                                     │
                        │  ┌──────────────────────────────┐   │
                        │  │   AMD RX 9070 XT (Navi 48)   │   │
                        │  │   DP-1: desktop  DP-2: VR    │   │
                        │  └──────────────────────────────┘   │
                        └─────────────────────────────────────┘
```

### Data flow

1. **Sway** holds DRM master fd for the 9070 XT
2. **DP-1** is a normal desktop output — Sway renders Emacs, terminals, browsers
3. **DP-2** (Beyond) has `non_desktop=1` — Sway never renders to it, only
   advertises it via `wp_drm_lease_device_v1`
4. **Monado** binds `wp_drm_lease_device_v1`, sees DP-2, requests a lease
5. **Sway** grants the lease — Monado receives a DRM fd scoped to DP-2's
   connector + CRTC + primary plane
6. **Monado** drives the Beyond directly via Vulkan (`VK_EXT_acquire_drm_display`)
7. **Emacs** runs as a pgtk Wayland client under Sway, managing ewwm via IPC
8. **Steam** runs under XWayland within Sway

---

## 6. Migration Path

### Now: Sway as host

```
Sway (DRM master) → Monado (DRM lessee) → Beyond
                   → Emacs (Wayland client)
                   → Steam (XWayland client)
```

### v0.5.0: ewwm reaches daily-driver (target: ~6 weeks)

Complete the missing Wayland protocols:
- ext-session-lock-v1
- ext-idle-notify-v1, zwp-idle-inhibit-v1
- zwp-primary-selection-v1, wlr-data-control-v1
- linux-dmabuf-v1, wp-cursor-shape-v1
- xdg-activation-v1
- wlr-screencopy-v1 (portal integration)
- wlr-output-management-v1

### v0.6.0: ewwm replaces Sway

```
ewwm (DRM master) → Monado (DRM lessee) → Beyond
                   → Emacs (Wayland client, WM brain)
                   → Steam (XWayland client)
```

The swap is transparent to Monado and applications. The DRM lease protocol is
the same (`wp_drm_lease_device_v1`). ewwm's `drm_lease.rs` already implements
the full protocol — it just needs the surrounding desktop infrastructure.

### Migration checklist

- [ ] All P0 protocols from v0.5.0 roadmap implemented in ewwm
- [ ] ewwm headless CI passes on aarch64 and x86_64
- [ ] Manual testing: session lock, idle, clipboard, screencopy
- [ ] DRM lease verified with Monado on actual hardware
- [ ] XWayland verified with Steam
- [ ] Performance: frame timing within 5% of Sway
- [ ] Fallback: keep Sway session entry as backup

---

## 7. Key Environment Variables

### Monado / OpenXR

| Variable | Value | Purpose |
|----------|-------|---------|
| `STEAMVR_LH_ENABLE` | `1` | Enable SteamVR Lighthouse tracking driver |
| `XRT_COMPOSITOR_COMPUTE` | `1` | Use compute shader path (recommended for AMD) |
| `XRT_COMPOSITOR_DESIRED_MODE` | `1` | Target 90 Hz refresh rate |
| `LH_OVERRIDE_IPD_MM` | `64` | Override IPD (Beyond Utility broken under Proton) |
| `XRT_COMPOSITOR_FORCE_WAYLAND` | `1` | Force Wayland window fallback (testing only) |
| `XRT_COMPOSITOR_FORCE_NVIDIA_DISPLAY` | `"Display Name"` | NVIDIA direct mode (not applicable) |
| `XRT_COMPOSITOR_FORCE_VK_DISPLAY` | `N` | Force VK_KHR_display index N (VT direct) |

### Sway / Wayland

| Variable | Value | Purpose |
|----------|-------|---------|
| `WLR_BACKENDS` | `drm,libinput` | Force DRM + libinput (skip headless) |
| `WLR_DRM_DEVICES` | `/dev/dri/card1` | Target specific GPU |
| `WAYLAND_DISPLAY` | `wayland-1` | Socket name (default) |
| `XDG_CURRENT_DESKTOP` | `sway` | Desktop identification |
| `XDG_SESSION_TYPE` | `wayland` | Session type |
| `WLR_NO_HARDWARE_CURSORS` | `1` | Software cursor fallback if needed |

### Steam / SteamVR

| Variable | Value | Purpose |
|----------|-------|---------|
| `PROTON_ENABLE_HIDRAW` | `0x35BD/0x0101` | Grant Beyond HID access to Proton |
| `STEAM_RUNTIME` | `1` | Use Steam runtime libraries |

### Beyond HID

| Variable | Value | Purpose |
|----------|-------|---------|
| `EXWM_VR_BEYOND_BRIGHTNESS` | `50` | Default brightness % (0-100) |
| `EXWM_VR_BEYOND_FAN_SPEED` | `60` | Default fan speed % (40-100) |

---

## 8. Sway Configuration for VR

```
# ~/.config/sway/config
output DP-1 mode 3840x2160@60Hz position 0 0
# Beyond (DP-2): do NOT configure — Sway auto-detects non_desktop=1
xwayland enable
exec emacs --with-pgtk
```

No explicit config needed for the Beyond. Sway reads the `non_desktop` DRM
connector property and automatically excludes the connector from rendering,
creates a `wp_drm_lease_device_v1` global, and advertises it for leasing.

### Verification

```bash
swaymsg -t get_outputs         # DP-1 only; DP-2 absent = non-desktop working
wayland-info | grep drm_lease  # wp_drm_lease_device_v1 present
monado-cli test                # display on DP-2 via DRM lease
```

---

## References

- [DRM Lease Protocol (Wayland Explorer)](https://wayland.app/protocols/drm-lease-v1)
- [Drew DeVault: DRM leasing — VR for Wayland](https://drewdevault.com/2019/08/09/DRM-leasing-and-VR-for-Wayland.html)
- [Keith Packard: DRM-lease kernel API](https://keithp.com/blogs/DRM-lease/)
- [Sway PR #4289: DRM lease support](https://github.com/swaywm/sway/pull/4289)
- [Sway DRM lease commit](https://github.com/swaywm/sway/commit/a2dd9830733f81127e3ff716a72d26a223ea0207)
- [wlroots DRM lease implementation](https://github.com/swaywm/wlroots/blob/master/backend/drm/drm.c)
- [Monado direct mode documentation](https://monado.freedesktop.org/direct-mode.html)
- [Monado Wayland direct source](https://monado.pages.freedesktop.org/monado/comp__window__direct__wayland_8c.html)
- [Smithay DRM Lease module](https://smithay.github.io/smithay/smithay/wayland/drm_lease/index.html)
- [Linux kernel non-desktop EDID quirks](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/drm_edid.c)
- [LVRA Wiki: Bigscreen Beyond](https://lvra.gitlab.io/docs/other/bigscreen-beyond/)
- [nixpkgs-xr overlay](https://github.com/nix-community/nixpkgs-xr)
- [Collabora: Moving Linux to another reality](https://www.collabora.com/news-and-blog/news-and-events/moving-the-linux-desktop-to-another-reality.html)
- [ewwm DRM lease survey](./drm-lease-survey.md)
- [ewwm Beyond 2e bootstrap analysis](./beyond-2e-bootstrap-analysis.md)
