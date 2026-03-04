# Beyond 2e Bootstrap — Action Plan

## Executive Summary

The Bigscreen Beyond 2e display is **not activating** on honey because:
1. **Kernel 6.12 is too old** for RDNA 4 display output (need 6.13.5+)
2. **HID power-on packets** are never sent (display board stays off)
3. **Non-desktop EDID quirk** is missing (not merged upstream)

All three must be fixed. This is a multi-step procedure.

---

## Phase 1: System Prerequisites (honey server)

### 1.1 User Group Membership
```bash
sudo usermod -aG video,render,input,plugdev jess
# Logout/login required
```

### 1.2 udev Rules
```bash
sudo cp packaging/udev/99-exwm-vr.rules /etc/udev/rules.d/
# Add Beyond-specific rules for all PIDs (0101, 0202, 0105, 4004)
sudo udevadm control --reload-rules
sudo udevadm trigger
# Unplug and replug the Beyond
```

### 1.3 Firmware Update
```bash
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
sudo cp linux-firmware/amdgpu/* /lib/firmware/amdgpu/
sudo dracut --force  # Rebuild initramfs
```

---

## Phase 2: Kernel Upgrade

Rocky 10 ships kernel 6.12 and won't upgrade to 6.13+.
Build a custom kernel with:
- Mainline 6.14.x (current stable)
- Bigscreen Beyond EDID non_desktop quirk patch
- All RDNA 4 display fixes

### Option A: ELRepo (easiest)
```bash
sudo dnf install elrepo-release
sudo dnf --enablerepo=elrepo-kernel install kernel-ml
# Then apply the BSB EDID quirk via module parameter or DKMS
```

### Option B: Build from Source
```bash
# Get kernel source
git clone --depth 1 -b v6.14 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux

# Apply BSB patch (one-liner in drm_edid.c)
# EDID_QUIRK('B', 'I', 'G', 0x1234, EDID_QUIRK_NON_DESKTOP)

# Build with Rocky 10 config as base
cp /boot/config-$(uname -r) .config
make olddefconfig
make -j$(nproc) rpm-pkg
sudo rpm -ivh ~/rpmbuild/RPMS/x86_64/kernel-*.rpm
```

### Option C: Nix-managed Kernel (preferred for reproducibility)
```nix
# In flake.nix or separate nix expression
linuxPackages_6_14.kernel.override {
  extraPatches = [
    { name = "bigscreen-beyond-non-desktop";
      patch = ./patches/bigscreen-beyond-edid.patch; }
  ];
};
```

### Reboot to new kernel, verify:
```bash
uname -r  # Should be 6.14.x
dmesg | grep -i "smu driver"  # Should NOT show version mismatch
```

---

## Phase 3: Display Verification

After kernel upgrade + firmware update + reboot:

```bash
# Check DRM connectors
for conn in /sys/class/drm/card*-*/; do
  name=$(basename "$conn")
  status=$(cat "$conn/status" 2>/dev/null)
  nd=$(cat "$conn/non_desktop" 2>/dev/null)
  echo "$name: status=$status non_desktop=$nd"
done

# Should see one connector with:
#   status=connected  non_desktop=1

# Read EDID
cat /sys/class/drm/card1-DP-1/edid | edid-decode 2>&1

# Check display modes
cat /sys/class/drm/card1-DP-1/modes
# Expected: 3840x1920 at 75/90 Hz
```

If DP still shows disconnected:
1. Try the other DP port on the GPU
2. Check `dmesg | grep -i dp` for link training errors
3. Verify firmware loaded: `dmesg | grep -i firmware`

---

## Phase 4: Bootstrap Calibration

### 4A: Proton Bootstrap (Proven Path)

1. **Install Steam:**
   ```bash
   # Via Flatpak (recommended on Rocky)
   flatpak install com.valvesoftware.Steam
   ```

2. **Install Beyond Driver (Steam App 2467050):**
   ```
   steam://install/2467050
   ```
   Or search "Bigscreen Beyond Driver" in Steam store.

3. **Configure Proton:**
   - Right-click Beyond Driver → Properties
   - Force Proton Experimental
   - Set launch options:
     ```
     PROTON_ENABLE_HIDRAW=0x35BD/0x0101 %command%
     ```

4. **Run Beyond Driver → Initial Calibration:**
   - IPD measurement
   - Face scan / lens configuration
   - Firmware update (if needed)
   - Display should activate at this point

5. **Install SteamVR, launch:**
   - Copy lighthouse DB to `~/.local/share/Steam/config/bigscreenbeyond/`
   - SteamVR should see the Beyond with tracking

### 4B: Native HID Bootstrap (Development Target)

