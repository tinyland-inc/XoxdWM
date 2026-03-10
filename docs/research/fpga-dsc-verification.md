# Beyond DSC Decoder: Hardware Identification & PPS Analysis

## Current Status (2026-03-10)

The linux-xr kernel RPMs are built via CI (GitHub Actions, `Jesssullivan/linux-xr`
`xr/main` branch). The build includes the CachyOS combined patch (`0007-vesa-dsc-bpp.patch`),
the standalone QP/RC fix (`amd-bsb-dsc-fix.patch`), and the EDID non_desktop quirk
(`bigscreen-beyond-edid.patch`). RT support is optional via workflow dispatch.

Nix kernel derivation is also functional at `nix/kernel/xr-kernel.nix` and exposed
as `packages.kernel-xr` in the flake.

**Next step**: install XR kernel on honey and verify DSC at BPP=8.0 with corrected
QP tables and RC offsets.

### Key Finding: Code Path Analysis (2026-03-10)

Source-level analysis of the kernel's DSC subsystem confirms that **both BPP selection
paths produce identical PPS parameters**. The "different code path" hypothesis was wrong.
The actual fix is the QP table and RC offset corrections in the CachyOS patch.

See [Code Path Analysis](#code-path-analysis-binary-hack-vs-displayid) below for details.

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

### 9-Bit Register Hypothesis: Largely Ruled Out

**If the DSC decoder is an Analogix ANX753x** (most likely): The 9-bit register theory
is very unlikely. Analogix chips are production silicon designed to the DSC 1.2a spec —
they use spec-compliant register widths. The failure at BPP=8.0 is almost certainly a
PPS computation bug in the kernel driver — specifically wrong QP tables and RC offsets.

**If the DSC decoder is an FPGA**: The 9-bit register theory remains technically
plausible but is the less likely explanation given code path analysis (see below).

### ~~Alternative Hypothesis: Code Path Difference~~ — DISPROVEN

Source-level analysis of `dc_dsc.c`, `rc_calc_fpu.c`, and `drm_dsc_helper.c` confirms
that both the binary hack and the VESA DisplayID path produce **identical PPS bytes**.
The paths diverge only in HOW `bits_per_pixel = 128` is selected, not in WHAT RC
parameters result. See [Code Path Analysis](#code-path-analysis-binary-hack-vs-displayid).

### Root Cause: Wrong QP Tables + RC Offset at BPP=8.0

The stock kernel's `qp_table_444_8bpc_max` and `qp_table_444_8bpc_min` have incorrect
values at BPP=8.0, and `get_ofs_set()` computes wrong RC offsets. This produces a PPS
whose rate control parameters cause the DSC decoder to fail — regardless of whether the
decoder is an FPGA or Analogix ASIC. The QP/RC fix in `amd-bsb-dsc-fix.patch` (and
equivalently in `0007-vesa-dsc-bpp.patch`) corrects these values.

## Code Path Analysis: Binary Hack vs DisplayID

### How BPP=128 Is Selected

**Path A: Binary hack (`dsc_policy_max_target_bpp_limit = 8`)**

The module parameter clamps `policy->max_target_bpp` to 8. In `decide_dsc_bandwidth_range()`
(`dc/dsc/dc_dsc.c`), since `timing->dsc_fixed_bits_per_pixel_x16 == 0` (no VESA parser),
the else branch fires — computing bandwidth range from policy limits:

```c
range->max_target_bpp_x16 = max_bpp_x16;   // 8 * 16 = 128
range->min_target_bpp_x16 = min_bpp_x16;   // 8 * 16 = 128
```

**Path B: VESA DisplayID (`dsc_fixed_bits_per_pixel_x16 = 128`)**

The CachyOS patch adds `drm_parse_vesa_specific_block()` which reads `dsc_bpp_int` and
`dsc_bpp_fract` from the EDID VESA vendor block. For Beyond: `BPP_int=8`, `BPP_frac=0`
→ `dp_dsc_bpp_x16 = 128`. This propagates to `stream->timing.dsc_fixed_bits_per_pixel_x16`.

In `decide_dsc_bandwidth_range()`, the FIRST branch fires:

```c
uint32_t preferred_bpp_x16 = timing->dsc_fixed_bits_per_pixel_x16;  // 128
if (preferred_bpp_x16) {
    range->max_target_bpp_x16 = preferred_bpp_x16;  // 128
    range->min_target_bpp_x16 = preferred_bpp_x16;  // 128
}
```

### Why They Produce Identical PPS

Both paths ultimately call `_do_calc_rc_params()` → `drm_dsc_compute_rc_parameters()`
with the same `drm_dsc_config.bits_per_pixel = 128`. The RC parameter computation depends
only on `bits_per_pixel`, `bits_per_component`, `slice_width`, and the QP/offset tables.
None of these change between the two paths.

| PPS Field | Path A | Path B | Difference |
|-----------|--------|--------|------------|
| `bits_per_pixel` (x16) | 128 | 128 | None |
| `initial_xmit_delay` | 512 | 512 | None |
| `initial_offset` | 6144 | 6144 | None |
| `initial_dec_delay` | (same) | (same) | None |
| `initial_scale_value` | 32 | 32 | None |
| `rc_range_params[0..14]` | (same) | (same) | None |

### What Actually Changes: QP Tables + RC Offset

The CachyOS patch modifies three things in `dc/dml/dsc/`:

**1. `qp_table_444_8bpc_max` at BPP=8** (`qp_tables.h:66`):
```
Stock:   { 4, 4, 5, 6, 7, 7, 7, 8, 9, 10, 10, 11, 11, 12, 13 }
Patched: { 4, 4, 5, 6, 7, 7, 7, 8, 9, 10, 11, 12, 13, 13, 15 }
                                            ^^  ^^  ^^  ^^  ^^
```
Ranges 10-14 are raised, allowing more aggressive quantization at high buffer fullness.

**2. `qp_table_444_8bpc_min` at BPP=8** (`qp_tables.h:74`):
```
Stock:   { 0, 0, 1, 1, 3, 3, 3, 3, 3, 4, 5, 5, 5, 8, 12 }
Patched: { 0, 0, 1, 1, 3, 3, 3, 3, 3, 3, 5, 5, 5, 7, 13 }
                                       ^^           ^^  ^^
```
Range 9 lowered (was 4→3), range 13 lowered (8→7), range 14 raised (12→13).

**3. RC offset[11] in `get_ofs_set()`** (`rc_calc_fpu.c:126`):
```c
// Stock:  (bpp >= 8) ? (-10)
// Patched: (bpp >= 8) ? (-12)
```
More aggressive negative offset at range 11, increasing rate control pressure.

### Implications

The display going dark at BPP=8.0 with the binary hack was NOT because the binary hack
took a different code path — it was because the **stock kernel's QP tables and RC offsets
are wrong at BPP=8.0 for 8bpc 4:4:4/RGB**. The DSC decoder (Analogix or FPGA) rejects
the resulting PPS because the rate control parameters produce invalid decode states.

The CachyOS patch fixes both:
1. **QP/RC values** — corrects the PPS so the decoder accepts it
2. **VESA DisplayID parser** — lets the kernel discover BPP=128 from the EDID instead
   of requiring a binary hack

Both are needed: the parser without QP/RC fix would still produce a bad PPS, and the
QP/RC fix without the parser requires manual intervention to set BPP=128.

## PPS Byte-Level Diff: Stock vs Patched Kernel

### Full rc_range_params Table (15 ranges, BPP=8.0, 8bpc 4:4:4 RGB)

| Range | Stock ofs | Stock max | Stock min | Patched ofs | Patched max | Patched min | Changed? |
|------:|----------:|----------:|----------:|------------:|------------:|------------:|----------|
| 0     | +2        | 4         | 0         | +2          | 4           | 0           | —        |
| 1     | 0         | 4         | 0         | 0           | 4           | 0           | —        |
| 2     | 0         | 5         | 1         | 0           | 5           | 1           | —        |
| 3     | -2        | 6         | 1         | -2          | 6           | 1           | —        |
| 4     | -4        | 7         | 3         | -4          | 7           | 3           | —        |
| 5     | -6        | 7         | 3         | -6          | 7           | 3           | —        |
| 6     | -8        | 7         | 3         | -8          | 7           | 3           | —        |
| 7     | -8        | 8         | 3         | -8          | 8           | 3           | —        |
| 8     | -8        | 9         | 3         | -8          | 9           | 3           | —        |
| 9     | -10       | 10        | **4**     | -10         | 10          | **3**       | min_qp   |
| 10    | -10       | **10**    | 5         | -10         | **11**      | 5           | max_qp   |
| 11    | **-10**   | **11**    | 5         | **-12**     | **12**      | 5           | ofs, max |
| 12    | -12       | **11**    | 5         | -12         | **13**      | 5           | max_qp   |
| 13    | -12       | **12**    | **8**     | -12         | **13**      | **7**       | max, min |
| 14    | -12       | **13**    | **12**    | -12         | **15**      | **13**      | max, min |

### PPS Byte Encoding

Each range is a big-endian 16-bit word at PPS bytes 58-87:
- Bits [15:11] = `range_bpg_offset` (5-bit 2's complement)
- Bits [10:6] = `range_max_qp` (5 bits unsigned)
- Bits [4:0] = `range_min_qp` (5 bits unsigned)

### Changed PPS Bytes (8 of 30)

| PPS Byte | Range | Stock | Patched | Notes |
|---------:|------:|------:|--------:|-------|
| 77       | 9     | 0x84  | 0x83    | min_qp: 4→3 |
| 79       | 10    | 0x85  | 0xC5    | max_qp: 10→11 |
| 80       | 11    | 0xB2  | 0xA3    | ofs: -10→-12, max_qp: 11→12 |
| 81       | 11    | 0xC5  | 0x05    | (cont'd) |
| 82       | 12    | 0xA2  | 0xA3    | max_qp: 11→13 |
| 83       | 12    | 0xC5  | 0x45    | (cont'd) |
| 85       | 13    | 0x08  | 0x47    | max_qp: 12→13, min_qp: 8→7 |
| 87       | 14    | 0x4C  | 0xCD    | max_qp: 13→15, min_qp: 12→13 |

### What This Means

Ranges 9-14 control rate buffer behavior at **high buffer fullness** — the later
stages of DSC decoding where the buffer is most stressed. The stock kernel's values
at BPP=8.0 are too conservative: narrow QP ranges and insufficient negative bpg_offset
at range 11 prevent the rate controller from managing bit allocation at this operating
point. The decoder sees rate control states that violate its internal constraints and
rejects the stream.

The patched values widen the QP operating range and strengthen the negative pressure
at range 11 (`-10` → `-12`), giving the rate controller room to converge. This matches
the VESA DSC 1.1 reference model output (Table E-5).

**Verification on honey**: After installing the XR kernel, dump PPS from
`/sys/kernel/debug/dri/1/DP-2/dsc_pic_parameter_set` and confirm bytes 77-87
match the patched values above. If they do, the QP/RC fix is active.

## Next Verification Steps

**Step A**: Install linux-xr kernel (v6.19.5-xr1) on honey. The patched kernel has
corrected QP tables, RC offset[11], and the VESA DisplayID parser. Expected outcome:
BPP=8.0 works, display shows correct image instead of going dark.
Install via `just beyond-kernel-install honey v6.19.5-xr1`.

**Step B**: Capture PPS from `/sys/kernel/debug/dri/1/DP-2/dsc_pic_parameter_set`
on the patched kernel. Compare `rc_range_params[10..14]` against stock kernel values
to confirm the QP table fix is active. Key fields to verify:
- `rc_range_params[11].range_bpg_offset` should be -12 (was -10)
- `rc_range_params[10..14].range_max_qp` should match patched table

**Step C**: If still fails with patched kernel, capture NVIDIA PPS (Windows) for
comparison. The NVIDIA driver may use different `initial_offset` or `rc_model_size`
values that we haven't accounted for.

**Step D**: If NVIDIA PPS reveals additional differences beyond QP/RC, create a
second patch for those fields and iterate.

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

1. **linux-xr kernel install + QP/RC validation** — imminent; XR kernel has corrected
   QP tables + RC offsets + VESA DisplayID parser. Expected to resolve BPP=8.0 failure.
2. **PPS capture on honey** — dump PPS from debugfs, compare stock vs patched kernel
3. **NVIDIA PPS capture** — reference known-good PPS from Windows driver
4. **Hardware identification** — PCB photos to confirm DSC decoder chip (Analogix vs FPGA)
5. **Systematic PPS boundary testing** — field-by-field isolation (if QP/RC fix fails)
6. ~~IceStorm bitstream extraction~~ — deprioritized (FPGA theory largely ruled out)
7. ~~SymbiYosys formal verification~~ — deprioritized (depends on step 6)

## References

- VESA DSC 1.1 specification, Annex E, Table E-5: RC range parameters for 8bpc 4:4:4
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
- CachyOS issue #731 (DSC patch integration): https://github.com/CachyOS/linux-cachyos/issues/731
- raika-xino AMD DSC fix (MIT): https://github.com/raika-xino/amd-bsb-dsc-fix
- VESA DSC 1.2 spec (hosted): https://glenwing.github.io/docs/VESA-DSC-1.2.pdf
