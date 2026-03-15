# kernel-xr Boot Failure Analysis — Rocky Linux 10.1

**Date**: 2026-03-15
**Kernel**: kernel-xr-6.19.5-3.xr.el10 (generic, non-RT)
**Target**: Dell T7810, Rocky Linux 10.1, systemd 257
**Status**: Root cause identified, fix in build [run 23106018203](https://github.com/Jesssullivan/linux-xr/actions/runs/23106018203)

## Symptom

```
[FAILED] Failed to start initrd-switch-root.service - Switch Root.
Cannot open access to console, the root account is locked.
```

Occurs after LVM is assembled, modules are loaded, and initramfs has found root.
Both RT and non-RT kernels fail identically.

## Root Cause: BTF Cascade Disable

The RPM spec disabled `CONFIG_DEBUG_INFO_NONE=y` to reduce build memory.
This cascade-disables `CONFIG_DEBUG_INFO_BTF`:

```
Kconfig (lib/Kconfig.debug line 398):
  config DEBUG_INFO_BTF
    depends on !DEBUG_INFO_SPLIT && !DEBUG_INFO_REDUCED
    depends on BPF_SYSCALL
```

Without BTF, systemd 257 cannot load its BPF programs for cgroup v2 management.
The BPF-based filesystem restriction fails, and systemd hangs during switch-root.

### Why DEBUG_INFO_REDUCED also fails

First fix attempt used `CONFIG_DEBUG_INFO_REDUCED=y`. This also kills BTF
because of the `depends on !DEBUG_INFO_REDUCED` constraint.

### Correct fix: DWARF4

Use `CONFIG_DEBUG_INFO_DWARF4=y` (smaller than DWARF5, ~4GB vs ~8GB link-time)
while keeping all `DEBUG_INFO_REDUCED`, `DEBUG_INFO_SPLIT`, `DEBUG_INFO_NONE`
disabled. This preserves BTF.

## Contributing Factors

### CONFIG_FW_LOADER_USER_HELPER=y

The ELRepo base.config has this enabled. systemd explicitly requires it disabled.
With it enabled, udev firmware loading can race during early boot in the initrd.

### Missing dracut in %post

The RPM `%post` scriptlet only ran `depmod` and `grubby --set-default`.
It never called `dracut` to generate an initramfs. The `just beyond-kernel-install`
target worked around this manually, but the RPM itself was broken.

### "Cannot open access to console"

This is a **red herring**. Rocky 10.1 locks the root account by default.
When switch-root fails and systemd drops to emergency mode, `sulogin` cannot
open a console because there is no root password. The actual failure is systemd
hanging during the cgroup v2 BPF initialization.

## Fix Applied (commit 575792d51)

```spec
# Use DWARF4 (not REDUCED/NONE) to preserve BTF for systemd 257
scripts/config --enable CONFIG_DEBUG_INFO
scripts/config --enable CONFIG_DEBUG_INFO_DWARF4
scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
scripts/config --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
scripts/config --disable CONFIG_DEBUG_INFO_REDUCED
scripts/config --disable CONFIG_DEBUG_INFO_SPLIT
scripts/config --disable CONFIG_DEBUG_INFO_NONE
scripts/config --enable CONFIG_DEBUG_INFO_BTF
scripts/config --enable CONFIG_DEBUG_INFO_BTF_MODULES

# systemd 257 requirements
scripts/config --disable CONFIG_FW_LOADER_USER_HELPER
scripts/config --enable CONFIG_AUTOFS_FS
scripts/config --enable CONFIG_TMPFS_XATTR
scripts/config --enable CONFIG_TMPFS_POSIX_ACL
scripts/config --enable CONFIG_OVERLAY_FS

# dracut in %post
dracut --force /boot/initramfs-${KREL}.img ${KREL}
```

## Remaining Risk: pahole Version

`CONFIG_DEBUG_INFO_BTF` requires `PAHOLE_VERSION >= 122`. The CI installs
`dwarves` via `apt-get` on Ubuntu. If the version is too old, `make olddefconfig`
will silently disable BTF. The `make listnewconfig` step helps detect this.

## systemd 257 Kernel Requirements (complete list)

### Hard requirements
- CONFIG_DEVTMPFS, CONFIG_CGROUPS, CONFIG_INOTIFY_USER
- CONFIG_SIGNALFD, CONFIG_TIMERFD, CONFIG_EPOLL
- CONFIG_UNIX (via CONFIG_NET), CONFIG_SYSFS, CONFIG_PROC_FS
- CONFIG_FHANDLE, CONFIG_FUTEX, CONFIG_BINFMT_ELF
- CONFIG_BPF_SYSCALL, CONFIG_CGROUP_BPF, CONFIG_DEBUG_INFO_BTF

### Must be disabled
- CONFIG_SYSFS_DEPRECATED, CONFIG_UEVENT_HELPER_PATH
- CONFIG_FW_LOADER_USER_HELPER, CONFIG_RT_GROUP_SCHED

### Strongly recommended
- CONFIG_AUTOFS_FS, CONFIG_TMPFS_XATTR, CONFIG_TMPFS_POSIX_ACL
- CONFIG_OVERLAY_FS, CONFIG_SECCOMP, CONFIG_SECCOMP_FILTER
- CONFIG_NET_NS, CONFIG_USER_NS, CONFIG_PID_NS

All verified present in the ELRepo base.config and preserved by our spec overrides.

## Upstream Patch Status

| Patch | Status | Next Step |
|-------|--------|-----------|
| VESA DisplayID DSC BPP (Bolyukin v7) | Blocked — Ville Syrjala architectural objections | Carry CachyOS patch |
| QP/RC offset (raika-xino) | Never submitted standalone | Submit to amd-gfx |
| EDID non_desktop (Scrumplex) | Stalled since May 2024 | Re-submit |
| PREEMPT_RT | Merged in 6.12 | CONFIG_PREEMPT_RT=y |

## References

- [systemd README kernel requirements](https://github.com/systemd/systemd/blob/main/README)
- [systemd v257 release notes](https://github.com/systemd/systemd/releases/tag/v257)
- [Bolyukin v7 LKML](https://lkml.org/lkml/2025/12/2/699)
- [Syrjala review concerns](https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg129819.html)
- [ELRepo kernel-ml](https://github.com/elrepo/kernel)
- [Rocky Linux 10.1 release notes](https://docs.rockylinux.org/release_notes/10_1)
