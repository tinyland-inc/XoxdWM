# kernel-xr.spec — XR-optimized kernel RPM for Rocky Linux 10
#
# Build: rpmbuild -bb \
#   --define "kversion 6.19.5" \
#   --define "xr_release 1" \
#   --define "rt_version 6.19.3-rt1" \
#   --define "variant -rt" \
#   kernel-xr.spec
#
# The build-rpm.sh script handles source/patch fetching and calls this.

# Disable automatic debuginfo/debugsource subpackages — kernel handles
# debug info internally via CONFIG_DEBUG_INFO and BTF.
%global debug_package %{nil}

%{!?kversion: %global kversion 6.19.5}
%{!?xr_release: %global xr_release 1}
%global krelease  %{xr_release}.xr.el10
%{!?rt_version: %global rt_version %{nil}}
%{!?variant: %global variant %{nil}}

Name:           kernel-xr%{variant}
Version:        %{kversion}
Release:        %{krelease}
Summary:        XR-optimized kernel with DSC fixes for Bigscreen Beyond 2e
License:        GPL-2.0-only
URL:            https://github.com/Jesssullivan/linux-xr

Source0:        linux-%{kversion}.tar.xz
Source1:        base.config

# XR patches (fetched by build-rpm.sh into SOURCES/)
Patch0:         0007-vesa-dsc-bpp.patch
Patch1:         bigscreen-beyond-edid.patch

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  elfutils-libelf-devel
BuildRequires:  openssl-devel
BuildRequires:  openssl
BuildRequires:  perl-interpreter
BuildRequires:  bc
BuildRequires:  bison
BuildRequires:  flex
BuildRequires:  rsync
BuildRequires:  rpm-build
BuildRequires:  dwarves
BuildRequires:  kmod

Requires(pre):  coreutils
Requires(pre):  systemd >= 203-2
Requires(pre):  /usr/bin/kernel-install
Requires(pre):  dracut >= 027
Requires(preun): systemd >= 200

Provides:       kernel-xr%{variant} = %{kversion}-%{krelease}
Provides:       kernel = %{kversion}-%{krelease}

%description
Linux kernel %{kversion} with XR/VR patches for Bigscreen Beyond 2e headsets
on AMD GPUs (RDNA2+). Includes:
- VESA DisplayID DSC BPP parser (CachyOS combined patch)
- EDID non-desktop quirk for Beyond (BIG/0x1234)
- DSC QP table corrections for 8bpc 4:4:4 at 8 BPP
- RC offset fix for ofs[11] in get_ofs_set() CM_444/CM_RGB
%if "%{rt_version}" != ""
- PREEMPT_RT real-time scheduling (%{rt_version})
%endif

%package devel
Summary:        Development files for kernel-xr %{kversion}
Provides:       kernel-devel = %{kversion}-%{krelease}

%description devel
Kernel headers and build support files for compiling out-of-tree modules
against kernel-xr %{kversion}-%{krelease}.

%package headers
Summary:        Header files for kernel-xr %{kversion}
Provides:       kernel-headers = %{kversion}-%{krelease}

%description headers
Userspace API header files for kernel-xr %{kversion}-%{krelease}.

%prep
%setup -q -n linux-%{kversion}

# Apply RT patch first (if building RT kernel)
%if "%{rt_version}" != ""
patch -p1 < %{_sourcedir}/patch-%{rt_version}.patch
%endif

# CachyOS combined: VESA DSC BPP parser + QP tables + RC offsets + amdgpu_dm
%patch -P0 -p1

# EDID non-desktop quirk for Beyond (fuzz needed: context shifted by DSC patch)
patch -p1 --fuzz=3 < %{_sourcedir}/bigscreen-beyond-edid.patch

# Apply base config from honey server
cp %{SOURCE1} .config

# XR-specific config overrides
scripts/config --set-val CONFIG_HZ 1000
scripts/config --enable CONFIG_HZ_1000
scripts/config --disable CONFIG_HZ_250
scripts/config --enable CONFIG_DRM_AMD_DC_DSC
scripts/config --enable CONFIG_DRM_AMD_DC_FP
scripts/config --enable CONFIG_USB_HIDDEV
scripts/config --enable CONFIG_USB_VIDEO_CLASS
scripts/config --set-str CONFIG_LOCALVERSION "-%{krelease}"

# SMI mitigation config (from Dell T7810 BIOS RE analysis)
# These ensure the kernel ships tools for characterizing and mitigating
# SMI-induced latency on C610/Wellsburg PCH systems.
scripts/config --enable CONFIG_HWLAT_TRACER
scripts/config --enable CONFIG_OSNOISE_TRACER
scripts/config --enable CONFIG_TIMERLAT_TRACER
scripts/config --enable CONFIG_TRACER_SNAPSHOT
scripts/config --enable CONFIG_X86_MSR
scripts/config --module CONFIG_DELL_RBU
scripts/config --disable CONFIG_ITCO_WDT

