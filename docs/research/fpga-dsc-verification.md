# Beyond DSC Decoder: Hardware Identification & Verification Notes

## Current Status (2026-03-10)

The linux-xr kernel RPMs are built via CI (GitHub Actions, `Jesssullivan/linux-xr`
`xr/main` branch). The build includes the CachyOS combined patch (`0007-vesa-dsc-bpp.patch`),
the standalone QP/RC fix (`amd-bsb-dsc-fix.patch`), and the EDID non_desktop quirk
(`bigscreen-beyond-edid.patch`). RT support is optional via workflow dispatch.

Nix kernel derivation is also functional at `nix/kernel/xr-kernel.nix` and exposed
as `packages.kernel-xr` in the flake.

**Next step**: install XR kernel on honey and verify the VESA DisplayID parser path.

The DisplayID path takes a DIFFERENT code path through amdgpu_dm than the
`dsc_policy_max_target_bpp_limit` binary hack that was used for initial BPP=128
testing. The binary hack produced BPP=128 but displays went dark. The proper patch
uses `dsc_fixed_bits_per_pixel_x16` from the EDID VESA vendor block, which feeds into:

```
dm_helpers_read_local_edid()
  -> drm_update_dsc_info()
    -> amdgpu_dm_update_connector_after_detect()
```

This computation path may produce different PPS parameters than the binary hack at the
same nominal BPP. The kernel install may resolve the question entirely.

## Context

### Hardware Architecture (researched 2026-03-10)

The Beyond's DSC decoder architecture is **not publicly confirmed**. Our original
assumption of a "Lattice ICE40 HX8K FPGA" is **UNVERIFIED** — no teardown, FCC filing,
or Bigscreen documentation names the DSC decoder chip. The FCC filing (2BCCB-BS1) has
internal photos under confidentiality hold.

**Most likely candidate: Analogix ANX7530 or ANX7580**

The Analogix ANX753x/7580 family are purpose-built DP-to-MIPI converters for VR HMDs
with integrated DSC support:

| Chip | MIPI Output | DSC | Resolution | Package |
|------|-------------|-----|------------|---------|
| ANX7530 | 2x 8-lane (16 total) | No (HW split) | 4K@60Hz, 2K@120Hz/eye | 5x5mm BGA |
| ANX7533 | 2x 4-lane (8 total) | 3:1 DSC | 1920x1440/eye | 5x5mm BGA |
| ANX7580 | 1x 4-lane (single) | 3:1 DSC | 4K@60Hz single panel | 5x5mm BGA |

The Beyond 2e has dual 2560x2544 micro-OLED panels at 90Hz. Pixel throughput:
- Per eye: 2560 × 2544 × 90 = 586M pixels/sec
- Total: ~1.17G pixels/sec
- At 24bpp uncompressed: ~28 Gbps → requires DSC at ~3-4:1 compression
- DP 1.4 4-lane HBR3: 32.4 Gbps (sufficient for compressed stream)

The ANX7530 (dual 8-lane MIPI, no DSC, 2K@120Hz/eye) could drive the panels IF the
GPU-side DSC produces a decoded stream at the DP receiver. Alternatively, the ANX7533
(with DSC) could handle 2560x2544/eye at lower bit rates.

A dedicated FPGA (ICE40 or CrossLink) is also possible but adds cost and board area
vs. an integrated Analogix solution. The 9-bit register hypothesis remains relevant
regardless of whether DSC decoding happens in an FPGA or in the Analogix chip's
DSC decoder block.

### Known USB IDs

| Device | USB VID:PID | Description |
|--------|-------------|-------------|
| Beyond HMD | 35bd:0101 | HID + Audio composite |
| Bigeye tracker | 35bd:0202 | UVC eye camera |
| Audio Strap | 35bd:0105 | Audio accessory |
| Firmware mode | 35bd:4004 | DFU/update mode |

### What We Don't Know

1. **DSC decoder identity**: FPGA vs ASIC vs Analogix integrated — no teardown confirms
2. **Microcontroller**: USB HID vendor 0x35bd is Bigscreen's own VID; MCU unknown
3. **Display panel vendor**: Micro-OLED 2560x2544, likely Sony or BOE, unconfirmed
4. **SPI flash / FPGA bitstream**: Only relevant if the DSC decoder IS an FPGA

### DSC Decoder Behavior

Regardless of silicon identity, the DSC decoder's behavior is the ground truth for
what parameters work. Kernel-side fixes (QP tables, RC offsets, BPP negotiation) are
only useful if the resulting PPS is accepted by the decoder.

## Observed Behavior

### BPP Threshold

| BPP (x16) | Real BPP | initial_xmit_delay | Display | Notes |
|-----------|----------|-------------------|---------|-------|
| 182 | 11.375 | 360 | ON | grey noise (wrong QP?) |
| 176 | 11.0 | 372 | ON | grey noise |
| 144 | 9.0 | 455 | ON | grey noise |
| 128 | 8.0 | 512 | OFF | hard failure |

