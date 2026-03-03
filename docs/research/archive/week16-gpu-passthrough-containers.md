# R16.3: GPU Passthrough for Containerized Compositor

## Context

Running the EXWM-VR compositor inside a container (Podman/Docker) or VM
requires GPU access for hardware-accelerated rendering. This document evaluates
device passthrough strategies, security implications, and recommendations.

## Device Passthrough (Containers)

### DRI Device Mapping

The compositor needs access to DRM render nodes and card devices:

```bash
# Minimal: render node only (sufficient for clients, not for KMS)
podman run --device /dev/dri/renderD128 ...

# Full: card + render node (needed for KMS/mode-setting compositor)
podman run \
    --device /dev/dri/card0 \
    --device /dev/dri/renderD128 \
    ...

# All DRI devices (multi-GPU)
podman run --device /dev/dri ...
```

### Additional Required Devices

| Device | Purpose | Required |
|--------|---------|----------|
| `/dev/dri/card0` | DRM KMS (mode setting) | Yes (for compositor) |
| `/dev/dri/renderD128` | DRM render node | Yes (for rendering) |
| `/dev/input/event*` | Input devices (libinput) | Yes (or use libseat) |
| `/dev/uinput` | Virtual input (ydotool) | Only for auto-type |
| `/dev/ttyUSB*` | OpenBCI serial | Only for BCI |

### Driver Version Matching

The container and host **must** use the same GPU driver version. A version
mismatch causes immediate failure (segfault or EGL initialization error).

**For Mesa (open-source drivers)**:

```bash
# Host Mesa version
glxinfo | grep "OpenGL version"  # e.g., Mesa 24.2.1

# Container must match
# Bad: container has Mesa 23.x, host has Mesa 24.x
# Good: same Mesa version inside and outside
```

**For NVIDIA (proprietary)**:

```bash
# Host driver version
nvidia-smi --query-gpu=driver_version --format=csv,noheader

# Container must have matching libnvidia-*.so
# Use nvidia-container-toolkit for automatic injection
podman run --hooks-dir=/usr/share/containers/oci/hooks.d \
    --security-opt=label=disable \
    ...
```

### Nix Container Advantage

Nix provides deterministic driver matching through its closure mechanism:

```nix
# Container image pins exact Mesa version from Nix store
dockerTools.buildLayeredImage {
  name = "exwm-vr-compositor";
  contents = [
    pkgs.mesa.drivers   # Same Mesa as host NixOS
    compositorPackage
  ];
  config.Env = [
    "LIBGL_DRIVERS_PATH=${pkgs.mesa.drivers}/lib/dri"
    "LD_LIBRARY_PATH=${pkgs.mesa.drivers}/lib"
  ];
}
```

This guarantees the container uses the exact same Mesa build as the host,
eliminating version mismatch issues entirely.

## Security Implications

### What GPU Passthrough Exposes

Passing `/dev/dri/*` to a container gives it:

- Direct memory-mapped access to GPU VRAM
- Ability to execute arbitrary GPU shaders
- DMA access to system memory (via GPU DMA engines)
- Potential to read other processes' GPU memory (driver-dependent)

This **breaks container isolation** in a meaningful way. A compromised
compositor container with GPU access can:

1. Read GPU memory from other containers sharing the same GPU
2. Perform GPU-based side-channel attacks
3. Crash the GPU (affecting all users of that GPU)
4. Potentially DMA to arbitrary physical addresses (on vulnerable drivers)

### Mitigation

- Run the compositor container with minimal capabilities (`--cap-drop=ALL`)
- Use SELinux to confine GPU device access (see `exwm_vr.te` policy)
- Do not share the GPU between trusted and untrusted workloads
- Prefer render nodes (`renderD128`) over card nodes when KMS is not needed

## VirtIO GPU for VM Guests

For VM-based isolation (QEMU/KVM), VirtIO-GPU provides a safer alternative:

```bash
# QEMU with VirtIO-GPU (virgl 3D acceleration)
qemu-system-x86_64 \
    -device virtio-gpu-gl-pci \
    -display egl-headless \
    ...
```

### VirtIO-GPU Trade-offs

| Aspect | Device Passthrough | VirtIO-GPU (virgl) |
|--------|-------------------|--------------------|
| Performance | Native | 50-70% of native |
| Isolation | Weak | Strong (mediated) |
| Driver matching | Required | Not required |
| DMA-BUF | Yes | No (SHM fallback) |
| DRM lease | Yes | No |
| VR capable | Yes | No |
| Setup complexity | Low | Medium |

### VFIO Passthrough (Full GPU)

For VR in a VM, VFIO GPU passthrough gives the guest exclusive GPU access:

```bash
# Bind GPU to vfio-pci driver
echo "0000:01:00.0" > /sys/bus/pci/drivers/amdgpu/unbind
echo "vfio-pci" > /sys/bus/pci/devices/0000:01:00.0/driver_override

# QEMU with VFIO passthrough
qemu-system-x86_64 \
    -device vfio-pci,host=01:00.0 \
    ...
```

This provides native performance and full DRM lease support, but the GPU is
exclusively owned by the VM (not shared with the host).

## Podman vs Docker

| Feature | Podman | Docker | Notes |
|---------|--------|--------|-------|
| Rootless containers | Yes | Partial | Podman preferred for security |
| Device access | `--device` | `--device` | Identical syntax |
| SELinux support | Native | Limited | Podman respects SELinux labels |
| GPU passthrough | Works | Works | Same kernel mechanism |
| NVIDIA toolkit | Supported | Native | `nvidia-container-toolkit` |
| Systemd integration | Native | Add-on | Podman generates quadlet units |

Podman is recommended for EXWM-VR container deployments due to rootless
support and native SELinux integration.

## Recommendation

| Use Case | Approach | Rationale |
|----------|----------|-----------|
| Development | Device passthrough (Podman) | Fast iteration, native performance |
| CI testing | VirtIO-GPU or headless | No real GPU needed for most tests |
| Production (server) | Headless (no GPU) | s390x / mainframe, IPC only |
| Production (desktop) | Native (no container) | Best performance, simplest setup |
| Production (VM) | VFIO passthrough | VR needs native GPU access |

**General guidance**: Use device passthrough for development containers where
isolation is not a concern. Use VirtIO-GPU for CI VMs. Avoid containerizing
the compositor in production unless there is a specific isolation requirement
that justifies the complexity.

## References

- [Podman device access](https://docs.podman.io/en/latest/markdown/podman-run.1.html)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/)
- [VirtIO-GPU virgl](https://virgil3d.github.io/)
- [VFIO GPU passthrough](https://www.kernel.org/doc/html/latest/driver-api/vfio.html)
- [Nix dockerTools](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-dockerTools)
