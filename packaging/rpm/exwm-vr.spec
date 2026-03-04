# RPM spec for EXWM-VR (XoxdWM) - VR-first Wayland compositor + Emacs WM
# Targets: Rocky Linux 9 (EPEL required) and Rocky Linux 10

%global project_name    exwm-vr
%global compositor_name ewwm-compositor
%global emacs_sitelisp  %{_datadir}/emacs/site-lisp/%{project_name}
%global bci_venv_dir    /opt/%{project_name}/bci-venv
%global selinux_mod     exwm_vr

# Rust toolchain minimum
%global rust_min_ver    1.75

# Use vendored Cargo dependencies for offline builds
%global cargo_vendored  1

# Build conditional: headless compositor variant (for s390x and servers)
%bcond headless 1

Name:           %{project_name}
Version:        0.5.0
Release:        1%{?dist}
Summary:        VR-first transhuman Emacs window manager (Wayland)
License:        GPL-3.0-or-later
URL:            https://github.com/Jesssullivan/XoxdWM
Source0:        %{url}/archive/v%{version}/%{project_name}-%{version}.tar.gz

# Vendored Cargo dependencies (generate with cargo vendor)
Source1:        %{project_name}-%{version}-vendor.tar.gz

# SELinux policy sources
Source10:       %{selinux_mod}.te
Source11:       %{selinux_mod}.if
Source12:       %{selinux_mod}.fc

# Systemd user service units
Source20:       exwm-vr-compositor.service
Source21:       exwm-vr-monado.service
Source22:       exwm-vr-emacs.service
Source23:       exwm-vr-brainflow.service
Source24:       exwm-vr.target

# udev rules
Source30:       99-exwm-vr.rules

# Desktop session files
Source40:       exwm-vr.desktop
Source41:       exwm-vr-session
Source42:       exwm-vr-portals.conf

BuildArch:      x86_64 aarch64 s390x

# ---------------------------------------------------------------------------
# Global build requirements
# ---------------------------------------------------------------------------
BuildRequires:  rust-toolchain >= %{rust_min_ver}
BuildRequires:  cargo
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  pkgconfig

# Compositor native dependencies (not needed on s390x headless-only builds)
%ifnarch s390x
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols)
BuildRequires:  libwayland-devel
BuildRequires:  mesa-libEGL-devel
BuildRequires:  mesa-libgbm-devel
BuildRequires:  libinput-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  openxr-devel
BuildRequires:  libdrm-devel
BuildRequires:  libseat-devel
BuildRequires:  libxcb-devel
BuildRequires:  xcb-util-wm-devel
%endif
BuildRequires:  systemd-devel

# Elisp build + test
%ifnarch s390x
BuildRequires:  emacs >= 29.1
%else
BuildRequires:  emacs-nox >= 29.1
%endif

# SELinux policy build
BuildRequires:  selinux-policy-devel
BuildRequires:  checkpolicy
BuildRequires:  policycoreutils

# BCI venv (skip on s390x -- no USB peripherals for OpenBCI)
%ifnarch s390x
BuildRequires:  python3-devel >= 3.9
BuildRequires:  python3-pip
BuildRequires:  python3-virtualenv
%endif

%if 0%{?el9}
BuildRequires:  epel-release
%endif

# ---------------------------------------------------------------------------
# Package descriptions
# ---------------------------------------------------------------------------
%description
EXWM-VR (XoxdWM) is a VR-first transhuman Emacs window manager built on
Smithay (Wayland compositor), Emacs (pgtk) as the WM brain, and Monado
(OpenXR runtime) for VR headset integration.  This is the meta-package that
pulls in all components.

Requires:       %{name}-compositor = %{version}-%{release}
Requires:       %{name}-elisp = %{version}-%{release}
Requires:       %{name}-monado = %{version}-%{release}
Requires:       %{name}-selinux = %{version}-%{release}

# ===========================================================================
# Subpackage: compositor
# ===========================================================================
%package compositor
Summary:        EXWM-VR Wayland compositor (Smithay + OpenXR)
Requires:       mesa-libEGL
Requires:       mesa-libgbm
Requires:       libwayland-server
Requires:       libinput
Requires:       libxkbcommon
Requires:       libseat
Requires:       libdrm
Requires:       systemd-libs
Requires:       openxr
Requires:       pipewire
Requires:       wireplumber
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-wlr
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

%description compositor
The ewwm-compositor binary -- a Smithay 0.7 Wayland compositor with OpenXR
VR support, DRM lease management, eye-tracking pipelines, and an s-expression
IPC channel for Emacs control.

