# ICE40 DSC Decoder: Formal Verification Notes

## Context

The Bigscreen Beyond 2e uses a Lattice ICE40 HX8K FPGA as its DSC (Display Stream
Compression) decoder. The FPGA sits between the DP receiver and the dual MIPI display
panels. It receives PPS (Picture Parameter Set) metadata + compressed pixel data over DP
and outputs decompressed pixels to the panels.

The FPGA's behavior is the ground truth for what DSC parameters work. Kernel-side fixes
(QP tables, RC offsets, BPP negotiation) are only useful if the resulting PPS is accepted
by the FPGA decoder.

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
512 → 0 overflow. This would make the decoder start transmitting immediately (delay=0)
instead of buffering 512 pixels, causing catastrophic decode failure.

### Alternative Hypothesis: Code Path Difference

The `dsc_policy_max_target_bpp_limit` binary hack forces BPP=128 via the bandwidth
negotiation path. The proper upstream fix uses `dsc_fixed_bits_per_pixel_x16` from the
EDID VESA vendor block, which may take a different computation path through the AMD
display code. These two paths might produce different PPS parameters even at the same
nominal BPP.

## Verification Approaches

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
# IceStorm can convert bitstream → routing → netlist
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

**This is the most actionable approach.** If the NVIDIA PPS differs from what Linux
produces at BPP=128, the difference reveals what the FPGA actually expects.

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

# Fields to test (BPP=144 → BPP=128):
# initial_xmit_delay: 455 → 512 (binary search around 500)
# initial_dec_delay: 790 → 856
# initial_offset: 5888 → 6144
# initial_scale_value: 28 → 32
# slice_bpg_offset: 245 → 123

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

1. **USB PPS capture from NVIDIA** — most information, moderate effort
2. **Upstream kernel patches** — proper dsc_fixed_bits_per_pixel_x16 path
3. **Systematic PPS boundary testing** — can do today on honey
4. **IceStorm bitstream extraction** — requires hardware access
5. **SymbiYosys formal verification** — requires netlist from step 4

## References

- VESA DSC 1.2a specification (section 3.2: RC parameter computation)
- Project IceStorm: https://github.com/YosysHQ/icestorm
- SymbiYosys: https://github.com/YosysHQ/sby
- Yosys: https://github.com/YosysHQ/yosys
- Lattice ICE40 HX8K datasheet: https://www.latticesemi.com/iCE40
- CachyOS kernel-patches: https://github.com/CachyOS/kernel-patches
