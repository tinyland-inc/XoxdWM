# Bigscreen Beyond 2e: AMD Kernel Patches Deep Dive

## Context

Getting the Bigscreen Beyond 2e working on AMD GPUs (specifically RX 9070 XT / Navi 48 / GFX1201) with Linux kernel >= 6.16.8 requires **two kernel patches**. Without them, you get either a black display or rainbow static artifacts.

This document covers what each patch does, why it's needed, and the technical details of the Beyond's EDID and DSC pipeline.

## The Two Patches

### 1. `bigscreen-beyond-kernel.patch` — EDID Non-Desktop Quirk

**Purpose**: Marks the Beyond as a non-desktop (VR/AR) display in the kernel's EDID quirk table.

**What it does**: Adds an entry to `edid_quirk_list[]` in `drivers/gpu/drm/drm_edid.c`:
```c
/* Bigscreen Beyond */
EDID_QUIRK('B', 'I', 'G', 0x1234, EDID_QUIRK_NON_DESKTOP),
```

This sets the `non_desktop` DRM connector property to `1`, which tells compositors (Sway, KDE, GNOME) not to use this connector for regular desktop output. Instead, VR runtimes like Monado can acquire it via DRM lease.

**Do you actually need it?** Maybe not — Sway already parses the EDID manufacturer code "BIG" and marks the connector as `non_desktop: true` independently of the kernel property. Monado acquires the DRM lease either way. But the kernel quirk is the "proper" fix and ensures non_desktop works regardless of compositor.

**Status in mainline**: As of kernel 6.19.5, this quirk is NOT in the mainline kernel. It's carried as a patch by CachyOS, Bazzite, and other gaming-focused distros.

**Beyond EDID details**:
- Manufacturer: `BIG` (EDID PnP ID `0x0927`)
- Product: `0x5095`
- Extension: DisplayID 1.2 with Type I Detailed Timing (5120x2560@30Hz)
- No product name string in EDID (binary-only manufacturer code)
- No VESA vendor-specific block (no DSC BPP declaration in EDID)

### 2. `amd-bsb-dsc-fix.patch` — DSC QP Table Corrections

**Purpose**: Fixes Display Stream Compression (DSC) quantization parameter tables for 4:4:4 8bpc at 8 bits-per-pixel.

**What it does**: Three targeted changes:

#### a. QP Max Table (`qp_tables.h`, line ~66)
```diff
-    {   8, { 4, 4, 5, 6, 7, 7, 7, 8, 9, 10, 10, 11, 11, 12, 13} },
+    {   8, { 4, 4, 5, 6, 7, 7, 7, 8, 9, 10, 11, 12, 13, 13, 15} },
```
The max QP values for the last 5 ranges (indices 10-14) are increased. This allows the DSC encoder more quantization headroom at 8 BPP, preventing underflow in complex image regions.

#### b. QP Min Table (`qp_tables.h`, line ~214)
```diff
-    {   8, { 0, 0, 1, 1, 3, 3, 3, 3, 3, 4, 5, 5, 5, 8, 12} },
+    {   8, { 0, 0, 1, 1, 3, 3, 3, 3, 3, 3, 5, 5, 5, 7, 13} },
```
Adjusts min QP for indices 9, 13, and 14 to match the corrected range.

#### c. Rate Control Offset (`rc_calc_fpu.c`, line ~126)
```diff
-    *p++ = (bpp <=  6) ? (-12) : ((bpp >=  8) ? (-10) : (-12 + ...));
+    *p++ = (bpp <=  6) ? (-12) : ((bpp >=  8) ? (-12) : (-12 + ...));
```
Changes the rate control offset from -10 to -12 when BPP >= 8. This tightens the rate control at the 8 BPP operating point.

**Why the Beyond triggers this bug**: The Beyond uses DSC with 8 bits-per-pixel compression at 3840x1920@90Hz. The stock kernel's QP tables produce invalid quantization at exactly 8 BPP in 4:4:4 mode, causing "rainbow static" — the DSC decoder on the Beyond's panel receives garbled rate control metadata and produces psychedelic noise instead of the intended image.

**Affected GPUs**: All AMD GPUs using the `amdgpu` display core (DC/DML). Confirmed on RX 9070 XT (GFX1201). Likely affects all RDNA2+ cards.

## The CachyOS Combined Patch: `0007-vesa-dsc-bpp.patch`

CachyOS carries both fixes PLUS additional DRM infrastructure in a single 392-line patch (`0007-vesa-dsc-bpp.patch`). This combined patch includes:

### Part 1: DSC QP Table Fixes
Same as `amd-bsb-dsc-fix.patch` above (3 targeted changes).

### Part 2: VESA DisplayID DSC BPP Passthrough (NEW)
A significant DRM subsystem enhancement that teaches the kernel to read DSC bits-per-pixel from EDID DisplayID VESA vendor-specific blocks:

- Adds `dp_dsc_bpp_x16` field to `struct drm_display_info` (6.4 fixed-point format)
- Adds `dsc_passthrough_timings_support` flag to `struct drm_display_mode`
- Refactors `drm_parse_vesa_mso_data()` → `drm_parse_vesa_specific_block()` to handle both MSO and DSC BPP
- Parses `DISPLAYID_VESA_DSC_BPP_INT` and `DISPLAYID_VESA_DSC_BPP_FRACT` from the VESA block

