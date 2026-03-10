# kernel-xr.spec — XR-optimized kernel RPM for Rocky Linux 10+
#
# Build from ELRepo kernel-ml SRPM with XR patches applied.
# Produces kernel-xr RPM with DSC fixes + EDID quirks for
# Bigscreen Beyond 2e on AMD GPUs.
#
# Usage:
#   rpmbuild -bb --define "kversion 6.19.5" kernel-xr.spec
#
# Prerequisites:
#   rpm -i kernel-ml-6.19.5-1.el10.elrepo.src.rpm
#   cp patches/*.patch ~/rpmbuild/SOURCES/

%define kversion %{?kversion}%{!?kversion:6.19.5}
%define krelease 1.xr.el10

Name:           kernel-xr
Version:        %{kversion}
Release:        %{krelease}
Summary:        XR-optimized kernel with DSC fixes for Bigscreen Beyond 2e
License:        GPL-2.0-only
URL:            https://github.com/Jesssullivan/XoxdWM

# Source: ELRepo kernel-ml SRPM provides linux-%{kversion}.tar.xz
Source0:        linux-%{kversion}.tar.xz

# XR patches (from exwm repo patches/ directory)
Patch0:         bigscreen-beyond-edid.patch
Patch1:         amd-bsb-dsc-fix.patch
# Patch2:       0007-vesa-dsc-bpp.patch  # CachyOS combined (when available)

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  elfutils-libelf-devel
BuildRequires:  openssl-devel
BuildRequires:  perl-interpreter
BuildRequires:  bc
BuildRequires:  bison
BuildRequires:  flex
BuildRequires:  rsync

%description
Linux kernel %{kversion} with XR/VR patches for Bigscreen Beyond 2e headsets
on AMD GPUs (RDNA2+). Includes:
- EDID non-desktop quirk for Beyond (BIG/0x1234)
- DSC QP table corrections for 8bpc 4:4:4 at 8 BPP
- RC offset fix for ofs[11] in get_ofs_set() CM_444/CM_RGB

%prep
%setup -q -n linux-%{kversion}
%patch0 -p1
%patch1 -p1

# Copy running kernel config as base
cp /boot/config-$(uname -r) .config || cp %{_sourcedir}/config-xr .config

# Enable XR-relevant options
scripts/config --enable CONFIG_DRM_AMD_DC_DSC
scripts/config --set-val CONFIG_HZ 1000
scripts/config --enable CONFIG_HZ_1000
scripts/config --disable CONFIG_HZ_250
scripts/config --enable CONFIG_USB_HIDDEV
scripts/config --enable CONFIG_USB_VIDEO_CLASS

# Set local version
scripts/config --set-str CONFIG_LOCALVERSION "-%{krelease}"

%build
make olddefconfig
make -j$(nproc) bzImage modules

%install
make INSTALL_MOD_PATH=%{buildroot} modules_install
make INSTALL_PATH=%{buildroot}/boot install

%post
depmod -a %{kversion}-%{krelease}
grubby --set-default /boot/vmlinuz-%{kversion}-%{krelease}

%files
/boot/vmlinuz-%{kversion}-%{krelease}
/boot/System.map-%{kversion}-%{krelease}
/boot/config-%{kversion}-%{krelease}
/lib/modules/%{kversion}-%{krelease}/
