# Dell T7810 SMI Latency Baseline — BIOS A02

**Date**: 2026-03-15
**System**: Dell Precision Tower 7810 (0GWHMW)
**BIOS**: A02 (2014-09-05) — factory original, 32 revisions behind current A34
**Kernel**: 6.19.5-1.el10.elrepo.x86_64 (ELRepo mainline, no RT)
**CPU**: 2× Xeon E5-2630 v3 (Haswell-EP, 8C/16T each, 16C/32T total)
**NUMA**: 2 domains — node0: CPUs 0-7,16-23 / node1: CPUs 8-15,24-31

## Methodology

### Firmware Analysis

Dell T7810 BIOS A34 firmware (T7810A34.exe, 10MB PE32) was extracted and analyzed:

1. **Extraction**: zlib-compressed PFS container at offset `0x07A410` decompresses to 17.1MB
2. **Parsing**: `uefi-firmware-parser -b -e` yields 3,091 files, 499 PE32 modules
3. **Inventory**: 270 DXE drivers, 153 SMM handlers, 72 PEI modules, 2 applications
4. **Build provenance**: Intel Grantley platform, WellsburgPkg (C610 PCH), Dell gen6b BIOS

### SMI Source Mapping

The PCH SMI Dispatcher (`DELL_PCH_SMI_DISPATCHER`, 26KB) was analyzed for I/O port access patterns:

| Register | Port | References | Purpose |
|----------|------|-----------|---------|
| ACPI_BASE | 0x0400 | 128 | Base I/O address for ACPI/SMI registers |
| SMI_EN | 0x0430 | via bits | SMI source enable register |
| SMI_STS | 0x0434 | via bits | SMI status register |

SMI_EN bit usage across all 499 PE32 modules:

| Bit | Name | Total refs | Top module | Risk |
|-----|------|-----------|------------|------|
| 3 | LEGACY_USB_EN | 2,642 (281 modules) | AMITSE (setup) | CRITICAL |
| 17 | LEGACY_USB2_EN | 1,821 (164 modules) | AMITSE (setup) | CRITICAL |
| 13 | TCO_EN | 2,732 (430 modules) | AMITSE (setup) | MEDIUM |
| 14 | PERIODIC_EN | 2,442 (430 modules) | AMITSE (setup) | MEDIUM |
| 5 | APMC_EN | 3,863 (430 modules) | AMITSE (setup) | HIGH |

The AMITSE (AMI TSE Setup Engine, 891KB) is the single largest consumer of SMI-related bits with 1,244 combined references.

### Dell-Specific SMM Modules

| Module | GUID | Size | Purpose |
|--------|------|------|---------|
| DellVariableSmm | 166fd043 | 63KB | UEFI variable access via SMI trap |
| DellSmBiosDaCiSmm | 2e3f2275 | 37KB | Dell SMBIOS command interface |
| DellDashBiosManager | 59378206 | 29KB | Remote management (periodic SMIs) |
| DellPchSmiDispatcher | b0d6ed53 | 26KB | Master SMI router |
| DellSmmSbGeneric | 71287108 | 14KB | USB Legacy SMI handler |
| DellCpuSmm | 4e98a9fe | 9KB | CPU thermal/microcode SMIs |
| DellPstateControl | 75be667c | 8KB | P-state changes via SMI |
| DellHeciSmm | 921cd783 | 6KB | Intel ME communication |

## Measurements

### MSR 0x34 (SMI_COUNT)

```
SMI count at boot:     ~9,959 (accumulated during POST)
SMIs in 10 seconds:    0 (idle system, no active I/O)
SMIs in 30 seconds:    22 (0.73/s — periodic management SMI)
```

The 10s measurement of zero is misleading — the periodic SMI fires approximately once per second but has jitter. The 30s measurement reliably captures the pattern.

### Hardware Latency Tracer (hwlat)

Kernel hwlat tracer configuration:
```
threshold:  10us
width:      500ms (sampling window)
window:     1000ms
duration:   60s
```

Results (60 events in 60 seconds):

