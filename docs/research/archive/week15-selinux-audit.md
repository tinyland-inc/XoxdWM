# R15.1: SELinux Policy Audit Patterns

## Methodology

For auditing EXWM-VR under SELinux enforcing mode:

```bash
# 1. Set compositor to permissive for audit
semanage permissive -a exwm_vr_compositor_t

# 2. Run full session (compositor + Emacs + VR + BCI)
systemctl --user start exwm-vr.target

# 3. Exercise all code paths:
#    - Launch applications (XDG, XWayland)
#    - Switch workspaces
#    - Float/unfloat windows
#    - VR mode toggle (Monado)
#    - Eye tracking session
#    - BCI session with OpenBCI Cyton
#    - KeePassXC auto-type
#    - Clipboard operations

# 4. Collect denials
ausearch -m avc -ts recent | audit2allow -R > audit-report.txt

# 5. Analyze required permissions
sesearch -A -s exwm_vr_compositor_t | sort > compositor-perms.txt
```

## Expected Permission Categories

### Compositor (exwm_vr_compositor_t)

| Access | Target | Reason |
|--------|--------|--------|
| read/write | drm_device_t | GPU/DRM access for rendering |
| read/write | input_device_t | libinput for keyboard/mouse |
| read/write | user_tmp_t | Wayland socket in XDG_RUNTIME_DIR |
| read/write | gpu_device_t | GPU compute/render |
| read | fonts_t | Font rendering |
| read | locale_t | Locale data |
| create/bind | unix_stream_socket | IPC with Emacs |
| read | proc_t | /proc/self for memory mapping |
| read/write | shm_t | Shared memory for SHM buffers |

**Deny by default:**
- `tcp_socket`, `udp_socket` — no network access needed
- `file write` outside XDG_RUNTIME_DIR and /tmp
- `ptrace` — no debugging of other processes
- `module_load` — no kernel module loading

### Monado (exwm_vr_monado_t)

| Access | Target | Reason |
|--------|--------|--------|
| read/write | drm_device_t | DRM lease for HMD |
| read/write | usb_device_t | HMD USB interface |
| read/write | user_tmp_t | Monado IPC socket |
| read/write | gpu_device_t | VR rendering |
| read | sysfs_t | Device enumeration |
| read/write | v4l_device_t | Camera for tracking (if applicable) |

### BrainFlow (exwm_vr_brainflow_t)

| Access | Target | Reason |
|--------|--------|--------|
| read/write | tty_device_t | Serial USB for OpenBCI Cyton |
| read/write | user_tmp_t | Unix socket for IPC |
| read | proc_t | Python runtime needs |
| execute | bin_t | Python interpreter |

## Overly Broad Permissions to Watch For

1. **`allow ... file { read write }` on `unlabeled_t`** — indicates files without
   proper labeling. Fix with file contexts, not broad allows.
2. **`allow ... self capability { sys_admin }`** — DRM/GPU sometimes triggers this;
   prefer `cap_sys_admin` only for specific device ioctls.
3. **`allow ... tmp_t { create write }`** — should be scoped to `user_tmp_t`, not
   system-wide tmp.
4. **`allow ... network`** — compositor must NEVER have network access. If audit
   shows network denials, investigate root cause (DNS lookup during font load, etc.).

## Iterative Refinement

After initial deployment:

```bash
# Check for denials weekly
ausearch -m avc -ts this-week -c ewwm-compositor | audit2allow -w

# Verify no overly broad rules
sesearch -A -s exwm_vr_compositor_t -c tcp_socket  # should return empty
sesearch -A -s exwm_vr_compositor_t -c udp_socket  # should return empty
```
