# XR-optimized kernel for Bigscreen Beyond 2e + AMD GPUs
#
# Two build modes:
#   1. Nix kernel derivation (NixOS deployments)
#   2. RPM kernel build (Rocky Linux deployments via rpmbuild)
#
# Patches:
#   - bigscreen-beyond-edid.patch: EDID non-desktop quirk (BIG/0x1234)
#   - 0007-vesa-dsc-bpp.patch: CachyOS combined DSC fix
#     (QP tables + RC ofs[11] + VESA DisplayID BPP parser + amdgpu_dm integration)
#
# CI integration:
#   Build via GloriousFlywheel ARC runners, cache via Attic.
#   RPMs published to private repo for Rocky deployments.
#
# Usage (NixOS):
#   boot.kernelPackages = pkgs.linuxPackages_xr;
#
# Usage (Rocky Linux):
#   nix build .#kernel-xr-rpm  # produces RPM in result/
#
{ lib, linuxKernel, fetchpatch, pkgs, ... }:

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
  };

  # RT preemption config
  rtConfig = with lib.kernel; {
    PREEMPT_RT = yes;
    PREEMPT_VOLUNTARY = lib.mkForce no;
  };

  mkXrKernel = { baseKernel, extraPatches ? [], extraConfig ? {} }:
    baseKernel.override {
      structuredExtraConfig = xrConfig // extraConfig;
      kernelPatches = (baseKernel.kernelPatches or [])
        ++ localPatches
        ++ extraPatches;
    };

in {
  # Standard XR kernel (latest mainline + patches)
  xrKernel = baseKernel: mkXrKernel { inherit baseKernel; };

  # RT XR kernel
  xrKernelRT = baseKernel: mkXrKernel {
    inherit baseKernel;
    extraConfig = rtConfig;
  };

  # RPM build for Rocky Linux (wraps kernel source + patches into rpmbuild)
  xrKernelRpm = { kernelVersion ? "6.19.5" }:
    pkgs.stdenv.mkDerivation {
      pname = "kernel-xr-rpm";
      version = kernelVersion;

      src = pkgs.fetchurl {
        url = "https://cdn.kernel.org/pub/linux/kernel/v${lib.versions.major kernelVersion}.x/linux-${kernelVersion}.tar.xz";
        # sha256 must be updated per version
        sha256 = lib.fakeSha256;
      };

      nativeBuildInputs = with pkgs; [
        rpm rpmbuild
        gcc gnumake perl bc bison flex rsync
        elfutils openssl
        xz
      ];

      patches = map (p: p.patch) localPatches;

      buildPhase = ''
        cp ${patchDir + "/bigscreen-beyond-edid.patch"} .
        cp ${patchDir + "/0007-vesa-dsc-bpp.patch"} .
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

  inherit localPatches xrConfig;
}
