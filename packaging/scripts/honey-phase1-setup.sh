#!/bin/bash
# Phase 1: Honey server prerequisites for Beyond 2e bootstrap
# Run on honey as: sudo bash honey-phase1-setup.sh

set -euo pipefail

echo "=== Phase 1: Beyond 2e Bootstrap Prerequisites ==="
echo

# 1. Group membership
echo "[1/4] Adding jess to video, render, input groups..."
usermod -aG video,render,input jess
echo "  Done. Groups: $(id jess)"
echo

# 2. udev rules
echo "[2/4] Installing udev rules..."
RULES_SRC="$(dirname "$0")/../udev/99-exwm-vr.rules"
if [ -f "$RULES_SRC" ]; then
    cp "$RULES_SRC" /etc/udev/rules.d/99-exwm-vr.rules
elif [ -f /tmp/99-exwm-vr.rules ]; then
    cp /tmp/99-exwm-vr.rules /etc/udev/rules.d/99-exwm-vr.rules
else
    echo "  ERROR: udev rules file not found. Copy manually."
    exit 1
fi
udevadm control --reload-rules
udevadm trigger
echo "  Installed: /etc/udev/rules.d/99-exwm-vr.rules"
echo

# 3. Check firmware
echo "[3/4] Checking amdgpu firmware..."
FW_DIR="/lib/firmware/amdgpu"
if ls "$FW_DIR"/gc_12_0_0* >/dev/null 2>&1; then
    echo "  Found firmware blobs:"
    ls -la "$FW_DIR"/gc_12_0_0* | head -5
    echo "  ..."
    echo "  Total amdgpu blobs: $(ls "$FW_DIR"/ | wc -l)"
else
    echo "  WARNING: No gc_12_0_0 firmware found!"
    echo "  Run: git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"
    echo "  Then: sudo cp linux-firmware/amdgpu/* /lib/firmware/amdgpu/"
    echo "  Then: sudo dracut --force"
fi
echo

# 4. Check kernel
echo "[4/4] Kernel check..."
echo "  Current: $(uname -r)"
KVER=$(uname -r | cut -d. -f1-2)
if [ "$(echo "$KVER >= 6.13" | bc)" -eq 1 ] 2>/dev/null; then
    echo "  OK: Kernel $KVER >= 6.13"
else
    echo "  WARNING: Kernel $KVER < 6.13 — RDNA 4 display output may not work."
    echo "  Beyond display requires kernel 6.13.5+ for proper SMU/DCN support."
    echo "  Options: ELRepo kernel-ml, build from source, or Nix-managed kernel."
fi
echo

# Summary
echo "=== Phase 1 Complete ==="
echo
echo "Actions required:"
echo "  1. LOG OUT and log back in (for group membership to take effect)"
echo "  2. Unplug and replug the Beyond headset (for udev rules)"
echo "  3. Upgrade kernel to 6.13.5+ (critical blocker for display)"
echo "  4. Update amdgpu firmware if needed"
