#!/bin/bash
# Phase 2: Kernel upgrade for Beyond 2e + RDNA 4 display support
# Run on honey as: sudo bash honey-phase2-kernel.sh
#
# Installs ELRepo kernel-ml (mainline ~6.15) alongside existing Rocky kernel.
# The original kernel remains as a fallback boot option.

set -euo pipefail

echo "=== Phase 2: Kernel Upgrade (ELRepo kernel-ml) ==="
echo
echo "Current kernel: $(uname -r)"
echo "Target: kernel-ml 6.15+ (mainline stable)"
echo

# 1. Install ELRepo
echo "[1/5] Installing ELRepo..."
if rpm -q elrepo-release >/dev/null 2>&1; then
    echo "  ELRepo already installed"
else
    dnf install -y elrepo-release
    echo "  ELRepo installed"
fi
echo

# 2. Install kernel-ml
echo "[2/5] Installing kernel-ml..."
dnf --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel kernel-ml-modules kernel-ml-modules-extra
echo "  kernel-ml installed"
echo

# 3. Update amdgpu firmware
echo "[3/5] Updating amdgpu firmware..."
FW_TMP=$(mktemp -d)
echo "  Cloning linux-firmware (shallow)..."
git clone --depth 1 --filter=blob:none --sparse \
    https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
    "$FW_TMP/linux-firmware" 2>&1 | tail -1
cd "$FW_TMP/linux-firmware"
git sparse-checkout set amdgpu 2>/dev/null || true
echo "  Copying firmware blobs..."
cp -u amdgpu/* /lib/firmware/amdgpu/ 2>/dev/null || cp amdgpu/* /lib/firmware/amdgpu/
cd /
rm -rf "$FW_TMP"
echo "  Firmware updated. Rebuilding initramfs for new kernel..."
# Find the newly installed kernel version
NEW_KVER=$(rpm -q kernel-ml --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)
dracut --force /boot/initramfs-"$NEW_KVER".img "$NEW_KVER"
echo "  initramfs rebuilt for $NEW_KVER"
echo

# 4. Add amdgpu kernel parameters
echo "[4/5] Configuring kernel parameters..."
GRUB_FILE="/etc/default/grub"
if grep -q 'amdgpu.modeset=1' "$GRUB_FILE"; then
    echo "  amdgpu parameters already present"
else
    # Append amdgpu parameters to GRUB_CMDLINE_LINUX
    sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 amdgpu.modeset=1 amdgpu.dc=1 amdgpu.dcdebugmask=0x10"/' "$GRUB_FILE"
    grub2-mkconfig -o /boot/grub2/grub.cfg
    echo "  Added: amdgpu.modeset=1 amdgpu.dc=1 amdgpu.dcdebugmask=0x10"
fi
echo

# 5. Set new kernel as default
echo "[5/5] Setting new kernel as default boot entry..."
grubby --set-default="/boot/vmlinuz-$NEW_KVER"
echo "  Default boot: $NEW_KVER"
echo

# 6. Add non-desktop override udev rule for Beyond EDID quirk
# (upstream patch not merged — use udev to set non_desktop=1)
echo "[bonus] Adding non-desktop udev override for Beyond..."
cat > /etc/udev/rules.d/98-bigscreen-non-desktop.rules <<'UDEV'
# Force non_desktop=1 for Bigscreen Beyond VR headset
# The upstream EDID quirk patch is not yet merged.
# This rule fires when the DRM connector's EDID matches Beyond's vendor "BIG".
# The actual connector name varies by port (DP-1, DP-2, etc.)
ACTION=="change", SUBSYSTEM=="drm", ENV{HOTPLUG}=="1", RUN+="/bin/bash -c 'for c in /sys/class/drm/card*-DP-*/; do if [ -f \"$c/edid\" ] && cat \"$c/edid\" 2>/dev/null | strings | grep -q BIG; then echo 1 > \"$c/non_desktop\" 2>/dev/null; fi; done'"
UDEV
udevadm control --reload-rules
echo "  Installed: /etc/udev/rules.d/98-bigscreen-non-desktop.rules"
echo

echo "=== Phase 2 Complete ==="
echo
echo "Installed kernel: $NEW_KVER"
echo "Boot default set to new kernel."
echo
echo "REBOOT REQUIRED: sudo reboot"
echo
echo "After reboot, verify:"
echo "  uname -r                               # Should be $NEW_KVER"
echo "  dmesg | grep -i 'smu driver'           # Should NOT show version mismatch"
echo "  cat /sys/class/drm/card*-DP-*/status    # Check for 'connected'"
echo "  cat /sys/class/drm/card*-DP-*/non_desktop  # Should be 1 for Beyond"
