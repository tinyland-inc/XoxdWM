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
    @echo "Running VR hardware test suite: {{suite}}..."
    #!/usr/bin/env bash
    set -euo pipefail
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

# ── beyond ─────────────────────────────────────────────

[group('vr')]
beyond-deploy-phase1 host="honey":
    @echo "Deploying Phase 1 prerequisites to {{host}}..."
    scp "{{project_root}}/packaging/udev/99-exwm-vr.rules" jess@{{host}}:/tmp/99-exwm-vr.rules
    scp "{{project_root}}/packaging/scripts/honey-phase1-setup.sh" jess@{{host}}:/tmp/honey-phase1-setup.sh
    @echo "Run on {{host}}: sudo bash /tmp/honey-phase1-setup.sh"

[group('vr')]
beyond-deploy-phase2 host="honey":
    @echo "Deploying Phase 2 kernel upgrade to {{host}}..."
    scp "{{project_root}}/packaging/scripts/honey-phase2-kernel.sh" jess@{{host}}:/tmp/honey-phase2-kernel.sh
    @echo "Run on {{host}}: sudo bash /tmp/honey-phase2-kernel.sh"

[group('vr')]
beyond-verify host="honey":
    @echo "Running display verification on {{host}}..."
    ssh jess@{{host}} "bash -s" < "{{project_root}}/packaging/scripts/honey-phase3-verify.sh"

[group('vr')]
beyond-status host="honey":
    @echo "Beyond 2e status on {{host}}..."
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== USB ==="
    ssh jess@{{host}} "lsusb | grep -i '35bd\|bigscreen\|bigeye' || echo 'Not detected'"
    echo "=== DRM ==="
    ssh jess@{{host}} 'for c in /sys/class/drm/card*-DP-*/; do n=$(basename "$c"); s=$(cat "$c/status" 2>/dev/null); nd=$(cat "$c/non_desktop" 2>/dev/null); echo "  $n: status=$s non_desktop=$nd"; done'
    echo "=== hidraw ==="
    ssh jess@{{host}} 'for h in /dev/hidraw*; do hnum=$(basename "$h"); perms=$(stat -c "%a %U:%G" "$h"); name=$(cat /sys/class/hidraw/$hnum/device/uevent 2>/dev/null | grep HID_NAME | cut -d= -f2); echo "  $h: $perms ($name)"; done'

[group('vr')]
beyond-hid-test host="honey":
    @echo "Testing Beyond HID access on {{host}}..."
    ssh jess@{{host}} 'python3 -c "
import struct, os
for i in range(6):
    path = f\"/dev/hidraw{i}\"
    try:
        with open(f\"/sys/class/hidraw/hidraw{i}/device/uevent\") as f:
            name = [l.split(\"=\",1)[1].strip() for l in f if l.startswith(\"HID_NAME\")][0]
        if \"Beyond\" in name:
            fd = os.open(path, os.O_RDWR)
            print(f\"  {path}: {name} — opened OK\")
            os.close(fd)
    except PermissionError:
        print(f\"  {path}: {name} — PERMISSION DENIED\")
    except Exception as e:
        pass
" 2>/dev/null || echo "  Python3 not available or test failed"'

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