### Key Observation: initial_xmit_delay = 512 = 0x200

At BPP=8.0, the DSC spec computes `initial_xmit_delay = 512`. This value requires
10 bits to represent. All working BPP values produce `initial_xmit_delay < 512` (9 bits).

**Hypothesis**: The ICE40 FPGA uses a 9-bit register for `initial_xmit_delay`, causing
512 -> 0 overflow. This would make the decoder start transmitting immediately (delay=0)
instead of buffering 512 pixels, causing catastrophic decode failure.

### DSC 1.2a Spec Formula for initial_xmit_delay

The spec defines:

```
initial_xmit_delay = max(
  ceil((rc_model_size - initial_offset) / bits_per_pixel),
  slice_width * bits_per_component / (4 * bits_per_pixel)
)
```

At BPP=8.0 (rc_model_size=8192, initial_offset=4096, slice_width=960, bpc=8):
- Term 1: ceil((8192 - 4096) / 8.0) = ceil(512.0) = 512
- Term 2: 960 * 8 / (4 * 8.0) = 7680 / 32 = 240

Both terms are well-defined but term 1 evaluates to exactly 512 -- the spec minimum at
this BPP. This is NOT a coincidence; 8.0 BPP is the boundary where the RC model buffer
math hits exactly 2^9.

### 9-Bit Register Hypothesis: Weakened by Hardware Research

The NVIDIA Windows driver may compute different PPS because it uses its own DSC parameter
computation, not the kernel's `drm_dsc_compute_rc_parameters()`. If NVIDIA produces a
working PPS at BPP=8.0, the difference could be in the computation rather than a register
width limitation.

**If the DSC decoder is an Analogix ANX753x**: The 9-bit register theory is unlikely.
Analogix chips are production silicon designed to the DSC spec — they would use
spec-compliant register widths. The failure at BPP=8.0 would more likely be a PPS
computation issue in the kernel driver.

**If the DSC decoder is an FPGA**: The 9-bit register theory remains plausible, as
custom FPGA implementations could have non-standard register widths.

The "different code path" theory (binary hack vs. proper DisplayID path) is currently
stronger than the 9-bit register theory because:
- The binary hack forces BPP via bandwidth negotiation, bypassing EDID-informed defaults
- The proper path may set additional PPS fields (e.g., native_420, simple_422) differently
- RC parameter tables may differ between the two paths

### Alternative Hypothesis: Code Path Difference

The `dsc_policy_max_target_bpp_limit` binary hack forces BPP=128 via the bandwidth
negotiation path. The proper upstream fix uses `dsc_fixed_bits_per_pixel_x16` from the
EDID VESA vendor block, which may take a different computation path through the AMD
display code. These two paths might produce different PPS parameters even at the same
nominal BPP.

## Next Verification Steps

**Step A**: Install linux-xr kernel (v6.19.5-xr1) on honey. Check if BPP=128 works
through the proper `dsc_fixed_bits_per_pixel_x16` code path. XR kernel RPMs are built;
install via `just beyond-kernel-install honey v6.19.5-xr1`. Highest-priority action.

**Step B**: If still fails, capture PPS from
`/sys/kernel/debug/dri/1/DP-2/dsc_pic_parameter_set` and compare against the PPS
produced by the binary hack. Diff every field.

**Step C**: If PPS differs between the two paths, the issue is the computation path,
not the FPGA. Fix the PPS computation (likely RC parameters or initial_offset) and
retest.

**Step D**: If PPS is identical, the FPGA 9-bit register theory gains significant
strength. Then proceed to NVIDIA PPS capture to determine what value NVIDIA uses for
`initial_xmit_delay` at BPP=8.0.

## Verification Approaches (Background)

### 1. Bitstream Extraction (IceStorm)

Extract the ICE40 configuration bitstream to understand the actual decoder implementation.

```bash
# Tools: Project IceStorm (https://github.com/YosysHQ/icestorm)
# The ICE40 bitstream is likely loaded from SPI flash at power-on.

# Step 1: Dump SPI flash
# Requires physical access to the Beyond PCB or JTAG
# ICE40 HX8K uses SPI flash for configuration

# Step 2: Unpack bitstream
iceunpack beyond_fpga.bin > beyond_fpga.asc

# Step 3: Convert to Verilog for analysis
# IceStorm can convert bitstream -> routing -> netlist
```

**Difficulty**: Requires physical access to the FPGA's SPI flash. The Beyond's
USB interface doesn't expose FPGA configuration (only HID commands reach the
microcontroller, not the FPGA directly).

### 2. USB PPS Capture (NVIDIA Reference)

Capture the PPS that NVIDIA's Windows driver sends to the Beyond. Since the Beyond
works on Windows with NVIDIA, their PPS is known-good.