# BCI workload support (CPU isolation, high-res timers)
scripts/config --enable CONFIG_CPU_ISOLATION
scripts/config --enable CONFIG_NO_HZ_FULL
scripts/config --enable CONFIG_HIGH_RES_TIMERS
scripts/config --enable CONFIG_RCU_NOCB_CPU
scripts/config --enable CONFIG_IRQ_FORCED_THREADING
scripts/config --enable CONFIG_UIO
scripts/config --enable CONFIG_UIO_PCI_GENERIC

# RT-specific config
%if "%{rt_version}" != ""
scripts/config --enable CONFIG_PREEMPT_RT
scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
scripts/config --disable CONFIG_PREEMPT_NONE
%endif

# Debug info + BTF (systemd 257 requires BPF/BTF for cgroup v2).
# Kconfig: CONFIG_DEBUG_INFO_BTF depends on !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED
# Use DWARF5 (default, smaller than DWARF4) with BTF generation via pahole.
# The .BTF section is ~1.6MB; DWARF is stripped by rpmbuild find-debuginfo.
scripts/config --enable CONFIG_DEBUG_INFO
scripts/config --enable CONFIG_DEBUG_INFO_DWARF5
scripts/config --disable CONFIG_DEBUG_INFO_DWARF4
scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
scripts/config --disable CONFIG_DEBUG_INFO_REDUCED
scripts/config --disable CONFIG_DEBUG_INFO_SPLIT
scripts/config --disable CONFIG_DEBUG_INFO_NONE
scripts/config --enable CONFIG_DEBUG_INFO_BTF
scripts/config --enable CONFIG_DEBUG_INFO_BTF_MODULES
scripts/config --enable CONFIG_DEBUG_INFO_COMPRESSED_ZSTD
scripts/config --disable CONFIG_DEBUG_INFO_COMPRESSED_NONE

# systemd 257 (Rocky 10.1) hard requirements — ensure these survive olddefconfig
scripts/config --disable CONFIG_FW_LOADER_USER_HELPER
scripts/config --enable CONFIG_AUTOFS_FS
scripts/config --enable CONFIG_TMPFS_XATTR
scripts/config --enable CONFIG_TMPFS_POSIX_ACL
scripts/config --enable CONFIG_OVERLAY_FS

# Validate: list any new config options not resolved by base.config
echo "=== New config options (should be empty or expected) ==="
make listnewconfig 2>/dev/null | grep -c CONFIG_ || true

make olddefconfig

# POST-OLDDEFCONFIG VALIDATION:
# make olddefconfig can re-enable options via Kconfig dependencies.
# Re-apply critical overrides and abort if they don't stick.
echo "=== Post-olddefconfig: re-applying critical systemd 257 overrides ==="
scripts/config --disable CONFIG_FW_LOADER_USER_HELPER
scripts/config --disable CONFIG_DEBUG_INFO_NONE
scripts/config --disable CONFIG_DEBUG_INFO_REDUCED
scripts/config --enable CONFIG_DEBUG_INFO_BTF

# Run olddefconfig again to resolve any new dependencies from re-applied overrides
make olddefconfig

# Hard validation: abort build if critical configs are wrong
echo "=== Validating critical kernel config ==="
fail=0
check_config() {
    local key="$1" expected="$2"
    actual=$(grep "^${key}=" .config 2>/dev/null || grep "^# ${key} is not set" .config 2>/dev/null || echo "MISSING")
    if [ "$expected" = "n" ]; then
        if echo "$actual" | grep -q "is not set"; then
            echo "  OK: ${key} is not set"
        elif echo "$actual" | grep -q "=n"; then
            echo "  OK: ${key}=n"
        else
            echo "  FAIL: ${key} should be disabled but got: ${actual}"
            fail=1
        fi
    else
        if echo "$actual" | grep -q "=${expected}"; then
            echo "  OK: ${key}=${expected}"
        else
            echo "  FAIL: ${key} expected=${expected} got: ${actual}"
            fail=1
        fi
    fi
}
check_config CONFIG_FW_LOADER_USER_HELPER n
check_config CONFIG_DEBUG_INFO_BTF y
check_config CONFIG_DEBUG_INFO_NONE n
check_config CONFIG_DEBUG_INFO_REDUCED n
check_config CONFIG_BPF_SYSCALL y
check_config CONFIG_CGROUP_BPF y
if [ "$fail" -ne 0 ]; then
    echo "FATAL: Critical kernel config validation failed. Aborting build."
    echo "This kernel would fail to boot on systemd 257 (Rocky 10.1)."
    exit 1
fi

# Capture the actual kernel release string (includes -rt1 if RT patched)
KREL=$(make -s kernelrelease)
echo "Kernel release: ${KREL}"
echo "${KREL}" > .kernel-release

%build
KREL=$(cat .kernel-release)
# Cap parallelism: containers report host nproc, not cgroup CPU limit.
# Kernel compilation uses ~1GB per gcc job; limit to avoid OOM on CI runners.
JOBS=$(nproc 2>/dev/null || echo 2)
[ "$JOBS" -gt 4 ] && JOBS=4

