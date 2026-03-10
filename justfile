# EXWM-VR task runner
# https://just.systems

set dotenv-load

project_root := justfile_directory()
core_el := `find lisp/core -name '*.el' -not -name '*-pkg.el' -not -name '*-autoloads.el' 2>/dev/null | sort`
vr_el := `find lisp/vr -name '*.el' 2>/dev/null | sort`
ext_el := `find lisp/ext -name '*.el' 2>/dev/null | sort`
all_el := core_el + " " + vr_el + " " + ext_el
load_flags := "-L " + project_root + "/lisp/core -L " + project_root + "/lisp/vr -L " + project_root + "/lisp/ext"

# ── build ──────────────────────────────────────────────

[group('build')]
build:
    @echo "Byte-compiling Elisp..."
    emacs --batch \
        {{load_flags}} \
        --eval '(setq byte-compile-error-on-warn nil)' \
        -f batch-byte-compile {{all_el}}
    @echo "Done."

[group('build')]
build-compositor:
    @echo "Building compositor (Rust)..."
    cargo build --manifest-path "{{project_root}}/compositor/Cargo.toml"

[group('build')]
build-all: build build-compositor

# ── test ───────────────────────────────────────────────

[group('test')]
test:
    @echo "Running ERT tests..."
    emacs --batch \
        {{load_flags}} \
        -l "{{project_root}}/test/run-tests.el"

[group('test')]
test-compositor:
    @echo "Running compositor tests..."
    cargo test --manifest-path "{{project_root}}/compositor/Cargo.toml"

[group('test')]
test-integration:
    @echo "Running integration tests..."
    emacs --batch \
        {{load_flags}} \
        -l "{{project_root}}/test/run-tests.el" \
        --eval '(ert-run-tests-batch-and-exit "week.*-integration")'

[group('test')]
test-all: test test-compositor test-integration

# ── lint ───────────────────────────────────────────────

[group('lint')]
lint-elisp:
    @echo "Linting Elisp..."
    emacs --batch \
        {{load_flags}} \
        --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile {{all_el}}

[group('lint')]
lint-rust:
    @echo "Linting Rust..."
    cargo clippy --manifest-path "{{project_root}}/compositor/Cargo.toml" -- -D warnings

[group('lint')]
lint-all: lint-elisp lint-rust

# ── vr ─────────────────────────────────────────────────

[group('vr')]
vr-mock:
    @echo "Launching compositor with Monado headless..."
    XRT_COMPOSITOR_FORCE_HEADLESS=1 \
        cargo run --manifest-path "{{project_root}}/compositor/Cargo.toml"

[group('vr')]
vr-test:
    @echo "Running VR integration tests..."
    XRT_COMPOSITOR_FORCE_HEADLESS=1 \
        cargo test --manifest-path "{{project_root}}/compositor/Cargo.toml" \
        -- --test-threads=1 vr_

[group('vr')]
vr-preflight:
    @echo "VR hardware preflight checks..."
    @echo "=== GPU ==="
    @test -e /dev/dri/card0 && echo "  /dev/dri/card0: OK" || echo "  /dev/dri/card0: MISSING"
    @test -e /dev/dri/renderD128 && echo "  /dev/dri/renderD128: OK" || echo "  /dev/dri/renderD128: MISSING"
    @echo "=== HMD USB ==="
    @lsusb 2>/dev/null | grep -i "bigscreen\|beyond\|valve\|htc\|oculus\|meta" || echo "  No known HMD detected via USB"
    @echo "=== Monado ==="
    @monado-cli probe 2>&1 && echo "  Monado: OK" || echo "  Monado: probe failed"
    @echo "=== Vulkan ==="
    @vulkaninfo --summary 2>&1 | head -10 || echo "  vulkaninfo not available"

[group('vr')]
vr-drm-info:
    @echo "DRM connector info..."
    @for card in /dev/dri/card*; do \
        echo "=== $card ==="; \
        drm_info "$card" 2>/dev/null || \
        for conn in /sys/class/drm/$(basename "$card")-*/; do \
            echo "  $(basename $conn): status=$(cat $conn/status 2>/dev/null) non_desktop=$(cat $conn/non_desktop 2>/dev/null)"; \
        done; \
    done