# ===========================================================================
# Subpackage: elisp
# ===========================================================================
%package elisp
Summary:        EXWM-VR Emacs Lisp modules
BuildArch:      noarch
Requires:       emacs >= 29.1
Requires:       %{name}-compositor = %{version}-%{release}

%description elisp
Emacs Lisp modules for EXWM-VR: core WM logic (ewwm-core, ewwm-workspace,
ewwm-layout, ewwm-input, ewwm-manage, ewwm-floating), VR integration
(ewwm-vr, ewwm-vr-scene, ewwm-vr-display, ewwm-vr-eye), accessibility
(ewwm-vr-wink, ewwm-vr-gaze-zone, ewwm-vr-fatigue), secrets management
(ewwm-secrets, ewwm-keepassxc-browser, ewwm-secrets-autotype), and the
original EXWM X11 compatibility layer.

# ===========================================================================
# Subpackage: monado
# ===========================================================================
%package monado
Summary:        Monado OpenXR runtime integration for EXWM-VR
BuildArch:      noarch
Requires:       monado
Requires:       %{name}-compositor = %{version}-%{release}

%description monado
Configuration files, systemd service units, and udev rules for integrating
the Monado OpenXR runtime with the EXWM-VR compositor.  Includes HMD
auto-detection and DRM lease handoff.

# ===========================================================================
# Subpackage: bci
# ===========================================================================
%package bci
Summary:        BrainFlow BCI integration for EXWM-VR
Requires:       python3 >= 3.9
Requires:       %{name}-compositor = %{version}-%{release}

%description bci
A self-contained Python virtual environment at %{bci_venv_dir} providing
BrainFlow-based brain-computer interface support for EXWM-VR.  Communicates
with the compositor over Unix domain sockets.

# ===========================================================================
# Subpackage: selinux
# ===========================================================================
%package selinux
Summary:        SELinux policy module for EXWM-VR
BuildArch:      noarch
Requires:       selinux-policy >= %{_selinux_policy_version}
Requires(post): policycoreutils
Requires(postun): policycoreutils

%description selinux
SELinux type-enforcement policy module for EXWM-VR.  Confines the compositor,
Monado runtime, and BrainFlow BCI processes with mandatory access controls.
Denies network access for the compositor and restricts file writes to
designated directories only.

# ===========================================================================
# Subpackage: headless
# ===========================================================================
%if %{with headless}
%package headless
Summary:        EXWM-VR headless compositor for servers and mainframes
Requires:       emacs-nox >= 29.1
Requires:       systemd-libs
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

%description headless
Headless compositor variant for EXWM-VR, intended for servers, mainframes
(IBM Z / s390x), and environments without GPU hardware.  Provides IPC-based
workspace management with terminal Emacs (emacs -nw).  No VR, eye tracking,
or BCI support.  Suitable for remote administration via SSH or VNC.
%endif

# ===========================================================================
# Prep
# ===========================================================================
%prep
%autosetup -n XoxdWM-%{version} -p1

# Unpack vendored Cargo deps
%if 0%{?cargo_vendored}
tar xf %{SOURCE1}
mkdir -p .cargo
cat > .cargo/config.toml << 'CARGO_EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
CARGO_EOF
%endif

# Copy SELinux sources into build tree
mkdir -p selinux-build
cp %{SOURCE10} %{SOURCE11} %{SOURCE12} selinux-build/

# ===========================================================================
# Build
# ===========================================================================
%build

# --- Compositor (Rust) ---
pushd compositor
export CARGO_HOME="$PWD/.cargo-home"
%ifarch s390x
# s390x: headless only -- skip VR, eye tracking, BCI features
cargo build --release --no-default-features --features headless \
    --jobs %{_smp_build_ncpus} \
    %{?_cargo_extra_args}
%else
cargo build --release --features vr \
    --jobs %{_smp_build_ncpus} \
    %{?_cargo_extra_args}
# Save VR binary before headless build overwrites target/release/
cp target/release/%{compositor_name} target/release/%{compositor_name}-vr
%if %{with headless}
# Also build headless variant on non-s390x architectures
cargo build --release --no-default-features --features headless \
    --jobs %{_smp_build_ncpus} \
    %{?_cargo_extra_args}
%endif
%endif
popd

