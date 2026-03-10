# RPM spec for Monado OpenXR runtime — Bigscreen Beyond configuration
# Target: Rocky Linux 10

%global monado_commit   main
%global monado_date     20260310

Name:           monado-beyond
Version:        0.0.1
Release:        1.%{monado_date}git%{?dist}
Summary:        Monado OpenXR runtime with Bigscreen Beyond support
License:        BSL-1.0
URL:            https://monado.freedesktop.org/
Source0:        https://gitlab.freedesktop.org/monado/monado/-/archive/%{monado_commit}/monado-%{monado_commit}.tar.gz

BuildRequires:  cmake >= 3.16
BuildRequires:  ninja-build
BuildRequires:  gcc-c++
BuildRequires:  eigen3-devel
BuildRequires:  glslang-devel
BuildRequires:  spirv-tools
BuildRequires:  spirv-tools-devel
BuildRequires:  vulkan-headers
BuildRequires:  vulkan-loader-devel
BuildRequires:  wayland-devel
BuildRequires:  wayland-protocols-devel
BuildRequires:  libdrm-devel
BuildRequires:  mesa-libEGL-devel
BuildRequires:  mesa-libGL-devel
BuildRequires:  mesa-vulkan-drivers
BuildRequires:  libusb1-devel
BuildRequires:  libuvc-devel
BuildRequires:  hidapi-devel
BuildRequires:  libXrandr-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  libudev-devel
BuildRequires:  pkg-config
# Optional: enable if available on Rocky 10
#BuildRequires:  opencv-devel

Requires:       vulkan-loader
Requires:       mesa-vulkan-drivers

%description
Monado is an open-source OpenXR runtime. This package builds Monado with
SteamVR Lighthouse driver support for use with the Bigscreen Beyond 2e
headset on AMD GPUs under Wayland (DRM lease via Sway).

%prep
%autosetup -n monado-%{monado_commit}

%build
%cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DXRT_BUILD_DRIVER_STEAMVR_LIGHTHOUSE=ON \
    -DXRT_FEATURE_STEAMVR_PLUGIN=ON
%cmake_build

%install
%cmake_install

# Install OpenXR active_runtime.json
install -Dm644 %{buildroot}%{_datadir}/openxr/1/openxr_monado.json \
    %{buildroot}%{_datadir}/openxr/1/openxr_monado.json 2>/dev/null || true

%post
# Grant real-time scheduling to monado-service
if [ -x %{_bindir}/monado-service ]; then
    setcap CAP_SYS_NICE=eip %{_bindir}/monado-service || true
fi

%files
%license LICENSE
%doc README.md
%{_bindir}/monado-service
%{_bindir}/monado-cli
%{_libdir}/libopenxr_monado.so*
%{_libdir}/libmonado*.so*
%{_datadir}/openxr/1/openxr_monado.json
# Include any installed cmake/pkgconfig files
%{_libdir}/pkgconfig/monado*.pc
%{_libdir}/cmake/monado*/

%changelog
* Mon Mar 10 2026 EXWM-VR <noreply@example.com> - 0.0.1-1
- Initial package: Monado with SteamVR Lighthouse for Bigscreen Beyond
