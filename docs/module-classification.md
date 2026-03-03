# EXWM Module Classification: Keep / Transform / Drop

Based on EXWM codebase analysis (docs/exwm-analysis.org).

## Summary

| Module | Lines | Classification | Wayland Sibling | Rationale |
|--------|-------|---------------|-----------------|-----------|
| exwm-core.el | 463 | **Keep** | ewwm-core.el | Core data structures; `exwm--id-buffer-alist` pattern portable |
| exwm.el | 1304 | **Keep** | ewwm.el | Init orchestrator; entry point pattern reusable |
| exwm-workspace.el | 1764 | **Transform** | ewwm-workspace.el | Workspace logic portable (~40%), frame/X11 geometry not |
| exwm-input.el | 1216 | **Transform** | ewwm-input.el | Key dispatch portable (~35%), X11 GrabKey not |
| exwm-layout.el | 664 | **Transform** | ewwm-layout.el | Tiling algorithms portable (~45%), X11 ConfigureWindow not |
| exwm-manage.el | 834 | **Transform** | ewwm-manage.el | Lifecycle concepts portable (~30%), X11 MapRequest not |
| exwm-floating.el | 761 | **Transform** | ewwm-floating.el | Float toggle portable (~25%), X11 reparenting not |
| exwm-xim.el | 794 | **Drop** | — | X Input Method; Wayland uses `zwp_text_input_v3` |
| exwm-systemtray.el | 702 | **Drop** | — | X11 system tray; Wayland uses `wlr-foreign-toplevel` |
| exwm-randr.el | 340 | **Drop** | — | RandR is X11; Wayland uses `wl_output` + `xdg-output` |
| exwm-xsettings.el | 326 | **Drop** | — | XSETTINGS protocol is X11-only |
| exwm-background.el | 206 | **Drop** | — | Root window background; no root window in Wayland |

**Totals:** 2 Keep, 5 Transform, 5 Drop

---

## Keep Modules

### exwm-core.el (463 lines)
- **Rationale:** Defines `exwm--id-buffer-alist` (central mapping), `exwm-mode` major mode, buffer-local variables. These patterns are directly reusable.
- **Wayland adaptation:** `ewwm-core.el` mirrors with `ewwm--surface-buffer-alist` using Wayland surface IDs instead of X window IDs.
- **Key portable patterns:** Buffer-local variable definitions, mode-line format, alist CRUD operations.

### exwm.el (1304 lines)
- **Rationale:** Init/exit orchestration, module loading, hook management. The architecture of "load core, then modules, then init" is reusable.
- **Wayland adaptation:** `ewwm.el` will orchestrate IPC connection, compositor startup, and VR module loading.

---

## Transform Modules

### exwm-workspace.el (1764 lines) → ewwm-workspace.el
- **Portable (~40%):** Workspace list management, `exwm-workspace-switch` switching logic, workspace indexing, buffer-to-workspace assignment, `exwm-workspace-number` config.
- **X11-coupled (~60%):** Frame geometry via root window, `xcb:ConfigureWindow` for workspace frames, `xcb:MapWindow`/`xcb:UnmapWindow` for workspace visibility, strut handling via `_NET_WM_STRUT`.
- **`exwm--id-buffer-alist` refs:** 8 (highest of any module).

### exwm-input.el (1216 lines) → ewwm-input.el
- **Portable (~35%):** Key binding dispatch (`exwm-input-set-key`), simulation key mapping, prefix key list, line-mode/char-mode concept.
- **X11-coupled (~65%):** `xcb:GrabKey`/`xcb:UngrabKey` for global keys, `xcb:AllowEvents` for key passthrough, X11 key event translation via keysym, focus management via `xcb:SetInputFocus`.
- **`exwm--id-buffer-alist` refs:** 4.

### exwm-layout.el (664 lines) → ewwm-layout.el
- **Portable (~45%):** Tiling algorithm (window geometry calculation), fullscreen toggle logic, layout mode switching, zoom concept.
- **X11-coupled (~55%):** `xcb:ConfigureWindow` for geometry application, `xcb:MapWindow`/`xcb:UnmapWindow` for visibility, border width via X11.
- **`exwm--id-buffer-alist` refs:** 3.

### exwm-manage.el (834 lines) → ewwm-manage.el
- **Portable (~30%):** Buffer creation on window manage, buffer cleanup on unmanage, class/title/instance tracking, manage rules framework.
- **X11-coupled (~70%):** `xcb:MapRequest` event handling, `xcb:PropertyNotify` for title/class changes, ICCCM WM_STATE management, EWMH property reading/writing.
- **`exwm--id-buffer-alist` refs:** 8 (tied with workspace).

### exwm-floating.el (761 lines) → ewwm-floating.el
- **Portable (~25%):** Floating window toggle concept, position/size tracking, floating frame concept.
- **X11-coupled (~75%):** Reparenting via `xcb:ReparentWindow`, X11 container window creation, mouse-based move/resize via X11 pointer grab, border drawing.
- **`exwm--id-buffer-alist` refs:** 2.

---

## Drop Modules

### exwm-xim.el (794 lines)
- **Why drop:** X Input Method protocol is entirely X11. Wayland uses `zwp_text_input_v3` protocol, handled natively by the compositor and client toolkits (GTK4, Qt6).
- **VR consideration:** VR text input uses a custom virtual keyboard rendered in the VR scene.

### exwm-systemtray.el (702 lines)
- **Why drop:** X11 system tray (freedesktop.org spec) has no direct Wayland equivalent. Status notifications in Wayland use `ext-transient-seat` or compositor-specific approaches.
- **VR consideration:** System tray items could appear as VR overlay panels (future extension).

### exwm-randr.el (340 lines)
- **Why drop:** RandR is X11 multi-monitor. Wayland handles output management via `wl_output` and `xdg-output-manager` protocols, managed by the compositor.
- **Note:** Output management logic still needed, but implemented in Rust compositor, not Elisp.

### exwm-xsettings.el (326 lines)
- **Why drop:** XSETTINGS is an X11 protocol for theme/DPI propagation. Wayland clients get DPI from `wl_output.scale` and themes from toolkit settings.

### exwm-background.el (206 lines)
- **Why drop:** Sets the X11 root window background. Wayland has no root window concept. VR background is a 3D environment rendered by the compositor.