### Part 3: AMD Display Manager Integration
When a display mode has `dsc_passthrough_timings_support` and `dp_dsc_bpp_x16 != 0`:
```c
stream->timing.dsc_fixed_bits_per_pixel_x16 = info->dp_dsc_bpp_x16;
```
This passes the EDID-declared DSC BPP directly to the AMD display hardware, bypassing the kernel's DSC BPP negotiation algorithm.

**Note for Beyond**: The Beyond 2e does NOT have a VESA vendor-specific block in its EDID (verified by hex dump analysis). This means Part 2+3 of the combined patch won't directly benefit the Beyond — the kernel will still use its own DSC BPP calculation. However, the QP table fixes (Part 1) are essential.

## Which Patch to Apply

| Situation | Patch Needed |
|-----------|-------------|
| Beyond shows nothing (black) | Check USB-C port FIRST (must be LEFT port) |
| Beyond shows rainbow static | `amd-bsb-dsc-fix.patch` (DSC QP fixes) |
| Want proper non_desktop in kernel | `bigscreen-beyond-kernel.patch` (EDID quirk) |
| Using CachyOS kernel | Already included in `0007-vesa-dsc-bpp.patch` |

## Critical Hardware Notes

### USB-C Port

The Beyond has two USB-C ports:
- **LEFT**: Fiber optic cable connection (DP + USB multiplexed via Link Box). This is the **only required** headset connection.
- **RIGHT**: Accessory port (USB 2.0, ~500mA). For audio adapters, face trackers, etc. NOT for display.

### HID Power-On Command Format

The Beyond uses 65-byte HID feature reports on the proprietary channel (35bd:0101). The command byte goes at **byte[1]** (after the report ID byte at byte[0]):

```
[0x00, CMD, data...]
```

Known commands: `0x22` (SetWorkState/power-on), `0x49` (brightness), `0x4C` (LED), `0x46` (fan), `0x56` (firmware version).

The power-on sequence is 5 packets:
```
[0x00, 0x22, 0x00, ...zeros]  (x3, phase 0)
[0x00, 0x22, 0x01, ...zeros]  (phase 1)
[0x00, 0x22, 0x02, ...zeros]  (phase 2)
```

**Bug found**: Early implementations (including our initial `beyond_hid.rs`) had an extra 0x00 before the command, placing 0x22 at byte[2]. This was inconsistent with how brightness/LED/fan commands worked and may have caused the headset to ignore power-on.

### Two HID Channels

The Beyond exposes two separate HID paths:
1. **35bd:0101** (Bigscreen proprietary): LED, fan, brightness, power-on. No report IDs, 64-byte vendor-defined reports.
2. **28de:2300** (Valve Watchman): IMU, tracking, config, video mode, HMD status. 33 report IDs (0x01-0x32).

The Watchman channel handles video configuration (`SelectVideoConfig`) and display state management. A complete display initialization may require commands on BOTH channels.

## Build Instructions (Rocky Linux 10, kernel 6.19.5)

```bash
# Prerequisites
sudo dnf install kernel-ml-devel-$(uname -r) gcc make elfutils-libelf-devel

# Clone patches
git clone https://github.com/CachyOS/kernel-patches.git /tmp/kernel-patches

# Apply DSC fix (minimal, standalone)
cd /usr/src/kernels/$(uname -r)
sudo patch -p1 < /tmp/amd-bsb-dsc-fix/amd-bsb-dsc-fix.patch

# Or apply full CachyOS DSC+BPP patch
sudo patch -p1 < /tmp/kernel-patches/6.19/0007-vesa-dsc-bpp.patch

# Rebuild just the amdgpu module
sudo make modules_prepare
sudo make M=drivers/gpu/drm/amd/display modules
sudo make M=drivers/gpu/drm/amd/display modules_install

# Reload
sudo modprobe -r amdgpu && sudo modprobe amdgpu
```

## Pipeline Verification

When the display IS working, you should see in `amdgpu_dm_dtn_log`:
```
DSC[1]:  ON  SLICE_WIDTH=960  Bytes_pp=256
S_ENC[1]: enc_enabled=1  stream_active=1
L_ENC[1]: link_trained=1  FEC_enabled=1
OTG[1]:  h_total=4200  v_total=1987  vtotal_max/min=0/0
```

Key indicators:
- `DSC ON` with `SLICE_WIDTH=960` (3840/4 slices)
- `FEC_enabled=1` (Forward Error Correction required for DSC over DP)
- `link_trained=1` (DP link negotiation succeeded)
- `stream_active=1` (frames being sent)

## References

- CachyOS kernel-patches: `https://github.com/CachyOS/kernel-patches/tree/master/6.19`
- amd-bsb-dsc-fix: `https://github.com/matte-schwartz/amd-bsb-dsc-fix`
- Monado VR runtime: `https://monado.freedesktop.org/`
- Beyond USB-C port info: Bigscreen support documentation
