# EWWM Application Compatibility Matrix

## Test Environment
- Compositor: ewwm-compositor (Smithay 0.7)
- Platform: NixOS (to be tested on actual hardware)
- Protocols: xdg-shell, wlr-layer-shell, ext-foreign-toplevel-list, XWayland

## Compatibility Status

| Application | Protocol | Status | Notes |
|-------------|----------|--------|-------|
| **foot** | Wayland native | Pending | Primary terminal |
| **Alacritty** | Wayland native | Pending | Alternative terminal |
| **Qutebrowser** | Wayland (Qt6) | Pending | `QT_QPA_PLATFORM=wayland` |
| **Firefox** | Wayland native | Pending | `MOZ_ENABLE_WAYLAND=1` |
| **Emacs pgtk** | Wayland native | Pending | Nested client via `emacsclient -c` |
| **KeePassXC** | Wayland (Qt6) | Pending | Auto-type status TBD |
| **waybar** | wlr-layer-shell | Pending | Panel/taskbar |
| **mako** | wlr-layer-shell | Pending | Notification daemon |
| **rofi** | wlr-layer-shell | Pending | Application launcher |
| **xterm** | XWayland | Pending | Basic X11 test |
| **xclock** | XWayland | Pending | Basic X11 test |
| **GIMP** | XWayland | Pending | Multi-window X11 |
| **LibreOffice** | XWayland | Pending | Complex X11 |
| **mpv** | Wayland native | Pending | Video playback |

## Classification Legend
- **Works**: No issues detected
- **Works with caveats**: Minor issues documented, usable
- **Broken**: Critical issues, workaround needed
- **Pending**: Not yet tested

## Test Checklist Per Application

### Core Functionality
- [ ] Application launches and renders
- [ ] Keyboard input works
- [ ] Pointer input works (click, scroll)
- [ ] Window title updates correctly
- [ ] Window geometry/resize works
- [ ] Application closes cleanly

### Wayland-Specific
- [ ] Correct `app_id` reported
- [ ] Clipboard copy/paste works
- [ ] Primary selection (middle-click) works
- [ ] Fullscreen mode works
- [ ] Popups/menus render correctly

### XWayland-Specific
- [ ] WM_CLASS correctly detected
- [ ] Transient windows (dialogs) auto-float
- [ ] Override-redirect (menus/tooltips) render unmanaged
- [ ] Clipboard bridge (Wayland <-> X11) works

## Application-Specific Notes

### Qutebrowser
- FIFO IPC location: `$XDG_RUNTIME_DIR/qutebrowser/ipc-*`
- Recommended config: `c.window.title_format = "{current_title} - {current_url}"`
- Native Wayland preferred over XWayland for input latency

### KeePassXC
- Auto-type on Wayland: uses `wtype`, `ydotool`, or `xdotool` backend
- Compositor-level auto-type is planned
- D-Bus Secret Service: `(secrets-list-collections)` from Emacs
- Browser integration: `keepassxc-proxy` socket

### Emacs pgtk
- GDK4 Wayland backend
- `emacsclient -c` creates managed frame
- Kill ring shared via Wayland clipboard
- Multiple frames on different workspaces supported

### waybar
- Exclusive zone: top of screen (default ~30px)
- taskbar module: requires ext-foreign-toplevel-list
- Custom modules can query ewwm via IPC

## Environment Variables
```bash
# Force Wayland for Qt applications
export QT_QPA_PLATFORM=wayland

# Force Wayland for GTK applications (usually auto-detected)
export GDK_BACKEND=wayland

# Force Wayland for Firefox
export MOZ_ENABLE_WAYLAND=1

# XWayland display (set by compositor)
# export DISPLAY=:N
```
