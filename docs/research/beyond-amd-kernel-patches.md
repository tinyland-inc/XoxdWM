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
 		*p++ = -10;                                           // ofs[10] - unchanged
-		*p++ = (bpp <=  6) ? (-12) : ((bpp >=  8) ? (-10) : (-12 + ...));  // ofs[11]
+		*p++ = (bpp <=  6) ? (-12) : ((bpp >=  8) ? (-12) : (-12 + ...));  // ofs[11]
```
Changes the ofs[11] rate control offset from -10 to -12 when BPP >= 8. This tightens the rate control at the 8 BPP operating point. **Note**: ofs[10] (`*p++ = -10`) is left unchanged — the fix is specifically on ofs[11] (the conditional BPP>=8 position).

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

**CORRECTION (2026-03-09)**: The Beyond 2e DOES have a VESA vendor-specific DisplayID
block in its EDID at offset 0xB0:
```
7E 00 07 3A 02 92 81 00 08 00 00 00
tag=0x7E, len=7, OUI=3A:02:92 (VESA), BPP_int=8, BPP_frac=0 → BPP=8.0 (128 x16)
```
Kernel 6.19.5 logs "Unexpected VESA vendor block size" because the MSO parser doesn't
recognize the DSC BPP format. Parts 2+3 of the CachyOS patch ARE critical for Beyond —
they add the parser that reads `dsc_fixed_bits_per_pixel_x16 = 128` from EDID, enabling
the correct DSC computation code path.

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

## BPP Binary Search Results (2026-03-09)

Systematic testing with `dsc_policy_max_target_bpp_limit` binary patching reveals a
hard threshold between BPP=9.0 and BPP=8.0:

| BPP x16 | Real BPP | initial_xmit_delay | initial_offset | Displays |
|---------|----------|-------------------|----------------|----------|
| 182 | 11.375 | 360 | 3168 | ON (grey noise) |
| 176 | 11.0 | 372 | 3840 | ON (grey noise) |
| 144 | 9.0 | 455 | 5888 | ON (grey noise) |
| 128 | 8.0 | 512 | 6144 | **OFF** |

**Hypothesis**: `initial_xmit_delay = 512 = 0x200` overflows a 9-bit register in
the ICE40 FPGA DSC decoder, causing immediate decode failure. This needs verification
via:
1. Formal analysis of ICE40 DSC decoder bitstream (Yosys/SymbiYosys)
2. USB capture of NVIDIA driver's PPS on Windows (known working)
3. Upstream `dsc_fixed_bits_per_pixel_x16` code path (may compute differently)

## Kernel Build Strategy

### Immediate: Rocky 10 Kernel Build with Upstream Patches

```bash
# 1. Get kernel source
rpm -i kernel-ml-6.19.5-1.el10.elrepo.src.rpm
cd ~/rpmbuild/SOURCES/

# 2. Apply CachyOS 0007 patch (contains all three fixes)
# Or apply upstream 7-patch series for VESA DisplayID DSC BPP

# 3. Build RPMs
rpmbuild -bb ~/rpmbuild/SPECS/kernel-ml.spec

# 4. Install and test
sudo dnf install ~/rpmbuild/RPMS/x86_64/kernel-ml-*.rpm
```

### Long-term: Reproducible XR Kernel via Nix

```nix
# nix/kernel/xr-kernel.nix
{ lib, linuxKernel, fetchpatch, ... }:
linuxKernel.kernels.linux_6_19.override {
  structuredExtraConfig = with lib.kernel; {
    PREEMPT_RT = yes;
    DRM_AMD_DC_DSC = yes;
    HZ_1000 = yes;  # VR latency
  };
  kernelPatches = [
    { name = "vesa-displayid-dsc-bpp";
      patch = ./patches/0007-vesa-dsc-bpp.patch; }
    { name = "bigscreen-beyond-edid";
      patch = ../../patches/bigscreen-beyond-edid.patch; }
  ];
};
```

### CI Pipeline

- Build kernel on each patch update (GitHub Actions)
- Automated PPS capture + validation against known-good values
- Test matrix: {kernel version} × {patch set} × {GPU generation}
- Publish RPMs to private repo for honey deployment

### FPGA Formal Verification (Future)

The ICE40 HX8K DSC decoder is the ultimate source of truth for what PPS parameters
work. Formal verification approaches:

1. **Bitstream extraction**: `icestorm` tools to reverse-engineer ICE40 config
2. **Model generation**: Yosys to extract logic model from bitstream
3. **Property checking**: SymbiYosys to verify register width assumptions
4. **Reference decoder**: Software model matching the FPGA's actual behavior
5. **Boundary testing**: Systematically vary PPS fields to map acceptance ranges

## Patch Status (our repo)

| Patch | File | Status |
|-------|------|--------|
| EDID non_desktop quirk | `patches/bigscreen-beyond-edid.patch` | ✓ Correct |
| DSC QP + RC fix | `patches/amd-bsb-dsc-fix.patch` | ✓ Correct (ofs[11] fixed) |
| wlroots non_desktop | `patches/wlroots-bigscreen-non-desktop.patch` | ✓ Correct |
| VESA DisplayID DSC BPP | not yet in repo | **NEEDED** — fetch from CachyOS or upstream |

**Action items**:
1. ~~Fix `amd-bsb-dsc-fix.patch` to target ofs[11] instead of ofs[10]~~ DONE
2. Add CachyOS 0007 patch (or upstream 7-patch series) to repo
3. Build kernel RPMs with all patches
4. Test on honey with full pipeline

## References

- CachyOS kernel-patches: `https://github.com/CachyOS/kernel-patches/tree/master/6.19`
- raika-xino amd-bsb-dsc-fix: `https://github.com/raika-xino/amd-bsb-dsc-fix`
- Upstream VESA DisplayID series: lore.kernel.org (search "VESA DisplayID fixed DSC BPP")
- Monado VR runtime: `https://monado.freedesktop.org/`
- Yosys/IceStorm: `https://github.com/YosysHQ/yosys`, `https://github.com/YosysHQ/icestorm`
- VESA DSC 1.2a specification (section 3.2: RC parameter computation)
