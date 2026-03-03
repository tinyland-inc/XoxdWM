# R15.4: Rocky Linux EPEL Dependency Analysis

## Build Dependencies

| Dependency | Rocky 9 (Base) | Rocky 9 (EPEL) | Rocky 10 (Base) | Notes |
|-----------|----------------|-----------------|-----------------|-------|
| rust / cargo | No | EPEL (1.75+) | CRB (1.75+) | Or use rustup |
| emacs-pgtk | No | No | No | Build from source always |
| libwayland-devel | AppStream | - | AppStream | >=1.20 |
| mesa-libEGL-devel | AppStream | - | AppStream | |
| mesa-libgbm-devel | AppStream | - | AppStream | |
| libinput-devel | AppStream | - | AppStream | |
| libxkbcommon-devel | AppStream | - | AppStream | |
| systemd-devel | BaseOS | - | BaseOS | |
| libdrm-devel | AppStream | - | AppStream | |
| libseat-devel | No | EPEL | AppStream | Key difference |
| openxr-devel | No | No | No | Build Monado from source |
| clang / llvm | AppStream | - | AppStream | For bindgen |
| pkg-config | BaseOS | - | BaseOS | |
| wayland-protocols | AppStream | - | AppStream | |
| pixman-devel | AppStream | - | AppStream | |
| python3-devel | AppStream | - | AppStream | For BrainFlow |
| python3-pip | AppStream | - | AppStream | |
| numpy / scipy | No | EPEL | AppStream | BrainFlow deps |
| zeromq-devel | No | EPEL | EPEL | For Pupil Labs ZMQ |

## Runtime Dependencies

| Dependency | Rocky 9 | Rocky 10 | Notes |
|-----------|---------|----------|-------|
| mesa-dri-drivers | BaseOS | BaseOS | GPU drivers |
| libwayland-client | AppStream | AppStream | |
| libinput | AppStream | AppStream | |
| libxkbcommon | AppStream | AppStream | |
| dbus | BaseOS | BaseOS | For secrets |
| polkit | BaseOS | BaseOS | For seat access |
| python3 | BaseOS | BaseOS | For BrainFlow |

## EPEL Requirements Summary

### Rocky 9: EPEL Required
- `libseat-devel` (build)
- `rust` / `cargo` (build — or use rustup which needs no EPEL)
- `python3-numpy`, `python3-scipy` (runtime, BCI subpackage only)
- `zeromq-devel` (build, eye tracking only)

### Rocky 10: Minimal EPEL
- `zeromq-devel` (build, eye tracking only)
- Most other EPEL deps moved to base/AppStream/CRB

## EPEL-Free Installation Path

For environments where EPEL is not permitted:

1. **Rust**: Install via `rustup` (user-local, no EPEL needed)
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

2. **libseat**: Build from source (small C library, ~500 lines)
   ```bash
   git clone https://git.sr.ht/~kennylevinsen/seatd
   meson setup build && ninja -C build && ninja -C build install
   ```

3. **Emacs pgtk**: Always built from source (no distro package for pgtk)
   ```bash
   ./configure --with-pgtk --with-native-compilation
   ```

4. **OpenXR/Monado**: Always built from source
   ```bash
   cmake -B build -DXRT_BUILD_DRIVER_SIMULATED=ON
   ```

5. **BrainFlow**: Python pip install in virtualenv (no system packages)
   ```bash
   python3 -m venv /opt/exwm-vr/bci-venv
   /opt/exwm-vr/bci-venv/bin/pip install brainflow==5.12.1
   ```

6. **ZeroMQ**: Build from source if needed
   ```bash
   cmake -B build && cmake --build build && cmake --install build
   ```

## Recommendation

- **Rocky 10**: Enable CRB repo (standard, not EPEL). EPEL only needed for ZMQ.
- **Rocky 9**: Use EPEL for convenience, but provide EPEL-free build instructions.
- **RPM spec**: Use `BuildRequires` with `%{?epel}` conditionals to handle both paths.
- **Bundled deps**: Consider bundling seatd and Monado as subpackages to reduce
  external dependencies.