```bash
# On Windows with USBPcap/Wireshark:
# 1. Start USBPcap on the DP AUX channel
# 2. Launch BigscreenBeyondUtility.exe
# 3. Wait for display to activate
# 4. Capture DP AUX transactions containing PPS (DPCD 0x00060-0x0009F)

# On Linux with DRM debug:
echo 0x9F > /sys/module/drm/parameters/debug
# Captures DP AUX reads/writes in dmesg
```

### 3. Formal Property Checking (SymbiYosys)

If we obtain the FPGA netlist (from IceStorm), we can formally verify register widths
and data path properties.

```
# Example: verify initial_xmit_delay register width
# File: beyond_dsc_verify.sby
[tasks]
bmc

[options]
bmc: mode bmc
bmc: depth 20

[engines]
smtbmc z3

[script]
read_verilog beyond_dsc_decoder.v
prep -top dsc_decoder

[files]
beyond_dsc_decoder.v
```

Properties to verify:
- `initial_xmit_delay` register width (9-bit? 10-bit? 16-bit?)
- `rc_model_size` register width (does 8192 require more bits than allocated?)
- PPS field acceptance ranges (which values cause the decoder to reject?)
- Slice width constraints (960 = 3840/4 must be exact)

### 4. Systematic PPS Boundary Testing

Without FPGA access, we can map the decoder's acceptance range empirically by varying
PPS fields one at a time while keeping others constant.

```bash
# Methodology:
# 1. Start from known-working PPS (e.g., BPP=144)
# 2. Vary one field at a time toward BPP=128 values
# 3. Binary search each field's boundary

# Fields to test (BPP=144 -> BPP=128):
# initial_xmit_delay: 455 -> 512 (binary search around 500)
# initial_dec_delay: 790 -> 856
# initial_offset: 5888 -> 6144
# initial_scale_value: 28 -> 32
# slice_bpg_offset: 245 -> 123

# This requires binary-patching individual PPS fields in amdgpu.ko
# or intercepting drm_dsc_compute_rc_parameters() output.
```

### 5. Software Reference Decoder

Build a software model matching the FPGA's behavior based on observations.

```python
# Inputs: PPS parameters + compressed bitstream
# Output: accept/reject + decoded pixels (if accepted)
#
# Start from VESA DSC 1.2a reference decoder source code
# Modify to match observed FPGA behavior (e.g., 9-bit xmit_delay)
# Validate against all tested BPP values
```

## Formal Kernel Build Integration

The kernel patches (QP tables + RC offset + VESA DisplayID parser) should be validated
against the FPGA's acceptance criteria. CI pipeline:

```
1. Build kernel with patches
2. Extract PPS from drm_dsc_compute_rc_parameters() for BPP=128
3. Compare against known-good PPS (NVIDIA capture or formally verified)
4. Flag any out-of-range values before deployment
```

## Priority Order

1. **linux-xr kernel install + DisplayID path test** -- imminent, may resolve everything
2. **PPS diff: DisplayID path vs. binary hack** -- if Step A fails
3. **NVIDIA PPS capture** -- if PPS is identical between paths (9-bit theory)
4. **Systematic PPS boundary testing** -- field-by-field isolation
5. **Hardware identification** -- PCB photos to confirm DSC decoder chip
6. **IceStorm bitstream extraction** -- only if decoder is confirmed FPGA
7. **SymbiYosys formal verification** -- requires netlist from step 6

## References

- VESA DSC 1.2a specification (section 3.2: RC parameter computation)
- Analogix ANX753x/7580 family: https://www.analogix.com/en/products/dp-mipi-converters/anx7580
- Analogix ANX7530 (dual MIPI for VR): https://www.analogix.com/en/products/dp-mipi-converters/anx7530
- Analogix HMD product brief (2018): https://2384176.fs1.hubspotusercontent-na1.net/hubfs/2384176/DevCon-Seoul-2018/2018-MIPI-DevCon-Rodriguez-Analogix-High-Performance-VR-Apps.pdf
- Alma Technologies DSC IP cores: https://www.alma-technologies.com/ip-core.DSC-1.2b-IP
- FCC filing 2BCCB-BS1 (Bigscreen VR Headset): https://fcc.report/FCC-ID/2BCCB-BS1
- Linux VR Adventures wiki (Beyond): https://lvra.gitlab.io/docs/hardware/bigscreen-beyond/
- Bigscreen Beyond 2 official teardown: https://store.bigscreenvr.com/blogs/beyond/inside-bigscreen-beyond-2-the-teardown
- Project IceStorm: https://github.com/YosysHQ/icestorm
- SymbiYosys: https://github.com/YosysHQ/sby
- Lattice CrossLink (MIPI bridging FPGA): https://www.latticesemi.com/Products/FPGAandCPLD/CrossLink
- CachyOS kernel-patches: https://github.com/CachyOS/kernel-patches