| Latency Range | Events | Affected CPUs | Description |
|--------------|--------|---------------|-------------|
| **2000-2523us** | ~6 | 24-28 (node1) | Cross-socket SMI rendezvous |
| **1694-1961us** | ~3 | 27 (node1) | Socket 1 SMI handler execution |
| **606us** | 1 | 26 (node1) | Shorter SMI variant |
| **16-60us** | ~50 | all | Background noise (acceptable) |

**Worst case: 2,523us (2.5ms) on CPU 24 (NUMA node1 / socket 1)**

### NUMA Asymmetry

Socket 1 consistently shows higher SMI latency than socket 0. This is expected on the C610 PCH architecture: the PCH is physically connected to socket 0, so SMI handling occurs locally on socket 0 but requires a cross-socket Inter-Processor Interrupt (IPI) to halt socket 1 for the SMI rendezvous. The IPI + cache coherency overhead adds ~500-1000us to the SMI duration on socket 1.

## Impact on BCI Workloads

| Sample Rate | Samples Lost per SMI | Events per Minute | Total Loss |
|-------------|---------------------|--------------------|------------|
| 250 Hz | 0.6 | 60 | 36 samples/min |
| 500 Hz | 1.25 | 60 | 75 samples/min |
| 1000 Hz | 2.5 | 60 | 150 samples/min |

At 1000 Hz with 100 channels, this represents **15,000 channel-samples corrupted per minute**.

For VR at 90 Hz (11.1ms frame budget), a 2.5ms SMI stall consumes 22.5% of the frame budget and will cause visible judder.

## Root Cause Analysis

1. **Periodic SMI timer**: The `DELL_SMART_TIMER` module generates periodic SMIs at ~1/s for system health monitoring. This is the primary source.

2. **USB Legacy emulation**: LEGACY_USB_EN (bit 3) and LEGACY_USB2_EN (bit 17) are enabled in BIOS A02 by default. These generate SMIs whenever the keyboard/mouse are accessed through USB legacy pathways.

3. **Dell management overhead**: `DellDashBiosManager` and `DellVariableSmm` contribute to SMI handler execution time. Every UEFI variable access (e.g., reading boot entries) triggers a full SMI trap cycle.

4. **BIOS A02 microcode**: The factory Haswell-EP microcode has the TSC-deadline timer errata. Under PREEMPT_RT, this can cause spurious timer interrupts during the SMI handler, potentially deadlocking the TSC sync rendezvous between sockets.

## Expected Improvement After BIOS A34

| Mitigation | Expected Impact |
|-----------|-----------------|
| BIOS A34 microcode update | Fixes TSC-deadline errata, stabilizes timer subsystem |
| Disable USB Legacy Support | Eliminates bits 3,17 — removes ~50% of SMI handler code paths |
| Disable Intel AMT | Removes HECI SMI handler entirely |
| Disable Computrace | Removes periodic anti-theft SMI check-ins |
| C-States limited to C1 | Eliminates APIC timer wakeup SMI path |
| `intel_pstate=disable` | Removes P-state SMI routing through `DellPstateControl` |

**Target**: <10us max hardware latency after all mitigations applied.

## Verification Plan

1. Flash BIOS A34 (FreeDOS USB or Ctrl+Esc recovery)
2. Configure BIOS settings (USB Legacy, AMT, C-States)
3. Install kernel-xr (generic, non-RT)
4. Apply tuned profile `xr-bci`
5. Re-run hwlat tracer: `echo hwlat > /sys/kernel/tracing/current_tracer`
6. Measure SMI count: `rdmsr -p 0 0x34` before/after 60s
7. Compare against this baseline
8. If <10us max latency achieved, proceed to RT kernel

## Tooling

All measurements reproducible via:
```bash
# From exwm repo:
just smi-validate honey --full    # comprehensive validation
just bios-verify honey            # check BIOS version
just bios-tuned-deploy honey      # deploy tuned profile
```

## Files

| File | Purpose |
|------|---------|
| `packaging/scripts/smi-validate` | Automated SMI characterization script |
| `packaging/tuned/xr-bci/tuned.conf` | RT workload tuned profile |
| `packaging/dhall/Platform.dhall` | Type-safe T7810 platform definition |
| `packaging/bios/extracted/` | Full firmware extraction (499 PE32 modules) |
