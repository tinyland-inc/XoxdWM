# XR-optimized kernel for Bigscreen Beyond 2e + AMD GPUs
#
# Two build modes:
#   1. Nix kernel derivation (NixOS deployments)
#   2. RPM kernel build (Rocky Linux deployments via rpmbuild) — WIP/placeholder
#
# Patches:
#   - bigscreen-beyond-edid.patch: EDID non-desktop quirk (BIG/0x1234)
#   - 0007-vesa-dsc-bpp.patch: CachyOS combined DSC fix
#     (QP tables + RC ofs[11] + VESA DisplayID BPP parser + amdgpu_dm integration)
#
# CI integration:
#   Build via GloriousFlywheel ARC runners, cache via Attic.
#   RPMs are built by the linux-xr CI pipeline, not this derivation.
#
# Usage (NixOS):
#   boot.kernelPackages = pkgs.linuxPackages_xr;
#
# Attic caching flow:
#   nix build .#kernel-xr  ->  attic push xr-cache result/
#   Subsequent builds on machines with the xr-cache substituter
#   get binary substitution instead of rebuilding the kernel.
#
{ lib, linuxKernel, fetchpatch, fetchurl, pkgs, ... }:

let
  patchDir = ../../patches;

  # Patches carried in this repository
  localPatches = [
    {
      name = "bigscreen-beyond-non-desktop";
      patch = patchDir + "/bigscreen-beyond-edid.patch";
    }
    {
      # CachyOS combined: QP tables + RC ofs[11] + VESA DisplayID parser
      # + amdgpu_dm dsc_fixed_bits_per_pixel_x16 passthrough.
      # This is the critical patch for Beyond DSC at 8 BPP.
      name = "vesa-dsc-bpp-cachyos";
      patch = patchDir + "/0007-vesa-dsc-bpp.patch";
    }
  ];

  # Structured kernel config for XR workloads
  xrConfig = with lib.kernel; {
    # VR frame timing: 1000Hz tick for sub-ms scheduling
    HZ_1000 = yes;
    HZ = freeform "1000";

    # AMD display: DSC and floating-point support
    DRM_AMD_DC_DSC = yes;
    DRM_AMD_DC_FP = yes;

    # USB: Beyond HID + Bigeye UVC + Valve Radio
    USB_HIDDEV = yes;
    HID_GENERIC = yes;
    USB_VIDEO_CLASS = yes;

    # DRM lease support (Monado VR compositor)
    DRM = yes;

    # SMI mitigation (from Dell T7810 BIOS A34 firmware RE)
    HWLAT_TRACER = yes;         # in-kernel hardware latency tracer
    TRACER_SNAPSHOT = yes;       # snapshot support for latency capture
    X86_MSR = yes;               # /dev/msr for SMI_COUNT (MSR 0x34)
    DELL_RBU = module;           # Dell Remote BIOS Update driver
    ITCO_WDT = no;               # disable TCO watchdog (eliminates TCO_EN SMIs)

    # BCI workload support (100:100 channel AD/DA, C777 wordclock)
    CPU_ISOLATION = yes;         # isolcpus for dedicated BCI cores
    NO_HZ_FULL = yes;            # tickless idle on isolated cores
    HIGH_RES_TIMERS = yes;       # sub-ms timer resolution
    RCU_NOCB_CPU = yes;          # offload RCU callbacks from isolated cores
    IRQ_FORCED_THREADING = yes;  # force threaded IRQ handlers
    UIO = yes;                   # userspace I/O for BCI devices
    UIO_PCI_GENERIC = yes;
  };

  # RT preemption config (applied when enableRT = true)
  rtConfig = with lib.kernel; {
    PREEMPT_RT = yes;
    PREEMPT_VOLUNTARY = lib.mkForce no;
    # RT needs full preemption, disable voluntary
    PREEMPT = lib.mkForce no;
    PREEMPT_DYNAMIC = lib.mkForce no;
  };

  # Fetch the PREEMPT_RT patch for a given kernel version.
  # RT patch versions trail mainline slightly; adjust rtVersion as needed.
  #
  # Find available RT patches at:
  #   https://cdn.kernel.org/pub/linux/kernel/projects/rt/
  fetchRtPatch = { kernelVersion, rtVersion }:
    let
      majorMinor = lib.versions.majorMinor kernelVersion;
    in {
      name = "preempt-rt-${rtVersion}";
      patch = fetchurl {
        url = "https://cdn.kernel.org/pub/linux/kernel/projects/rt/${majorMinor}/patch-${rtVersion}.patch.xz";
        # Set the real sha256 after first fetch attempt:
        #   nix-prefetch-url --unpack <url>
        # or let the build fail and copy the hash from the error message.
        sha256 = lib.fakeHash;
      };
    };

  mkXrKernel = {
    baseKernel,
    enableRT ? false,
    rtVersion ? null,
    extraPatches ? [],
    extraConfig ? {},
  }:
    let
      rtPatches = lib.optionals (enableRT && rtVersion != null) [
        (fetchRtPatch {
          kernelVersion = baseKernel.version;
          inherit rtVersion;
        })
      ];
    in
    baseKernel.override {
      structuredExtraConfig = xrConfig
        // (lib.optionalAttrs enableRT rtConfig)
        // extraConfig;
      kernelPatches = (baseKernel.kernelPatches or [])
        ++ localPatches
        ++ rtPatches
        ++ extraPatches;
    };

in {
  inherit mkXrKernel localPatches xrConfig rtConfig;

  # Standard XR kernel (latest mainline + patches)
  xrKernel = baseKernel: mkXrKernel { inherit baseKernel; };

  # RT XR kernel (requires rtVersion to be specified)
  xrKernelRT = baseKernel: rtVersion: mkXrKernel {
    inherit baseKernel rtVersion;
    enableRT = true;
  };

  # RPM build for Rocky Linux — WIP/placeholder.
  # This derivation will NOT build as-is: sha256 is a placeholder
  # and the spec file path needs updating for your local tree.
  # For production RPM builds, use the linux-xr CI pipeline.
  xrKernelRpm = { kernelVersion ? "6.19.5" }:
    pkgs.stdenv.mkDerivation {
      pname = "kernel-xr-rpm";
      version = kernelVersion;

      src = pkgs.fetchurl {
        url = "https://cdn.kernel.org/pub/linux/kernel/v${lib.versions.major kernelVersion}.x/linux-${kernelVersion}.tar.xz";
        # Replace with real sha256 for the target kernel version:
        #   nix-prefetch-url https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.19.5.tar.xz
        sha256 = lib.fakeHash;
      };

      nativeBuildInputs = with pkgs; [
        rpm
        gcc gnumake perl bc bison flex rsync
        elfutils openssl
        xz
      ];

      patches = map (p: p.patch) localPatches;

      buildPhase = ''
        cp ${patchDir + "/bigscreen-beyond-edid.patch"} .
        cp ${patchDir + "/0007-vesa-dsc-bpp.patch"} .

        # NOTE: spec file path assumes packaging/rpm/kernel-xr.spec exists.
        # Adjust if your tree uses a different location.
        cp ${../../packaging/rpm/kernel-xr.spec} kernel-xr.spec

        mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
        cp $src rpmbuild/SOURCES/
        cp *.patch rpmbuild/SOURCES/

        rpmbuild -bb \
          --define "_topdir $PWD/rpmbuild" \
          --define "kversion ${kernelVersion}" \
          kernel-xr.spec
      '';

      installPhase = ''
        mkdir -p $out
        cp rpmbuild/RPMS/*/*.rpm $out/ || true
      '';
    };
}