Write a tool that sends the display power-on sequence:
```rust
// beyond_init.rs
use hidapi::HidApi;

const VENDOR_ID: u16 = 0x35BD;
const PRODUCT_ID: u16 = 0x0101;

fn power_on_display(device: &hidapi::HidDevice) {
    // Display board power-on sequence (from Wireshark capture)
    // These are Get Feature Report requests with report ID 0x81
    let mut buf = [0u8; 64];

    // Report ID 0x06, payload: 00 22 00 00
    buf[0] = 0x06;
    buf[1] = 0x00;
    buf[2] = 0x22;
    buf[3] = 0x00;
    buf[4] = 0x00;
    device.send_feature_report(&buf).ok();

    // Same again
    device.send_feature_report(&buf).ok();

    // Report ID 0x06, payload: 00 22 01 00
    buf[3] = 0x01;
    device.send_feature_report(&buf).ok();

    // Report ID 0x06, payload: 00 22 02 00
    buf[3] = 0x02;
    device.send_feature_report(&buf).ok();
}
```

**Note:** The exact packet format needs verification — the Wireshark capture
shows `810600220000` which may be: report_id=0x81, then 0x06, 0x00, 0x22, 0x00, 0x00.
This needs USB HID protocol analysis to determine if `0x81` is the GET_REPORT
request and `0x06` is the actual report ID being fetched.

---

## Phase 5: Monado + ewwm Integration

Once display is working:

1. **Install Monado via nixpkgs-xr:**
   ```bash
   nix profile install github:nix-community/nixpkgs-xr#monado
   ```

2. **Configure Monado for Beyond:**
   ```bash
   export STEAMVR_LH_ENABLE=1
   export XRT_COMPOSITOR_COMPUTE=1
   export XRT_COMPOSITOR_DESIRED_MODE=1  # 90 Hz
   export LH_OVERRIDE_IPD_MM=64  # Your IPD
   monado-service &
   ```

3. **DRM Lease from ewwm compositor:**
   - Compositor detects `non_desktop=1` connector
   - Advertises via `wp_drm_lease_device_v1`
   - Monado acquires lease for exclusive display access
   - This is already implemented in `compositor/src/vr/drm_lease.rs`

4. **Eye Tracking:**
   - Bigeye camera → libuvc (v4l has issues) → 800x400 MJPEG frames
   - Use [bsb2e_linux fork of Baballonia](https://github.com/leon-costa/Baballonia)
   - NixOS: `nix run 'git+https://github.com/leon-costa/Baballonia?submodules=1#default'`
   - Route gaze data through OpenXR → ewwm-vr-eye.el
   - Note: eye camera firmware updates still require Windows

---

## Phase 6: Native Bootstrap Tool (Long-term)

Replace the Proton dependency with a native Rust tool:

### `compositor/src/vr/beyond_hid.rs`

```rust
pub struct BeyondHid {
    device: HidDevice,
}

impl BeyondHid {
    pub fn open() -> Result<Self>;
    pub fn power_on_display(&self) -> Result<()>;
    pub fn set_brightness(&self, pct: u8) -> Result<()>;  // 0-100
    pub fn set_fan_speed(&self, pct: u8) -> Result<()>;   // 40-100
    pub fn set_led_color(&self, r: u8, g: u8, b: u8) -> Result<()>;
    pub fn get_firmware_version(&self) -> Result<String>;
    pub fn read_proximity_sensor(&self) -> Result<bool>;
    pub fn read_imu(&self) -> Result<ImuData>;  // From input reports
}
```

### `lisp/vr/ewwm-vr-beyond.el`

```elisp
(defun ewwm-vr-beyond-set-brightness (pct)
  "Set Beyond display brightness (0-100)."
  (interactive "nBrightness: ")
  (ewwm-ipc-send (format "(beyond-set-brightness :value %d)" pct)))

(defun ewwm-vr-beyond-power-on ()
  "Send display power-on sequence to Beyond."
  (interactive)
  (ewwm-ipc-send "(beyond-display-power-on)"))
```

---

## Timeline Estimate

| Phase | Effort | Blocking? |
|-------|--------|-----------|
| 1. System prereqs | 30 min | No |
| 2. Kernel upgrade | 2-4 hours | **Yes** — display won't work without it |
| 3. Display verify | 15 min | Validates phases 1-2 |
| 4A. Proton bootstrap | 1-2 hours | First path to working display |
| 4B. Native HID init | 2-4 hours | Alternative to Proton |
| 5. Monado + ewwm | 4-8 hours | Full integration |
| 6. Native tool | 1-2 weeks | Long-term replacement |

**Critical path: Phase 2 (kernel) blocks everything else.**

---

## Fallback: QEMU/VFIO or Windows To Go

If any step absolutely requires native Windows:

### VFIO VM (one-time calibration)
- 9070 XT VFIO confirmed working (PCI `1002:7550` + `1002:ab40`)
- Pass entire USB controller (not individual devices) for Beyond
- Single-GPU passthrough: unbind host display, pass to VM, rebind on shutdown
- Calibration data stored as JSON on headset — persists after returning to Linux

### Windows To Go USB (emergency)
```bash
sudo woeusb --device /path/to/Windows11.iso /dev/sdX --target-filesystem ntfs
```
32GB USB minimum. Only needed for eye camera firmware updates or enrollment.

### What Requires Windows (as of March 2026)
1. Eye camera firmware updates (may be resolved by upcoming firmware)
2. IPD adjustment via Utility (workaround: `LH_OVERRIDE_IPD_MM` with Monado)
3. Eye tracking initial enrollment (workaround: Baballonia bsb2e_linux fork)