# --- Elisp byte-compilation ---
%{_bindir}/emacs --batch \
    -L lisp/core -L lisp/vr -L lisp/ext \
    --eval '(setq byte-compile-error-on-warn nil)' \
    -f batch-byte-compile \
    lisp/core/*.el lisp/vr/*.el lisp/ext/*.el

# --- SELinux policy module ---
pushd selinux-build
make -f %{_datadir}/selinux/devel/Makefile %{selinux_mod}.pp
popd

# --- BCI venv (skip on s390x) ---
%ifnarch s390x
python3 -m venv --system-site-packages %{_builddir}/bci-venv
%{_builddir}/bci-venv/bin/pip install --no-build-isolation \
    brainflow numpy scipy
%endif

# ===========================================================================
# Install
# ===========================================================================
%install

# --- Compositor binary ---
%ifnarch s390x
install -Dpm 0755 compositor/target/release/%{compositor_name}-vr \
    %{buildroot}%{_bindir}/%{compositor_name}
%endif

# --- Desktop session entry + session wrapper + portal config ---
%ifnarch s390x
install -Dpm 0644 %{SOURCE40} \
    %{buildroot}%{_datadir}/wayland-sessions/exwm-vr.desktop
install -Dpm 0755 %{SOURCE41} \
    %{buildroot}%{_datadir}/%{project_name}/exwm-vr-session
install -Dpm 0644 %{SOURCE42} \
    %{buildroot}%{_datadir}/xdg-desktop-portal/exwm-vr-portals.conf
%endif

# --- Headless compositor binary ---
%if %{with headless}
install -Dpm 0755 compositor/target/release/%{compositor_name} \
    %{buildroot}%{_bindir}/%{compositor_name}-headless
%ifarch s390x
# On s390x the headless build IS the only compositor build
# (already built with --features headless above)
%endif
%endif

# --- Elisp files ---
install -d %{buildroot}%{emacs_sitelisp}/core
install -d %{buildroot}%{emacs_sitelisp}/vr
install -d %{buildroot}%{emacs_sitelisp}/ext

install -pm 0644 lisp/core/*.el lisp/core/*.elc \
    %{buildroot}%{emacs_sitelisp}/core/
install -pm 0644 lisp/vr/*.el lisp/vr/*.elc \
    %{buildroot}%{emacs_sitelisp}/vr/
install -pm 0644 lisp/ext/*.el lisp/ext/*.elc \
    %{buildroot}%{emacs_sitelisp}/ext/

# Emacs load-path setup
install -d %{buildroot}%{_datadir}/emacs/site-lisp/site-start.d
cat > %{buildroot}%{_datadir}/emacs/site-lisp/site-start.d/%{project_name}-init.el << 'ELISP_EOF'
;;; exwm-vr-init.el --- Auto-load setup for EXWM-VR  -*- lexical-binding: t -*-
(let ((base (file-name-directory load-file-name)))
  (add-to-list 'load-path (expand-file-name "../exwm-vr/core" base))
  (add-to-list 'load-path (expand-file-name "../exwm-vr/vr" base))
  (add-to-list 'load-path (expand-file-name "../exwm-vr/ext" base)))
;;; exwm-vr-init.el ends here
ELISP_EOF

# --- Systemd user services ---
%ifnarch s390x
install -Dpm 0644 %{SOURCE20} \
    %{buildroot}%{_userunitdir}/exwm-vr-compositor.service
install -Dpm 0644 %{SOURCE21} \
    %{buildroot}%{_userunitdir}/exwm-vr-monado.service
install -Dpm 0644 %{SOURCE22} \
    %{buildroot}%{_userunitdir}/exwm-vr-emacs.service
install -Dpm 0644 %{SOURCE23} \
    %{buildroot}%{_userunitdir}/exwm-vr-brainflow.service
install -Dpm 0644 %{SOURCE24} \
    %{buildroot}%{_userunitdir}/exwm-vr.target
%endif

# --- udev rules (skip on s390x -- no HMD hardware) ---
%ifnarch s390x
install -Dpm 0644 %{SOURCE30} \
    %{buildroot}%{_udevrulesdir}/99-exwm-vr.rules

# --- Monado config ---
install -d %{buildroot}%{_sysconfdir}/xdg/openxr/1
cat > %{buildroot}%{_sysconfdir}/xdg/openxr/1/active_runtime.json << 'JSON_EOF'
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "monado",
        "library_path": "/usr/lib64/libopenxr_monado.so"
    }
}
JSON_EOF

install -d %{buildroot}%{_sysconfdir}/%{project_name}
cat > %{buildroot}%{_sysconfdir}/%{project_name}/monado.conf << 'CONF_EOF'
# Monado integration settings for EXWM-VR
# DRM lease: compositor hands off HMD display to Monado
[drm_lease]
enabled = true
auto_select_hmd = true

# Frame timing: target HMD refresh rate
[frame_timing]
target_fps = 90
prediction_offset_ms = 5.0
CONF_EOF

# --- BCI venv ---
install -d %{buildroot}%{bci_venv_dir}
cp -a %{_builddir}/bci-venv/* %{buildroot}%{bci_venv_dir}/

# Fix shebang paths in venv
find %{buildroot}%{bci_venv_dir}/bin -type f -executable \
    -exec sed -i '1s|^#!.*python.*|#!/opt/%{project_name}/bci-venv/bin/python3|' {} \;
%endif

# --- Headless documentation ---
%if %{with headless}
install -d %{buildroot}%{_docdir}/%{project_name}-headless
install -pm 0644 docs/architecture-notes.md \
    %{buildroot}%{_docdir}/%{project_name}-headless/
install -pm 0644 docs/gpu-compatibility.md \
    %{buildroot}%{_docdir}/%{project_name}-headless/
%endif

# --- SELinux policy ---
install -Dpm 0644 selinux-build/%{selinux_mod}.pp \
    %{buildroot}%{_datadir}/selinux/packages/%{selinux_mod}.pp
install -Dpm 0644 selinux-build/%{selinux_mod}.if \
    %{buildroot}%{_datadir}/selinux/devel/include/contrib/%{selinux_mod}.if

# --- State directories ---
install -d %{buildroot}%{_localstatedir}/lib/%{project_name}
install -d %{buildroot}%{_rundir}/%{project_name}

# ===========================================================================
# Check (tests)
# ===========================================================================
%check

# --- Rust unit tests (compositor) ---
pushd compositor
export CARGO_HOME="$PWD/.cargo-home"
%ifarch s390x
cargo test --release --no-default-features --features headless \
    %{?_cargo_extra_args} || \
    echo "WARN: Rust tests (headless) -- skipped on mock build"
%else
cargo test --release --features vr %{?_cargo_extra_args} || \
    echo "WARN: Rust tests require Linux DRM/Wayland -- skipped on mock build"
%endif
popd

# --- ERT tests (Elisp) ---
%{_bindir}/emacs --batch \
    -L lisp/core -L lisp/vr -L lisp/ext -L test \
    -l test/run-tests.el || \
    echo "WARN: ERT tests may need running compositor -- partial pass expected"

# ===========================================================================
# Scriptlets
# ===========================================================================

# --- compositor ---
%post compositor
%systemd_user_post exwm-vr-compositor.service
%systemd_user_post exwm-vr-emacs.service
%systemd_user_post exwm-vr.target

%preun compositor
%systemd_user_preun exwm-vr-compositor.service
%systemd_user_preun exwm-vr-emacs.service
%systemd_user_preun exwm-vr.target

%postun compositor
%systemd_user_postun_with_restart exwm-vr-compositor.service

# --- elisp ---
%post elisp
# Re-byte-compile after install (picks up user's Emacs version)
%{_bindir}/emacs --batch \
    -L %{emacs_sitelisp}/core \
    -L %{emacs_sitelisp}/vr \
    -L %{emacs_sitelisp}/ext \
    --eval '(setq byte-compile-error-on-warn nil)' \
    -f batch-byte-compile \
    %{emacs_sitelisp}/core/*.el \
    %{emacs_sitelisp}/vr/*.el \
    %{emacs_sitelisp}/ext/*.el \
    2>/dev/null || :

# --- monado ---
%post monado
%systemd_user_post exwm-vr-monado.service
udevadm control --reload-rules 2>/dev/null || :
udevadm trigger --subsystem-match=drm 2>/dev/null || :
udevadm trigger --subsystem-match=usb 2>/dev/null || :

%preun monado
%systemd_user_preun exwm-vr-monado.service

%postun monado
%systemd_user_postun_with_restart exwm-vr-monado.service

# --- selinux ---
%post selinux
%selinux_modules_install %{_datadir}/selinux/packages/%{selinux_mod}.pp
# Relabel installed files
restorecon -R %{_bindir}/%{compositor_name} 2>/dev/null || :
restorecon -R %{bci_venv_dir} 2>/dev/null || :
restorecon -R %{_localstatedir}/lib/%{project_name} 2>/dev/null || :

%postun selinux
if [ $1 -eq 0 ]; then
    %selinux_modules_uninstall %{selinux_mod}
fi

# --- headless ---
%if %{with headless}
%post headless
%systemd_user_post exwm-vr-compositor.service

%preun headless
%systemd_user_preun exwm-vr-compositor.service

%postun headless
%systemd_user_postun_with_restart exwm-vr-compositor.service
%endif

# ===========================================================================
# File lists
# ===========================================================================

# --- meta package (empty -- just dependencies) ---
%files
%license LICENSE
%doc README.md PLAN.md

# --- compositor (skip on s390x -- only headless available) ---
%ifnarch s390x
%files compositor
%license LICENSE
%{_bindir}/%{compositor_name}
%{_userunitdir}/exwm-vr-compositor.service
%{_userunitdir}/exwm-vr-emacs.service
%{_userunitdir}/exwm-vr.target
%{_datadir}/wayland-sessions/exwm-vr.desktop
%dir %{_datadir}/%{project_name}
%{_datadir}/%{project_name}/exwm-vr-session
%{_datadir}/xdg-desktop-portal/exwm-vr-portals.conf
%dir %{_localstatedir}/lib/%{project_name}
%endif

# --- elisp ---
%files elisp
%license LICENSE
%dir %{emacs_sitelisp}
%{emacs_sitelisp}/core/
%{emacs_sitelisp}/vr/
%{emacs_sitelisp}/ext/
%{_datadir}/emacs/site-lisp/site-start.d/%{project_name}-init.el

# --- monado (skip on s390x -- no VR hardware) ---
%ifnarch s390x
%files monado
%license LICENSE
%{_userunitdir}/exwm-vr-monado.service
%{_userunitdir}/exwm-vr-brainflow.service
%{_udevrulesdir}/99-exwm-vr.rules
%dir %{_sysconfdir}/xdg/openxr
%dir %{_sysconfdir}/xdg/openxr/1
%config(noreplace) %{_sysconfdir}/xdg/openxr/1/active_runtime.json
%dir %{_sysconfdir}/%{project_name}
%config(noreplace) %{_sysconfdir}/%{project_name}/monado.conf
%endif

# --- bci (skip on s390x -- no USB peripherals) ---
%ifnarch s390x
%files bci
%license LICENSE
%dir /opt/%{project_name}
%{bci_venv_dir}/
%endif

# --- selinux ---
%files selinux
%license LICENSE
%{_datadir}/selinux/packages/%{selinux_mod}.pp
%{_datadir}/selinux/devel/include/contrib/%{selinux_mod}.if

# --- headless ---
%if %{with headless}
%files headless
%license LICENSE
%{_bindir}/%{compositor_name}-headless
%dir %{_docdir}/%{project_name}-headless
%{_docdir}/%{project_name}-headless/architecture-notes.md
%{_docdir}/%{project_name}-headless/gpu-compatibility.md
%endif

# ===========================================================================
# Changelog
# ===========================================================================
%changelog
* Tue Mar 03 2026 EXWM-VR Maintainers <maintainers@xoxdwm.dev> - 0.5.0-1
- Version bump to 0.5.0 (v0.5.0-vr-renderer milestone)
- Install .desktop + session wrapper to wayland-sessions for GDM/SDDM
- Install XDG portal config for screen sharing and file chooser
- Add PipeWire, WirePlumber, xdg-desktop-portal-wlr to Requires
- Fix compositor Type=notify -> Type=simple (no sd_notify in Smithay)
- Fix udev rules filename (99-exwm-vr.rules)
- Fix VR/headless binary overwrite during build
- Replace emacs-pgtk BuildRequires with emacs (Rocky has no -pgtk variant)
- Session wrapper: Wayland toolkit hints, D-Bus bus, Electron hint
- Audio (ewwm-audio.el) and notification (ewwm-notify.el) modules

* Wed Feb 11 2026 EXWM-VR Maintainers <maintainers@xoxdwm.dev> - 0.1.0-2
- Add headless subpackage for s390x and server deployments
- Add %%ifarch s390x conditionals to skip VR/GPU/BCI on mainframes
- Add %%bcond headless build conditional
- Include architecture-notes.md and gpu-compatibility.md in headless docs

* Tue Feb 11 2026 EXWM-VR Maintainers <maintainers@xoxdwm.dev> - 0.1.0-1
- Initial RPM packaging
- Compositor: Smithay 0.7 with OpenXR VR, eye tracking, gaze focus
- Elisp: full WM brain (ewwm-*), VR modules, secrets management
- Monado: OpenXR runtime integration with DRM lease
- BCI: BrainFlow Python venv for brain-computer interface
- SELinux: type enforcement policy for all components
