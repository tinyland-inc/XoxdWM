# wlroots-beyond.spec — Patched wlroots for Bigscreen Beyond VR headsets
#
# Applies the non-desktop EDID force patch so compositors (sway, etc.)
# correctly identify the Beyond as a VR headset and offer it for DRM lease.
#
# Usage:
#   rpmbuild -bb --define "wlroots_version 0.18.2" wlroots-beyond.spec

%define wlroots_version %{?wlroots_version}%{!?wlroots_version:0.18.2}

Name:           wlroots-beyond
Version:        %{wlroots_version}
Release:        1%{?dist}
Summary:        Patched wlroots with Bigscreen Beyond non-desktop detection
License:        MIT
URL:            https://gitlab.freedesktop.org/wlroots/wlroots
Source0:        %{url}/-/releases/%{version}/downloads/wlroots-%{version}.tar.gz

# Force non_desktop for Bigscreen Beyond when kernel lacks EDID quirk
Patch0:         wlroots-bigscreen-non-desktop.patch

BuildRequires:  meson >= 0.59
BuildRequires:  ninja-build
BuildRequires:  gcc
BuildRequires:  pkgconfig
BuildRequires:  wayland-devel
BuildRequires:  wayland-protocols-devel
BuildRequires:  libdrm-devel
BuildRequires:  mesa-libEGL-devel
BuildRequires:  mesa-libgbm-devel
BuildRequires:  mesa-libGL-devel
BuildRequires:  libinput-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  pixman-devel
BuildRequires:  libseat-devel
BuildRequires:  xcb-util-wm-devel
BuildRequires:  libxcb-devel
BuildRequires:  xwayland
BuildRequires:  hwdata

Provides:       wlroots = %{version}-%{release}
Provides:       wlroots%{?_isa} = %{version}-%{release}
Conflicts:      wlroots

%description
wlroots %{version} with a patch to force non_desktop=true for Bigscreen Beyond
VR headsets. Without this, compositors treat the Beyond as a regular monitor
and won't offer it for DRM lease to VR runtimes (Monado, SteamVR).

# ---------------------------------------------------------------------------
# Subpackage: devel
# ---------------------------------------------------------------------------
%package devel
Summary:        Development files for wlroots-beyond
Requires:       %{name}%{?_isa} = %{version}-%{release}
Requires:       wayland-devel
Requires:       libdrm-devel
Requires:       mesa-libEGL-devel
Requires:       mesa-libgbm-devel
Requires:       libinput-devel
Requires:       libxkbcommon-devel
Requires:       pixman-devel
Provides:       wlroots-devel = %{version}-%{release}
Provides:       wlroots-devel%{?_isa} = %{version}-%{release}
Conflicts:      wlroots-devel

%description devel
Headers and pkgconfig files for building against wlroots-beyond.

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
%prep
%autosetup -n wlroots-%{version} -p1

%build
%meson -Dxwayland=enabled -Dexamples=false
%meson_build

%install
%meson_install

%files
%license LICENSE
%{_libdir}/libwlroots-*.so.*

%files devel
%{_includedir}/wlr/
%{_libdir}/libwlroots-*.so
%{_libdir}/pkgconfig/wlroots-*.pc

%changelog
* Mon Mar 10 2026 EXWM-VR Maintainers <maintainers@xoxdwm.dev> - 0.18.2-1
- Initial wlroots-beyond package
- Patch: force non_desktop for Bigscreen Beyond VR headsets