[group('vr')]
vr-hardware-test suite="smoke":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Running VR hardware test suite: {{suite}}..."
    case "{{suite}}" in
    smoke)
        echo "--- Smoke test: build + basic GPU tests ---"
        cargo test --manifest-path "{{project_root}}/compositor/Cargo.toml" \
            --features full-backend,vr
        ;;
    drm-lease)
        echo "--- DRM lease tests ---"
        cargo test --manifest-path "{{project_root}}/compositor/Cargo.toml" \
            --features full-backend,vr -- --test-threads=1 drm_lease
        ;;
    full)
        echo "--- Full VR hardware test suite ---"
        cargo test --manifest-path "{{project_root}}/compositor/Cargo.toml" \
            --features full-backend,vr -- --test-threads=1
        ;;
    *)
        echo "Unknown suite: {{suite}} (use smoke, drm-lease, or full)"
        exit 1
        ;;
    esac

[group('vr')]
vr-benchmark-gpu:
    @echo "Running GPU benchmark suite..."
    cargo bench --manifest-path "{{project_root}}/compositor/Cargo.toml" \
        --features full-backend,vr 2>&1 | tee benchmark-results/gpu-bench.txt || \
    cargo test --manifest-path "{{project_root}}/compositor/Cargo.toml" \
        --features full-backend,vr -- --test-threads=1 benchmark

# ── beyond / remote setup ─────────────────────────────

setup_script := project_root + "/packaging/scripts/exwm-vr-setup"

# Deploy the unified setup script to a remote host, then run a command.
# Usage: just beyond-remote <host> <command>
#   just beyond-remote honey prereqs     — install groups + udev (sudo)
#   just beyond-remote honey verify      — check display, USB, permissions
#   just beyond-remote honey beyond-status
[group('vr')]
beyond-remote host command:
    @echo "=== {{host}}: {{command}} ==="
    scp -q "{{setup_script}}" "{{project_root}}/packaging/udev/99-exwm-vr.rules" "{{project_root}}/packaging/scripts/beyond-power-on" "{{project_root}}/packaging/systemd/exwm-vr-beyond-power.service" "{{project_root}}/packaging/sway/config" "{{project_root}}/packaging/sway/status.sh" "{{project_root}}/patches/wlroots-bigscreen-non-desktop.patch" "{{project_root}}/patches/amd-bsb-dsc-fix.patch" "{{project_root}}/patches/bigscreen-beyond-edid.patch" jess@{{host}}:/tmp/
    ssh jess@{{host}} "chmod +x /tmp/exwm-vr-setup /tmp/beyond-power-on && mv -f /tmp/config /tmp/exwm-sway-config 2>/dev/null; mv -f /tmp/status.sh /tmp/exwm-sway-status.sh 2>/dev/null; /tmp/exwm-vr-setup {{command}}"

# Same as beyond-remote but wraps in sudo (prompts for password).
[group('vr')]
beyond-remote-sudo host command:
    @echo "=== {{host}}: sudo {{command}} ==="
    scp -q "{{setup_script}}" "{{project_root}}/packaging/udev/99-exwm-vr.rules" "{{project_root}}/packaging/scripts/beyond-power-on" "{{project_root}}/packaging/systemd/exwm-vr-beyond-power.service" "{{project_root}}/packaging/sway/config" "{{project_root}}/packaging/sway/status.sh" "{{project_root}}/patches/wlroots-bigscreen-non-desktop.patch" "{{project_root}}/patches/amd-bsb-dsc-fix.patch" "{{project_root}}/patches/bigscreen-beyond-edid.patch" jess@{{host}}:/tmp/
    ssh jess@{{host}} "chmod +x /tmp/exwm-vr-setup /tmp/beyond-power-on && mv -f /tmp/config /tmp/exwm-sway-config 2>/dev/null; mv -f /tmp/status.sh /tmp/exwm-sway-status.sh 2>/dev/null; echo 'Running with sudo...' && sudo /tmp/exwm-vr-setup {{command}}"

# Shorthand aliases for common operations
[group('vr')]
beyond-status host="honey":
    just beyond-remote {{host}} beyond-status

[group('vr')]
beyond-verify host="honey":
    just beyond-remote {{host}} verify

[group('vr')]
beyond-hid-test host="honey":
    just beyond-remote {{host}} beyond-hid-test

[group('vr')]
beyond-setup host="honey":
    @echo "Full setup on {{host}} (sudo required)..."
    just beyond-remote-sudo {{host}} full-setup

[group('vr')]
beyond-gpu-tools host="honey":
    @echo "Installing GPU tools on {{host}} (sudo required)..."
    just beyond-remote-sudo {{host}} gpu-tools

[group('vr')]
beyond-display-init host="honey":
    @echo "Beyond display init on {{host}} (sudo required)..."
    just beyond-remote-sudo {{host}} beyond-display-init

