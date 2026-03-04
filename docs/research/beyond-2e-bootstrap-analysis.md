# Bigscreen Beyond 2e Bootstrap Analysis

## Hardware Inventory (honey server)

| Device | USB ID | Description | Status |
|--------|--------|-------------|--------|
| Bigscreen Beyond | 35bd:0101 | HMD (HID + Audio) | Detected, serial XCNL4M25CA001675 |
| Bigscreen Bigeye | 35bd:0202 | Eye tracking (UVC) | Detected, 800x400 MJPEG ~90fps |
| Valve VR Radio x2 | 28de:2102 | Base station dongles | Detected |
| Valve Tundra Tracker | 28de:2300 | Body tracker | Detected |
| AMD RX 9070 XT | PCI 0x7550 | Navi 48 / GFX1201 | amdgpu loaded, RADV working |

**Display link: NOT connected** — all DP connectors show `disconnected`, no EDID.

---

## 1. Why the Display Is Not Activating

### 1a. HID Initialization Required

Per [SteamVR-for-Linux#610](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/610),
the Beyond display **does not activate until specific HID packets are sent**.

Wireshark capture of Windows initialization traffic shows these packets are sent
to the Beyond's HID interface before the display powers on:

```
810600220000   (request HID report — board power init)
810600220000
810600220000
810600220100
810600220200
```

These are 36-byte "Request HID report" messages targeting the Beyond's internal
display board controller. Without them, the display stays black even though
tracking, audio, and proximity sensors work.

### 1b. Kernel Non-Desktop Quirk

The Beyond's EDID does not properly set the `non_desktop` flag, which causes
desktop environments to treat it as a regular monitor. A
[kernel patch](https://www.phoronix.com/news/Linux-Bigscreen-Beyond-VR)
(submitted by contact@scrumplex.net) adds a one-line quirk to force
`non_desktop = 1` for the Beyond's EDID. This patch has NOT been merged
upstream as of early 2025.

For AMD GPUs, the [LVRA wiki](https://lvra.gitlab.io/docs/hardware/)
recommends **kernel 6.15+** (or the `linux-bsb` AUR package which bundles
the patch). Our honey server runs kernel **6.12.0 RT** — too old.

### 1c. Display Stream Compression (DSC)

The Beyond uses DSC for its high-resolution micro-OLED panels. The AMD
amdgpu driver has had DSC issues with VR headsets. Mesa 25.0+ and kernel
6.13+ include fixes. Our system Mesa 25.0.7 should be fine, but the
kernel 6.12 may lack DSC fixes for RDNA 4.

---

## 2. Beyond 2e HID Protocol (Decoded)

### USB Interfaces

**Beyond (35bd:0101)** — 3 interfaces, Full Speed (12Mbps):
- Interface 0: **Audio Control** (stereo mic input terminal)
- Interface 1: **Audio Streaming** (48kHz/16-bit PCM, async isochronous EP4 IN)
- Interface 2: **HID** (Vendor-defined, interrupt EP1 IN, 64-byte reports)

**Bigeye (35bd:0202)** — 2 interfaces, High Speed (480Mbps):
- Interface 0: **Video Control** (UVC camera sensor)
- Interface 1: **Video Streaming** (800x400 MJPEG, ~90fps, isochronous EP2 IN)

### HID Report Descriptor (38 bytes)

```
Usage Page: 0xFFFF (Vendor-Defined)
Collection: Application
  Input:   64 bytes (Usage 0x02, 0x03) — headset → host
  Feature: 64 bytes (Usage 0x06, 0x07) — bidirectional config
End Collection
```

No Output reports — all host→device communication uses HID Feature reports
(Get/Set Feature Report).

### Known HID Commands

From [beyond_squared](https://github.com/ichbinkenny/beyond_squared) (Rust).
All commands are 65-byte HID Feature Reports:

```
Byte [0]: 0x00 (report ID)
Byte [1]: Command type
Byte [2..N]: Data
Byte [N+1..64]: Zero padding
```

| Command | Byte[1] | Data | Range |
|---------|---------|------|-------|
| Set LED Color | `0x4C` ('L') | [2]=R, [3]=G, [4]=B | 0-255 per channel |
| Set Fan Speed | `0x46` ('F') | [2]=speed | 40-100% |
| Set Brightness | `0x49` ('I') | [2-3]=big-endian u16 | 0x0032–0x010A |

Brightness formula: `device_value = (2.15 * percentage + 50) as u16`

### Additional Protocol Details

- **Firmware is JSON-based** — contains lens distortion, mura correction, display timing
- Accessible via SteamVR `lighthouse_console`:
  `~/.steam/steam/steamapps/common/SteamVR/tools/lighthouse/bin/linux64/lighthouse_console`
  Can download/upload JSON config. **Back up config before editing — risk of bricking.**
- 72/75/90Hz mode switching = flashing a different JSON firmware
- **IPD is mechanical** on Beyond 2e (53-70mm hex tool adjustment, no HID needed)
- **Beyond 2e ships with Universal-Fit Cushion** — no iPhone face scan needed
  (unlike Beyond 1 which required XR+ face scan for custom cushion)
- **Eye tracking enrollment is server-side** — requires token from Bigscreen,
  model trained on their GPU infrastructure, then runs locally on user's GPU
- **Fiber cable is NOT reversible** — must plug into LEFT USB-C port on headset

### SteamVR Configuration for Beyond

File: `~/.steam/steam/config/steamvr.vrsettings`
```json
{
  "compositor": {
    "disableAsync": true,
    "enableLinuxVulkanAsync": false,
    "forceFadeOnBadTracking": false
  },
  "steamvr": {
    "allowDisplayPortModeSwitch": false,
    "allowDisplayPortTraining": false,
    "enableLinuxVulkanAsync": false,
    "motionSmoothing": false,
    "renderTargetMultiplier": 1.0
  }
}
```

### SteamCMD Windows SteamVR Download (No Windows Needed)

The Beyond Utility under Proton needs a Windows SteamVR install path:
```bash
mkdir steamvr_win && steamcmd +@ShutdownOnFailedCommand 1 \
  +@sSteamCmdForcePlatformType windows \
  +force_install_dir $(realpath steamvr_win) \
  +login anonymous +app_update 250820 validate +quit
```

### Success Probability (from Arch Guide)

- HMD recognition via Proton + HIDRAW: ~70%
- SteamVR with tracking + display: ~60-70%
- With kernel EDID quirk patch: ~80-85%

### Display Power-On Sequence (from Wireshark)

The missing initialization packets are HID report requests:
```
Report ID 0x81, 6 bytes payload
Sequence: 06 00 22 00 00  (×3)
          06 00 22 01 00  (×1)
          06 00 22 02 00  (×1)
```
These likely control the internal display controller power rails.

---

## 3. Bootstrap Strategy Options

### Option A: Proton + Steam (Recommended First Attempt)

The [Arch Linux VR guide](https://gist.github.com/Chuyo2022/09dc4d8404c2e8d638b20d3d2ccd0643)
documents a working procedure:

1. Install Steam on honey
2. Install "Bigscreen Beyond Driver" from Steam (app ID 2467050)
3. Force Proton Experimental (or ≥10) in Properties
4. Set launch options: `PROTON_ENABLE_HIDRAW=0x35BD/0x0101 %command%`
5. Install udev rules for hidraw access
6. Launch Beyond Driver → it handles HID initialization + calibration
7. Then launch SteamVR

**Pros:** Known working on AMD + Arch. Beyond Driver handles all calibration.
**Cons:** Requires Steam, Proton, SteamVR stack. Heavy dependency chain.

### Option B: Native HID Tool (beyond_squared enhanced)

Write a Linux-native HID tool that:
1. Sends the display power-on sequence (the 5 missing packets)
2. Sets IPD, brightness, fan speed via feature reports
3. Handles eye tracking calibration enrollment
4. Communicates with Monado instead of SteamVR

**Pros:** No Windows dependencies. Full control. Can integrate into ewwm.
**Cons:** Requires reverse-engineering the complete calibration protocol.
The beyond_squared tool only covers LED/fan/brightness — not IPD or
eye tracking calibration.

### Option C: Monado Direct (Matrix Fork)

The [LVRA wiki](https://lvra.gitlab.io/docs/other/bigscreen-beyond/)
notes: "Bigscreen Beyond works with Monado on AMD with a kernel patch;
SteamVR works on AMD after Monado has run."

This suggests Monado handles the HID initialization that SteamVR-for-Linux
does not. Matrix's Monado fork "fixes some Bigscreen specific issues."

**Pros:** Open source, lighter than SteamVR. Direct OpenXR integration.
**Cons:** May still need kernel patch. Matrix fork availability unclear.

### Option D: QEMU/KVM USB Passthrough

Run Windows VM with USB passthrough for initial calibration:
1. VFIO GPU passthrough for the 9070 XT (confirmed working)
2. USB passthrough for the Beyond hub chain (pass whole USB controller)
3. Run Bigscreen software in VM for initial setup
4. Return to Linux after calibration (settings stored as JSON on headset)

**VFIO Device IDs:**
- VGA: `1002:7550` (Navi 48)
- Audio: `1002:ab40`
- Requires `<rom bar="off"/>` in libvirt XML
- Resizable BAR may need: `echo 3 > /sys/bus/pci/devices/[PCI_ADDR]/resource2_resize`

```nix
# NixOS VFIO config
boot.kernelParams = [ "amd_iommu=on" "vfio-pci.ids=1002:7550,1002:ab40" ];
boot.initrd.kernelModules = [ "vfio_pci" "vfio" "vfio_iommu_type1" ];
```

**Pros:** Guaranteed to work for initial calibration.
**Cons:** Complex setup. Single GPU passthrough disrupts host. One-time use.

### Option E: Windows-to-Go USB Stick

Minimal Windows installation on USB for initial calibration only.
Create via [WoeUSB-ng](https://github.com/WoeUSB/WoeUSB-ng) from Linux:
```bash
sudo woeusb --device /path/to/Windows11.iso /dev/sdX --target-filesystem ntfs
```

**Pros:** Simplest guaranteed path. 32GB USB minimum.
**Cons:** Requires Windows license. Separate boot.

---

## 4. Recommended Path Forward

### Phase 1: Fix Kernel + Permissions (Immediate)

1. **Add jess to required groups:**
   ```bash
   sudo usermod -aG video,render,input jess
   ```

2. **Install udev rules** from `packaging/udev/99-exwm-vr.rules`

3. **Kernel upgrade path:**
   - Rocky 10 may not have 6.15 available in standard repos
   - Options: kernel-ml from ELRepo, or build custom kernel with BSB patch
   - The BSB non-desktop quirk patch is a one-liner — we can carry it

### Phase 2: Proton Bootstrap (Most Proven)

Install Steam + Beyond Driver via Proton. This is the most documented
working path on AMD GPUs. Do initial calibration here.

### Phase 3: Native HID Integration (ewwm)

Once calibrated and display confirmed working:

1. **Port beyond_squared HID commands into ewwm-vr-display.el**
   - Brightness, fan speed, LED control via `ewwm-vr-beyond-set-brightness`
   - Display power-on sequence as part of session start

2. **Write display power-on routine in compositor**
   - Send the 5-packet HID init sequence on session start
   - Add to `compositor/src/vr/drm_lease.rs` or new `beyond_hid.rs`

3. **Eye tracking via UVC**
   - Bigeye camera is standard UVC — use v4l2 directly
   - 800x400 MJPEG at ~90fps
   - Feed frames to eye tracking ML model
   - Bigscreen says raw camera outputs are "open and accessible to any VR developer"

4. **Monado driver integration**
   - Target Matrix's Monado fork
   - Implement Beyond-specific OpenXR extensions

### Phase 4: Fully Native (Long-term)

Eventually replace all Proton/Steam dependencies with native tools:
- Custom HID daemon for Beyond management
- Direct Monado OpenXR runtime
- Native eye tracking pipeline
- No Windows software required for new headset setup

---

## 5. GPU Status (AMD RX 9070 XT on Rocky 10)

| Component | Current | Required | Notes |
|-----------|---------|----------|-------|
| Kernel | 6.12.0 RT | **6.13.5+** | SMU tables, firmware loading, DCN 4.0.1 |
| Mesa (system) | 25.0.7 | 25.0+ | OK — minimum for RADV GFX1201 |
| Mesa (Nix) | 24.2.8 | **25.0+** | **NOT sufficient** — only experimental GFX12 |
| amdgpu firmware | gc_12_0_0 | Verify dates | Need commit de78f0aa+ from linux-firmware |
| SMU driver | 0x2e vs fw 0x32 | 6.13.5+ kernel | **Critical** — affects power/display init |
| Vulkan | 1.3.289 RADV | OK | Compute works, display may not |

### Critical: Kernel 6.12 Is Insufficient for RDNA 4 Display

The SMU version mismatch (`smu driver if version = 0x2e, smu fw if version = 0x32`)
is **not cosmetic** — it means the kernel's SMU interface tables are outdated for
the GPU firmware. This can cause:
- Display engine (DCN 4.0.1) never initializing
- GPU staying in BACO (Bus Active, Chip Off) power state
- DP link training never starting
- All connectors showing "disconnected" (exactly our symptom)

Users on kernel 6.12 with Navi 48 report firmware loading errors (-19/ENODEV).
Kernel 6.13.5 is the community-established minimum for reliable RX 9070 operation.

**Rocky 10 will NOT ship kernel 6.13+** — RHEL-based distros don't upgrade
major kernel versions within a release. Options:
1. Build mainline kernel 6.14.x with Bigscreen Beyond EDID quirk patch
2. Use ELRepo for mainline kernel packages
3. Nix-managed kernel as sidecar

### Firmware Update Required

```bash
# Check firmware dates
ls -la /lib/firmware/amdgpu/gc_12_0_0*

# Update from git
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
sudo cp linux-firmware/amdgpu/* /lib/firmware/amdgpu/
sudo dracut --force  # Rebuild initramfs
```

### Kernel Parameters

```
amdgpu.modeset=1 amdgpu.dc=1 amdgpu.dcdebugmask=0x10
```

---

---

## 6. Monado Integration (Key Findings)

**Upstream Monado does NOT have a dedicated Beyond driver.** Beyond works
through the **SteamVR Lighthouse wrapper driver** (`STEAMVR_LH_ENABLE=1`).

### How Beyond Works with Monado

1. Beyond uses Lighthouse base station tracking (same as Vive/Index)
2. Monado's Lighthouse driver handles tracking
3. Monado acquires the display via DRM lease (needs non_desktop quirk)
4. Bigscreen Beyond Utility (Proton) handles HID communication

### IPD Override

The Beyond Utility's IPD adjustment does NOT work under Proton. Use:
```bash
LH_OVERRIDE_IPD_MM=64  # Set to your IPD in mm
```

### Eye Tracking Stack (Beyond 2e)

```
Bigeye camera (UVC) → Baballonia → eye tracking ML model → OpenXR
```

Key projects:
- [Baballonia](https://github.com/Project-Babble/Baballonia) — cross-platform eye/face tracking
- [bsb2e_linux fork](https://github.com/leon-costa/Baballonia) — libuvc plugin for Bigeye
- [go-bsb-cams](https://github.com/LilliaElaine/go-bsb-cams) — Go camera capture + HTTP stream
- Kernel patch may be needed for UVC `dwMaxVideoFrameSize` check

### nixpkgs-xr Overlay

```nix
services.monado = {
  enable = true;
  defaultRuntime = true;
  highPriority = true;
};
systemd.user.services.monado.environment = {
  STEAMVR_LH_ENABLE = "1";
  XRT_COMPOSITOR_COMPUTE = "1";
  XRT_COMPOSITOR_DESIRED_MODE = "1";  # 90 Hz
  LH_OVERRIDE_IPD_MM = "64";
};
```

### EDID Quirk Patch Details

- **Author:** Sefa Eyeoglu (Scrumplex)
- **File:** `drivers/gpu/drm/drm_edid.c`
- **Change:** `EDID_QUIRK('B', 'I', 'G', 0x1234, EDID_QUIRK_NON_DESKTOP)`
- **Status:** NOT merged upstream. Available via:
  - `linux-bsb` AUR package
  - [Nobara-BSB-RPM-Sources](https://github.com/foxyote/Nobara-BSB-RPM-Sources)
  - Manual patch (one-liner)

---

## 7. Beyond 2e USB Device IDs

| PID | Device | Purpose |
|-----|--------|---------|
| 0x0101 | Beyond | HMD (HID + Audio) |
| 0x0202 | Bigeye | Eye tracking cameras |
| 0x0105 | Audio Strap | Audio (if equipped) |
| 0x4004 | Firmware Mode | DFU/firmware update |

### udev Rules (Complete)

```
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="0101", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="0202", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="0105", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="4004", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="35bd", MODE="0666"
```

---

## Sources

- [SteamVR-for-Linux#610](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/610) — Display wake-up bug, HID packet analysis
- [beyond_squared](https://github.com/ichbinkenny/beyond_squared) — Rust HID utility (LED, fan, brightness)
- [Arch Linux VR Guide](https://gist.github.com/Chuyo2022/09dc4d8404c2e8d638b20d3d2ccd0643) — Complete setup procedure
- [LVRA Wiki: Beyond](https://lvra.gitlab.io/docs/other/bigscreen-beyond/) — Linux VR Adventures documentation
- [LVRA Wiki: Hardware](https://lvra.gitlab.io/docs/hardware/) — Kernel patch requirements
- [Phoronix: Linux BSB Patch](https://www.phoronix.com/news/Linux-Bigscreen-Beyond-VR) — Non-desktop EDID quirk
- [Bigscreen Beyond 2e Eye Tracking Setup](https://store.bigscreenvr.com/blogs/beyond/beyond-2e-eyetracking-setup-guide-with-vrchat)
- [Monado Documentation](https://monado.freedesktop.org/) — Direct mode, driver architecture
- [Monado Driver Writing Guide](https://monado.pages.freedesktop.org/monado/writing-driver.html)
- [DRM Leasing for VR](https://drewdevault.com/2019/08/09/DRM-leasing-and-VR-for-Wayland.html)
- [nixpkgs-xr](https://github.com/nix-community/nixpkgs-xr) — Nix XR/VR overlay
- [Baballonia](https://github.com/Project-Babble/Baballonia) — Eye tracking
- [go-bsb-cams](https://github.com/LilliaElaine/go-bsb-cams) — Camera capture
- [Nobara-BSB-RPM-Sources](https://github.com/foxyote/Nobara-BSB-RPM-Sources) — RPM kernel + tools
- [Level1Techs RX 9070 Setup](https://forum.level1techs.com/t/9070-and-9070-xt-setup-notes-for-linux/227038)
- [Fedora RX 9070 Fix](https://discussion.fedoraproject.org/t/fix-for-radeon-rx-9070-xt-on-fedora-amdgpu-firmware-errors-19-and-black-screen-solved/175555)
- [NVIDIA DSC Discussion](https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/679)
- [Kernel EDID Patch (dri-devel)](https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg493878.html)
- [VFIO 9070 XT Working (Level1Techs)](https://forum.level1techs.com/t/vfio-pass-through-working-on-9070xt/227194)
- [9070 XT VFIO Gist](https://gist.github.com/gdesatrigraha/95426de35da26a9747a16991b00789ab)
- [NixOS GPU Passthrough + VR](https://astrid.tech/2022/09/22/0/nixos-gpu-vfio/)
- [WoeUSB-ng](https://github.com/WoeUSB/WoeUSB-ng)
