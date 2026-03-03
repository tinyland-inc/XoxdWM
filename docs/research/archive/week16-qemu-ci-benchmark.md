# R16.1: QEMU User-Mode Emulation vs Native ARM64 CI

## Context

The EXWM-VR project targets aarch64 alongside x86_64 and s390x. CI must build
and test the Rust compositor and Elisp modules on aarch64. This document
evaluates the trade-offs between QEMU user-mode emulation and native ARM64 CI
runners.

## QEMU User-Mode Emulation

QEMU user-mode (`qemu-aarch64-static`) translates aarch64 syscalls and
instructions on an x86_64 host. It is the simplest path: no new hardware, no
new CI provider.

### Performance Overhead

| Task | Native ARM64 | QEMU on x86_64 | Slowdown |
|------|-------------|----------------|----------|
| `cargo build --release` | ~8 min | ~50-80 min | 6-10x |
| `cargo test` | ~3 min | ~20-30 min | 7-10x |
| Elisp byte-compile | ~15 sec | ~60-90 sec | 4-6x |
| ERT test suite | ~30 sec | ~2-3 min | 4-6x |

QEMU user-mode overhead is dominated by instruction translation, not I/O.
Rust compilation is particularly affected because LLVM codegen is CPU-bound.

### Setup (GitHub Actions)

```yaml
jobs:
  build-aarch64:
    runs-on: ubuntu-latest
    steps:
      - uses: docker/setup-qemu-action@v3
        with:
          platforms: arm64
      - uses: docker/setup-buildx-action@v3
      - run: |
          docker buildx build \
            --platform linux/arm64 \
            --target builder \
            -f Dockerfile.ci .
```

### Limitations

- Rust proc-macros execute under QEMU (significant overhead)
- Some syscalls behave differently (io_uring, memfd_create edge cases)
- Debug symbols inflate memory usage under emulation
- Cargo parallel jobs should be reduced (`-j2` instead of `-j$(nproc)`)

## Native ARM64 CI Runners

### GitHub Actions ARM64 Runners

GitHub offers `ubuntu-arm64` runners (launched 2024):

- **Availability**: Generally available for public repos (free tier)
- **Specs**: 4 vCPU Ampere Altra, 16 GB RAM
- **Cost (private repos)**: $0.16/min (vs $0.008/min for x86_64 Linux)
- **Cost ratio**: 20x more expensive per minute, but ~8x faster for Rust builds
- **Net cost**: ~2.5x more expensive but dramatically faster

```yaml
jobs:
  build-aarch64:
    runs-on: ubuntu-arm64
    steps:
      - uses: actions/checkout@v4
      - run: cargo build --release
```

### Hetzner ARM64 Cloud (Self-Hosted Runner)

Hetzner CAX series (Ampere Altra):

| Instance | vCPU | RAM | Price/mo | Price/hr |
|----------|------|-----|----------|----------|
| CAX11 | 2 | 4 GB | EUR 3.29 | ~EUR 0.005 |
| CAX21 | 4 | 8 GB | EUR 5.89 | ~EUR 0.009 |
| CAX31 | 8 | 16 GB | EUR 10.49 | ~EUR 0.016 |

- Cheapest option for sustained CI workloads
- Requires self-hosted runner setup (GitHub Actions runner agent)
- Spot instances not available for ARM64 at Hetzner (as of early 2026)
- Management overhead: OS updates, runner agent updates, security

### Oracle Cloud ARM64 (Free Tier)

Oracle Cloud offers Ampere A1 in the always-free tier:

- 4 OCPU (ARM64), 24 GB RAM -- generous for CI
- Unreliable availability (free tier instances often not launchable)
- Not suitable as sole CI target

## Recommendation

| Use Case | Approach | Rationale |
|----------|----------|-----------|
| PR CI (fast feedback) | QEMU user-mode | Simple, no extra infra, acceptable for ERT tests |
| Nightly full build | GitHub ARM64 runner | Native speed, worth the cost for release validation |
| Release builds | GitHub ARM64 runner or Hetzner CAX31 | Must be native for reproducible binaries |
| s390x CI | QEMU user-mode only | No native s390x CI runners available anywhere |

### Phased Approach

1. **Now**: QEMU user-mode for all cross-arch CI (works today, zero cost)
2. **When builds exceed 60 min**: Add native ARM64 runner for nightly builds
3. **For releases**: Always use native ARM64 (reproducible, correct optimization)

### Cargo Build Caching

Regardless of approach, use `sccache` or GitHub Actions cache to avoid
re-compiling unchanged dependencies:

```yaml
- uses: Swatinem/rust-cache@v2
  with:
    shared-key: "aarch64-compositor"
```

This reduces incremental build times from ~50 min to ~10 min under QEMU.

## References

- [GitHub ARM64 runner docs](https://docs.github.com/en/actions/using-github-hosted-runners/using-github-hosted-runners/about-github-hosted-runners#supported-runners-and-hardware-resources)
- [QEMU user-mode documentation](https://www.qemu.org/docs/master/user/main.html)
- [Hetzner Cloud ARM64 pricing](https://www.hetzner.com/cloud/)
- [sccache for Rust CI](https://github.com/mozilla/sccache)