[group('vr')]
beyond-power-on host="honey" *args="":
    @echo "Sending Beyond power-on on {{host}}..."
    just beyond-remote {{host}} beyond-power-on {{args}}

[group('vr')]
beyond-sway-setup host="honey":
    @echo "Building sway host compositor on {{host}} (sudo required)..."
    just beyond-remote-sudo {{host}} sway-setup

[group('vr')]
beyond-steam-setup host="honey":
    @echo "Installing native Steam on {{host}} (sudo required)..."
    just beyond-remote-sudo {{host}} steam-setup

[group('vr')]
beyond-monado-setup host="honey":
    @echo "Building Monado on {{host}} (sudo required)..."
    just beyond-remote-sudo {{host}} monado-setup

[group('vr')]
beyond-first-frame host="honey":
    @echo "Testing first frame on {{host}}..."
    just beyond-remote {{host}} beyond-first-frame

[group('vr')]
beyond-openxr-build host="honey":
    @echo "Building hello_xr on {{host}}..."
    just beyond-remote {{host}} openxr-build

[group('vr')]
beyond-download-config host="honey":
    @echo "Downloading Beyond calibration config on {{host}}..."
    just beyond-remote {{host}} beyond-download-config

[group('vr')]
beyond-oobe host="honey":
    @echo "Running full OOBE on {{host}}..."
    just beyond-remote {{host}} beyond-oobe

[group('vr')]
beyond-kernel-dsc-fix host="honey":
    @echo "Patching amdgpu DSC QP tables on {{host}} (sudo required)..."
    just beyond-remote-sudo {{host}} kernel-dsc-fix

# Build XR kernel from source with all patches on remote host.
# Optionally pass kernel version: just beyond-kernel-build honey 6.19.5
[group('vr')]
beyond-kernel-build host="honey" *args="":
    @echo "Building XR kernel on {{host}} (sudo required, takes ~30min)..."
    scp -q "{{setup_script}}" "{{project_root}}/patches/bigscreen-beyond-edid.patch" "{{project_root}}/patches/0007-vesa-dsc-bpp.patch" jess@{{host}}:/tmp/
    ssh jess@{{host}} "chmod +x /tmp/exwm-vr-setup && sudo /tmp/exwm-vr-setup kernel-build {{args}}"

# ── deploy ────────────────────────────────────────────

# Deploy all components to a host
# Usage: just deploy honey [components]
# Components: kernel, compositor, sway, monado, all (default: all)
[group('deploy')]
deploy host="honey" components="all":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Deploying to {{host}} ==="

    if [[ "{{components}}" == "all" || "{{components}}" == *"kernel"* ]]; then
        echo ">>> Checking kernel..."
        LATEST=$(gh release view -R Jesssullivan/linux-xr --json tagName -q .tagName 2>/dev/null || echo "none")
        echo "    Latest kernel release: ${LATEST}"
    fi

    if [[ "{{components}}" == "all" || "{{components}}" == *"compositor"* ]]; then
        echo ">>> Building compositor..."
        nix build .#compositor --out-link result-compositor
        echo ">>> Copying to {{host}}..."
        nix copy --to ssh://jess@{{host}} ./result-compositor
    fi

    if [[ "{{components}}" == "all" || "{{components}}" == *"sway"* ]]; then
        echo ">>> Building sway..."
        nix build .#sway-beyond --out-link result-sway
        echo ">>> Copying to {{host}}..."
        nix copy --to ssh://jess@{{host}} ./result-sway
    fi

    echo ">>> Running verification..."
    just deploy-verify {{host}}

# Post-deploy verification
[group('deploy')]
deploy-verify host="honey":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Verifying deployment on {{host}} ==="
    ssh jess@{{host}} bash -s <<'VERIFY'
    echo "Kernel: $(uname -r)"
    echo "Sway: $(sway --version 2>/dev/null || echo 'not found')"
    echo "Monado: $(monado-cli version 2>/dev/null || echo 'not found')"
    echo "GPU: $(lspci | grep -i vga | head -1)"
    echo "DRM: $(ls /dev/dri/card* 2>/dev/null | tr '\n' ' ')"
    echo "Beyond USB: $(lsusb -d 35bd: 2>/dev/null || echo 'not connected')"
    echo "non_desktop: $(cat /sys/class/drm/card*/DP-*/non_desktop 2>/dev/null | head -1 || echo 'N/A')"
    VERIFY

# ── kernel (linux-xr) ─────────────────────────────────

linux_xr_repo := "Jesssullivan/linux-xr"

