# sway-beyond.spec — Sway built against patched wlroots-beyond
#
# Sway 1.10 compositor configured as VR host compositor for EXWM-VR.
# Built against wlroots-beyond (with Bigscreen Beyond non-desktop patch).
#
# Usage:
#   rpmbuild -bb --define "sway_version 1.10" sway-beyond.spec

%define sway_version %{?sway_version}%{!?sway_version:1.10}

Name:           sway-beyond
Version:        %{sway_version}
Release:        1%{?dist}
Summary:        Sway compositor built against wlroots-beyond for VR hosts
License:        MIT
URL:            https://github.com/swaywm/sway
Source0:        %{url}/releases/download/%{version}/sway-%{version}.tar.gz

# EXWM-VR default sway config for VR host machines
Source1:        exwm-vr-sway.conf

BuildRequires:  meson >= 0.60
BuildRequires:  ninja-build
BuildRequires:  gcc
BuildRequires:  pkgconfig
BuildRequires:  wlroots-beyond-devel >= 0.18
BuildRequires:  wayland-devel
BuildRequires:  wayland-protocols-devel
BuildRequires:  json-c-devel
BuildRequires:  pango-devel
BuildRequires:  cairo-devel
BuildRequires:  gdk-pixbuf2-devel
BuildRequires:  libinput-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  pcre2-devel
BuildRequires:  scdoc
BuildRequires:  libevdev-devel

Requires:       wlroots-beyond%{?_isa} >= 0.18
Requires:       xwayland

Provides:       sway = %{version}-%{release}
Provides:       sway%{?_isa} = %{version}-%{release}
Conflicts:      sway

%description
Sway %{version} built against wlroots-beyond (patched wlroots with Bigscreen
Beyond non-desktop detection). Intended as the host compositor for EXWM-VR
setups where sway manages the desktop monitor and offers the VR headset
via DRM lease to Monado/SteamVR.

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
%prep
%autosetup -n sway-%{version} -p1

%build
%meson -Dxwayland=enabled -Dman-pages=enabled
%meson_build

%install
%meson_install

# Install EXWM-VR sway config drop-in
install -Dpm 0644 %{SOURCE1} \
    %{buildroot}%{_sysconfdir}/sway/config.d/exwm-vr.conf

%files
%license LICENSE
%{_bindir}/sway
%{_bindir}/swaymsg
%{_bindir}/swaynag
%{_bindir}/swaybar
%dir %{_sysconfdir}/sway
%dir %{_sysconfdir}/sway/config.d
%config(noreplace) %{_sysconfdir}/sway/config.d/exwm-vr.conf
%{_datadir}/wayland-sessions/sway.desktop
%{_mandir}/man1/sway*.1*
%{_mandir}/man5/sway*.5*
%{_mandir}/man7/sway*.7*
%{_datadir}/bash-completion/completions/sway*
%{_datadir}/fish/vendor_completions.d/sway*
%{_datadir}/zsh/site-functions/_sway*

%changelog
* Mon Mar 10 2026 EXWM-VR Maintainers <maintainers@xoxdwm.dev> - 1.10-1
- Initial sway-beyond package
- Built against wlroots-beyond with Bigscreen Beyond patches
- Includes EXWM-VR sway config drop-in