# Deterministic build: without these, ccache gets 0% hits because
# __DATE__/__TIME__/BUILD_TIMESTAMP differ on every invocation.
export KBUILD_BUILD_TIMESTAMP=''
export KBUILD_BUILD_USER='builder'
export KBUILD_BUILD_HOST='ci'

make %{?_cc:CC="%{_cc}"} -j${JOBS} V=0 bzImage modules

%install
KREL=$(cat .kernel-release)
mkdir -p %{buildroot}/boot
mkdir -p %{buildroot}/lib/modules

make INSTALL_MOD_PATH=%{buildroot} modules_install

# Install kernel + support files manually (do NOT use `make install` — it
# triggers kernel-install/dracut hooks which fail inside rpmbuild chroot)
cp arch/x86/boot/bzImage %{buildroot}/boot/vmlinuz-${KREL}
cp System.map %{buildroot}/boot/System.map-${KREL}
cp .config %{buildroot}/boot/config-${KREL}

# Copy vmlinuz into modules dir (required by kernel-install at install time)
cp arch/x86/boot/bzImage %{buildroot}/lib/modules/${KREL}/vmlinuz

# Remove depmod auto-generated files (regenerated at install time)
rm -f %{buildroot}/lib/modules/${KREL}/modules.{alias,alias.bin,builtin.alias.bin}
rm -f %{buildroot}/lib/modules/${KREL}/modules.{dep,dep.bin,devname,softdep}
rm -f %{buildroot}/lib/modules/${KREL}/modules.{symbols,symbols.bin}

# Install vmlinux for devel
mkdir -p %{buildroot}/usr/src/kernels/${KREL}
cp -a .config Module.symvers System.map Makefile \
    %{buildroot}/usr/src/kernels/${KREL}/
cp -a include scripts arch/x86/include \
    %{buildroot}/usr/src/kernels/${KREL}/

# Headers
make INSTALL_HDR_PATH=%{buildroot}/usr headers_install

# Remove build/source symlinks (point to builddir)
rm -f %{buildroot}/lib/modules/${KREL}/build
rm -f %{buildroot}/lib/modules/${KREL}/source
ln -sf /usr/src/kernels/${KREL} \
    %{buildroot}/lib/modules/${KREL}/build

%post
# Phase 1: signal that core is being installed (modules may arrive later)
KREL=%{kversion}-%{krelease}
ACTUAL_KREL=$(ls /lib/modules/ | grep "%{kversion}.*%{krelease}" | head -1)
mkdir -p /var/lib/rpm-state/kernel
touch /var/lib/rpm-state/kernel/installing_core_${ACTUAL_KREL:-${KREL}}

%posttrans
# Phase 2: runs after ALL sub-packages in the transaction are installed.
# This is the canonical point for kernel-install (triggers depmod, dracut, BLS).
KREL=%{kversion}-%{krelease}
ACTUAL_KREL=$(ls /lib/modules/ | grep "%{kversion}.*%{krelease}" | head -1)
ACTUAL_KREL=${ACTUAL_KREL:-${KREL}}

# Remove installing flag
rm -f /var/lib/rpm-state/kernel/installing_core_${ACTUAL_KREL}

# Register with weak-modules (RHEL/Rocky only)
if [ -x /usr/sbin/weak-modules ]; then
    /usr/sbin/weak-modules --add-kernel ${ACTUAL_KREL} || exit $?
fi

# kernel-install orchestrates: depmod, dracut (initramfs), BLS entry creation
if [ -x /usr/bin/kernel-install ]; then
    /usr/bin/kernel-install add ${ACTUAL_KREL} /lib/modules/${ACTUAL_KREL}/vmlinuz || exit $?
else
    # Fallback for systems without kernel-install
    depmod -a ${ACTUAL_KREL}
    dracut --force /boot/initramfs-${ACTUAL_KREL}.img ${ACTUAL_KREL} || true
    grubby --set-default /boot/vmlinuz-${ACTUAL_KREL} || true
fi

echo ""
echo "kernel-xr installed: ${ACTUAL_KREL}"
echo ""
echo "For RT/BCI workloads, install the xr-bci tuned profile:"
echo "  sudo tuned-adm profile xr-bci"
echo "  sudo reboot"
echo "Validate: sudo smi-validate --full"

%preun
KREL=%{kversion}-%{krelease}
ACTUAL_KREL=$(ls /lib/modules/ | grep "%{kversion}.*%{krelease}" | head -1)
ACTUAL_KREL=${ACTUAL_KREL:-${KREL}}
if [ -x /usr/bin/kernel-install ]; then
    /usr/bin/kernel-install remove ${ACTUAL_KREL} || exit $?
fi
if [ -x /usr/sbin/weak-modules ]; then
    /usr/sbin/weak-modules --remove-kernel ${ACTUAL_KREL} || exit $?
fi

%postun
if [ $1 -eq 0 ]; then
    depmod -a
fi

%files
/boot/*%{kversion}*%{krelease}*
/lib/modules/*%{kversion}*%{krelease}*/

%files devel
/usr/src/kernels/*%{kversion}*%{krelease}*/

%files headers
/usr/include/*
