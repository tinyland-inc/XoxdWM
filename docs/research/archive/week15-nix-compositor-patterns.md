# R15.3: Nix Flake Packaging Patterns for Wayland Compositors

## Survey of Existing Compositors

### niri (niri-flake)

**Repo**: github:YaLTeR/niri

Key patterns:
- Separate `packages.niri` and `packages.niri-unstable` outputs
- NixOS module at `nixosModules.niri`
- Uses `wrapInhibitEnv` to set `WLR_*` environment variables
- Session management: `.desktop` file in `share/wayland-sessions/`
- GPU driver integration: passes through `mesa.drivers` and `libvdpau`
- Overlay pattern: adds niri to `pkgs.niri` via nixpkgs overlay

Module options:
```nix
programs.niri = {
  enable = true;
  package = pkgs.niri;  # overridable
};
```

Session wrapper sets:
- `XDG_CURRENT_DESKTOP=niri`
- `XDG_SESSION_TYPE=wayland`
- `XDG_SESSION_DESKTOP=niri`
- `NIXOS_OZONE_WL=1` (for Chromium/Electron Wayland)
- `MOZ_ENABLE_WAYLAND=1` (for Firefox)

### Hyprland (hyprland-flake)

**Repo**: github:hyprwm/Hyprland

Key patterns:
- Heavy use of overlays for mesa/wayland patching
- `cachix` integration (`hyprland.cachix.org`)
- Separate `programs.hyprland` NixOS module and home-manager module
- GPU-specific options: `programs.hyprland.nvidiaPatches`
- XWayland toggle: `programs.hyprland.xwayland.enable`
- Portal integration: auto-configures `xdg-desktop-portal-hyprland`

Environment propagation:
```nix
environment.sessionVariables = mkIf cfg.enable {
  HYPRLAND_LOG_WLR = "1";
  NIXOS_OZONE_WL = "1";
};
```

### sway (NixOS upstream module)

**Repo**: nixpkgs `nixos/modules/programs/sway.nix`

Key patterns (most mature, in nixpkgs):
- `programs.sway.enable` with `security.polkit` integration
- `programs.sway.wrapperFeatures` for GPU and dbus wrapping
- `programs.sway.extraPackages` for commonly bundled tools
- Session management: `/share/wayland-sessions/sway.desktop`
- PAM integration: `security.pam.services.swaylock`
- Portal: auto-enables `xdg-desktop-portal-wlr`

Wrapper script pattern:
```nix
wrappedSway = pkgs.writeShellScript "sway" ''
  export XDG_SESSION_TYPE=wayland
  export XDG_CURRENT_DESKTOP=sway
  exec ${pkgs.dbus}/bin/dbus-run-session ${cfg.package}/bin/sway "$@"
'';
```

## Patterns to Adopt for EXWM-VR

### 1. Session Environment Variables (from all three)
```nix
environment.sessionVariables = {
  XDG_CURRENT_DESKTOP = "EXWM-VR";
  XDG_SESSION_TYPE = "wayland";
  NIXOS_OZONE_WL = "1";        # Chromium/Electron
  MOZ_ENABLE_WAYLAND = "1";     # Firefox
  QT_QPA_PLATFORM = "wayland";  # Qt apps
  SDL_VIDEODRIVER = "wayland";   # SDL games
  _JAVA_AWT_WM_NONREPARENTING = "1";  # Java apps
};
```

### 2. D-Bus Wrapper (from sway)
Wrap compositor launch in `dbus-run-session` to ensure session bus exists:
```bash
exec dbus-run-session ewwm-compositor "$@"
```

### 3. Cachix Pattern (from Hyprland)
- Create `exwm-vr.cachix.org` cache
- CI pushes: `cachix push exwm-vr $(nix build --print-out-paths)`
- Greedy: `cachix watch-exec exwm-vr -- nix build` pushes ALL deps

### 4. XDG Portal Integration
- Auto-enable `xdg-desktop-portal-wlr` (or similar) for:
  - Screen sharing (PipeWire)
  - File dialogs
  - Notifications

### 5. GPU Driver Propagation (from Hyprland)
- Pass through GPU-specific libraries
- Optional NVIDIA patches/environment variables
- Mesa driver path injection

### 6. Overlay for Integration
```nix
overlays.default = final: prev: {
  exwm-vr-compositor = final.callPackage ./nix/packages/compositor.nix { };
  exwm-vr-elisp = final.callPackage ./nix/packages/elisp.nix { };
};
```

## Anti-Patterns to Avoid

1. **Don't hard-code GPU driver paths** — use `hardware.opengl.package`
2. **Don't assume systemd** — support both systemd and direct-launch
3. **Don't bundle mesa** — use system mesa to match GPU drivers
4. **Don't skip dbus wrapping** — many apps need session bus
5. **Don't forget XWayland** — most legacy apps still need it