# Download + install latest XR kernel RPM on remote host.
# Usage: just beyond-kernel-install honey v6.19.5-xr1
[group('vr')]
beyond-kernel-install host tag:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Installing kernel-xr {{tag}} on {{host}} ==="
    gh release download "{{tag}}" -R "{{linux_xr_repo}}" \
        -p "kernel-xr-*.x86_64.rpm" -D /tmp/kernel-xr-rpms/ --clobber
    scp /tmp/kernel-xr-rpms/kernel-xr-*.x86_64.rpm jess@{{host}}:/tmp/
    ssh jess@{{host}} "sudo dnf install -y /tmp/kernel-xr-*.x86_64.rpm"
    echo "Installed. Reboot {{host}} to activate."

# Trigger linux-xr CI rebuild (when patches change).
[group('vr')]
beyond-kernel-trigger kversion="6.19.5" xr_release="1" rt_version="6.19.3-rt1":
    gh workflow run build-kernel.yml -R "{{linux_xr_repo}}" \
        -f kernel_version="{{kversion}}" \
        -f xr_release="{{xr_release}}" \
        -f rt_version="{{rt_version}}"
    @echo "Triggered. Watch: gh run list -R {{linux_xr_repo}}"

# Verify XR kernel install on remote host.
[group('vr')]
beyond-kernel-verify host="honey":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Kernel verification on {{host}} ==="
    ssh jess@{{host}} "uname -r && zcat /proc/config.gz 2>/dev/null | grep -E 'HZ=|PREEMPT_RT|DRM_AMD_DC_DSC|USB_HIDDEV' || grep -E 'HZ=|PREEMPT_RT|DRM_AMD_DC_DSC|USB_HIDDEV' /boot/config-\$(uname -r)"

# Dump DSC PPS from debugfs and verify QP/RC fix is active.
# Requires Beyond to be connected and display active on DP-2.
[group('vr')]
beyond-kernel-pps host="honey" connector="DP-2":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== DSC PPS dump from {{host}} ({{connector}}) ==="
    PPS=$(ssh jess@{{host}} "sudo cat /sys/kernel/debug/dri/1/{{connector}}/dsc_pic_parameter_set 2>/dev/null || echo 'NOT_FOUND'")
    if [ "$PPS" = "NOT_FOUND" ]; then
        echo "PPS not available — is DSC active on {{connector}}?"
        echo "Try: ssh jess@{{host}} 'ls /sys/kernel/debug/dri/*/'"
        exit 1
    fi
    echo "$PPS"
    echo ""
    echo "=== QP/RC fix verification ==="
    echo "Check rc_range_params bytes 77-87 against expected patched values:"
    echo "  PPS[77]=0x83 PPS[79]=0xC5 PPS[80]=0xA3 PPS[81]=0x05"
    echo "  PPS[82]=0xA3 PPS[83]=0x45 PPS[85]=0x47 PPS[87]=0xCD"

# ── dev ────────────────────────────────────────────────

[group('dev')]
dev:
    @echo "Launching Emacs with EXWM-VR load path..."
    emacs {{load_flags}} --eval '(require (quote exwm))'

