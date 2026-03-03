# R16.2: RISC-V Wayland Compositor Status

## Context

RISC-V (riscv64gc) is an emerging ISA with growing Linux ecosystem support.
This document evaluates the feasibility of running EXWM-VR components on
RISC-V hardware, from headless IPC-only mode to full graphical compositor.

## Smithay on RISC-V

Smithay is pure Rust with C library dependencies. The key question is whether
those C dependencies build and work on riscv64.

### Dependency Status

| Dependency | riscv64 Support | Notes |
|-----------|----------------|-------|
| wayland-client (Rust) | Yes | Pure Rust protocol marshaling |
| wayland-server (Rust) | Yes | Pure Rust |
| libwayland (C) | Yes | In Debian/Fedora riscv64 ports |
| libinput | Yes | Mainline; input devices are arch-independent |
| libdrm | Yes | Mainline kernel support |
| libseat | Yes | Pure C, no arch-specific code |
| libxkbcommon | Yes | Pure C keymap compiler |
| Mesa (EGL/GBM) | Partial | llvmpipe works; no native GPU drivers |
| calloop | Yes | Pure Rust event loop |
| openxrs | Untested | Pure Rust OpenXR bindings; unlikely issues |

### Expected Build Issues

1. **bindgen**: C header parsing works on riscv64 (LLVM/Clang support exists)
2. **Atomic operations**: riscv64gc includes the `A` extension (atomics); no
   issues expected with `std::sync::atomic`
3. **SIMD**: No vector extension available on current hardware; BrainFlow and
   signal processing will use scalar fallbacks
4. **proc-macros**: Build natively or cross-compile with proper target config

## wlroots on RISC-V

wlroots (the C compositor library, not used by EXWM-VR but relevant as a
reference) has been reported working on RISC-V:

- **SiFive HiFive Unmatched**: wlroots + Sway running with llvmpipe
- **StarFive VisionFive 2**: Sway runs in software rendering mode
- **Performance**: Usable for lightweight terminal/editor workflows at 720p

Since wlroots' dependencies overlap heavily with Smithay's, this is a positive
signal for Smithay on RISC-V.

## Mesa on RISC-V

| Driver | Status | Notes |
|--------|--------|-------|
| llvmpipe | Works | Software rasterizer, LLVM riscv64 backend |
| lavapipe | Works | Software Vulkan 1.0, very slow |
| Imagination PowerVR (pvr) | In progress | For Imagination GPU in JH7110 SoC |
| No other native drivers | N/A | No Mali/Adreno/Intel/AMD on RISC-V SoCs |

llvmpipe provides OpenGL 4.5 and GLES 3.1 in software. This is sufficient for
Smithay's GlesRenderer but performance will be limited to simple desktop
compositing at low resolutions (720p-1080p, 15-30 fps).

## Emacs on RISC-V

Emacs has supported riscv64-linux-gnu since Emacs 29:

- **Emacs 29+**: riscv64 in `config.sub`, builds cleanly
- **emacs-nox**: Works (terminal mode, no GUI dependencies)
- **emacs-pgtk**: Works if GTK4 is available (it is on Fedora/Debian riscv64)
- **Native compilation (libgccjit)**: GCC has riscv64 support; native-comp works

Elisp is architecture-independent, so all EXWM-VR `.el` modules work without
modification.

## Linux Kernel DRM Subsystem

The DRM subsystem is architecture-independent at the core. However, GPU drivers
are tied to specific hardware:

- **drm/imagination**: PVR driver for Imagination GPU in StarFive JH7110
  (upstream since Linux 6.8, still maturing)
- **drm/verisilicon**: For VeriSilicon Vivante GPUs in some RISC-V SoCs
  (out-of-tree, limited Mesa support)
- **virtio-gpu**: Works for QEMU/KVM guests (useful for CI)

DRM lease support (`wp_drm_lease_v1`) is GPU-driver-independent at the
protocol level, but requires a GPU that supports connector leasing. No RISC-V
GPU driver currently supports DRM lease.

## Hardware Options

| Board | SoC | GPU | Price | Viability |
|-------|-----|-----|-------|-----------|
| SiFive HiFive Unmatched | FU740 | None | ~$600 (discontinued) | Headless only |
| StarFive VisionFive 2 | JH7110 | Imagination BXE-4-32 | ~$65 | Best option; PVR driver maturing |
| Milk-V Pioneer | SG2042 | None (PCIe slot) | ~$300 | PCIe GPU possible (untested) |
| Lichee Pi 4A | TH1520 | Imagination | ~$120 | Similar to VisionFive 2 |
| QEMU riscv64 | N/A | virtio-gpu | Free | CI and testing |

## Feasibility Assessment

| Mode | Feasibility | Confidence |
|------|-------------|------------|
| Headless (IPC only) | High | 90% -- pure Rust + Emacs nox |
| Terminal Emacs + IPC | High | 90% -- no GPU needed |
| 2D compositor (llvmpipe) | Medium | 70% -- works on wlroots, untested on Smithay |
| 2D compositor (native GPU) | Low | 30% -- PVR driver is immature |
| VR | None | 0% -- no VR runtime, no capable GPU |
| Eye tracking | None | 0% -- no USB stack on most boards |
| BCI | None | 0% -- no serial peripherals |

## Conclusion

**Headless mode likely works** with minimal effort. The Rust compositor's IPC
and workspace management logic has no architecture-specific code. Terminal
Emacs (`emacs -nw`) with the full ewwm Elisp stack should function identically
to other architectures.

**Full GPU compositing is unlikely** in the near term. The only viable path is
the Imagination PVR driver on JH7110-based boards, which is still maturing and
lacks DMA-BUF import reliability.

**Recommendation**: Add riscv64 to CI as a headless-only build target using
QEMU user-mode emulation. Do not invest in GPU compositor testing until the
Imagination PVR Mesa driver reaches feature parity with Panfrost.

## References

- [Fedora RISC-V port](https://fedoraproject.org/wiki/Architectures/RISC-V)
- [Imagination PVR kernel driver](https://docs.kernel.org/gpu/imagination/index.html)
- [StarFive VisionFive 2 wiki](https://doc-en.rvspace.org/VisionFive2/)
- [Emacs riscv64 support commit](https://git.savannah.gnu.org/cgit/emacs.git/log/?qt=grep&q=riscv)