[group('dev')]
clean:
    @echo "Cleaning build artifacts..."
    rm -f "{{project_root}}"/lisp/core/*.elc
    rm -f "{{project_root}}"/lisp/vr/*.elc
    rm -f "{{project_root}}"/lisp/ext/*.elc
    rm -rf "{{project_root}}/compositor/target"
    @echo "Done."

[group('dev')]
changelog:
    git-cliff --output "{{project_root}}/CHANGELOG.md"

[group('dev')]
changelog-unreleased:
    git-cliff --unreleased

# ── benchmark ──────────────────────────────────────────

[group('benchmark')]
benchmark:
    @echo "Running EWWM benchmark suite..."
    emacs --batch \
        {{load_flags}} \
        -l ewwm-benchmark \
        --eval '(ewwm-benchmark-run-all)'

[group('benchmark')]
benchmark-report:
    @echo "Generating benchmark report..."
    emacs --batch \
        {{load_flags}} \
        -l ewwm-benchmark \
        --eval '(progn (ewwm-benchmark-run-all) (princ (ewwm-benchmark-report)))'

# ── security ──────────────────────────────────────────

[group('security')]
security-check:
    @echo "Running security verification checks..."
    @echo "  Checking IPC socket permissions..."
    @test -z "${XDG_RUNTIME_DIR:-}" || ls -la "${XDG_RUNTIME_DIR}"/ewwm-ipc.sock 2>/dev/null || echo "  IPC socket not found (compositor not running)"
    @echo "  Checking for network listeners..."
    @ss -tlnp 2>/dev/null | grep -E 'ewwm|compositor' || echo "  No network listeners found (good)"
    @echo "  Checking SELinux policy..."
    @test -f "{{project_root}}/packaging/selinux/exwm-vr.te" && echo "  SELinux policy present" || echo "  SELinux policy missing"
    @echo "  Checking FIPS compliance doc..."
    @test -f "{{project_root}}/docs/fips-compliance.md" && echo "  FIPS compliance doc present" || echo "  FIPS compliance doc missing"
    @echo "  Checking secure input module..."
    @test -f "{{project_root}}/lisp/vr/ewwm-vr-secure-input.el" && echo "  Secure input module present" || echo "  Secure input module missing"
    @echo "Security checks complete."

[group('security')]
audit:
    @echo "EXWM-VR Security Audit Report"
    @echo "=============================="
    @cat "{{project_root}}/docs/security-audit-v0.1.0.md"

# ── release ────────────────────────────────────────────

[group('release')]
release-check: test test-compositor
    @echo "Release checks passed."

[group('release')]
release tag="v0.5.0":
    @echo "Preparing release {{tag}}..."
    git-cliff --tag "{{tag}}" --output "{{project_root}}/CHANGELOG.md"
    @echo "CHANGELOG.md updated."
    @echo "Tag with: git tag -a {{tag}} -m 'Release {{tag}}'"
    @echo "Push with: git push origin {{tag}}"

[group('release')]
release-notes:
    @echo "## Release Notes"
    @echo ""
    git-cliff --unreleased --strip header

# ── ci ─────────────────────────────────────────────────

[group('ci')]
ci: lint-elisp build test
    @echo "CI passed."

# ── nix ────────────────────────────────────────────────

[group('nix')]
nix-build:
    @echo "Building compositor via Nix..."
    nix build .#compositor

[group('nix')]
nix-build-headless:
    @echo "Building headless compositor via Nix..."
    nix build .#compositor-headless

[group('nix')]
nix-build-elisp:
    @echo "Building ewwm-elisp package via Nix..."
    nix build .#ewwm-elisp

[group('nix')]
nix-check:
    @echo "Running nix flake check..."
    nix flake check

[group('nix')]
nix-test-boot:
    @echo "Running NixOS boot-test VM..."
    nix build .#checks.x86_64-linux.boot-test -L

[group('nix')]
nix-test-full:
    @echo "Running NixOS full-stack-test VM..."
    nix build .#checks.x86_64-linux.full-stack-test -L

[group('nix')]
nix-fmt:
    @echo "Formatting Nix files..."
    nixpkgs-fmt flake.nix nix/**/*.nix

# ── selinux ───────────────────────────────────────────

selinux_dir := project_root + "/packaging/selinux"
devel_mk := "/usr/share/selinux/devel/Makefile"

[group('selinux')]
selinux-build:
    @echo "Building SELinux policy modules..."
    make -C "{{selinux_dir}}" -f "{{devel_mk}}" exwm_vr.pp
    make -C "{{selinux_dir}}" -f "{{devel_mk}}" exwm_vr_nix.pp

[group('selinux')]
selinux-install:
    @echo "Installing SELinux policy modules..."
    sudo semodule -i "{{selinux_dir}}/exwm_vr.pp"
    sudo semodule -i "{{selinux_dir}}/exwm_vr_nix.pp"

[group('selinux')]
selinux-uninstall:
    @echo "Removing SELinux policy modules..."
    sudo semodule -r exwm_vr 2>/dev/null || true
    sudo semodule -r exwm_vr_nix 2>/dev/null || true

[group('selinux')]
selinux-label-nix:
    @echo "Labeling Nix compositor binary..."
    sudo "{{selinux_dir}}/label-nix-compositor.sh"

[group('selinux')]
selinux-check:
    @echo "Checking SELinux policy syntax..."
    checkmodule -M -m -o /dev/null "{{selinux_dir}}/exwm_vr.te" && echo "  exwm_vr.te: OK"
    checkmodule -M -m -o /dev/null "{{selinux_dir}}/exwm_vr_nix.te" && echo "  exwm_vr_nix.te: OK"

[group('selinux')]
selinux-clean:
    @echo "Cleaning SELinux build artifacts..."
    rm -f "{{selinux_dir}}"/*.pp "{{selinux_dir}}"/*.mod "{{selinux_dir}}"/*.mod.fc
    rm -rf "{{selinux_dir}}/tmp"
