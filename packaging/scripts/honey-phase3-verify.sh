#!/bin/bash
# Phase 3: Display verification after kernel upgrade
# Run on honey as: bash honey-phase3-verify.sh (no sudo needed)

set -euo pipefail

echo "=== Phase 3: Beyond 2e Display Verification ==="
echo

# 1. Kernel
echo "[1/7] Kernel..."
KVER=$(uname -r)
echo "  Running: $KVER"
KMAJ=$(echo "$KVER" | cut -d. -f1)
KMIN=$(echo "$KVER" | cut -d. -f2)
if [ "$KMAJ" -ge 6 ] && [ "$KMIN" -ge 13 ]; then
    echo "  OK: >= 6.13"
else
    echo "  FAIL: $KVER < 6.13 — RDNA 4 display may not work"
fi
echo

# 2. SMU
echo "[2/7] SMU status..."
if dmesg 2>/dev/null | grep -i "smu driver" | grep -qi "mismatch"; then
    echo "  WARNING: SMU version mismatch detected!"
    dmesg | grep -i "smu driver" | tail -2
else
    echo "  OK: No SMU mismatch"
fi
echo

# 3. Firmware
echo "[3/7] amdgpu firmware..."
FW_ERRORS=$(dmesg 2>/dev/null | grep -ci "firmware.*error\|firmware.*fail\|firmware.*-19" || true)
if [ "$FW_ERRORS" -gt 0 ]; then
    echo "  WARNING: $FW_ERRORS firmware errors in dmesg"
    dmesg | grep -i "firmware.*error\|firmware.*fail" | tail -3
else
    echo "  OK: No firmware errors"
fi
echo

# 4. DRM connectors
echo "[4/7] DRM connectors..."
FOUND_BEYOND=false
for conn in /sys/class/drm/card*-*/; do
    [ -d "$conn" ] || continue
    name=$(basename "$conn")
    status=$(cat "$conn/status" 2>/dev/null || echo "?")
    nd=$(cat "$conn/non_desktop" 2>/dev/null || echo "?")
    enabled=$(cat "$conn/enabled" 2>/dev/null || echo "?")
    echo "  $name: status=$status non_desktop=$nd enabled=$enabled"
    if [ "$status" = "connected" ] && [ "$nd" = "1" ]; then
        FOUND_BEYOND=true
        BEYOND_CONN="$name"
    fi
done
if $FOUND_BEYOND; then
    echo "  ** Beyond detected on $BEYOND_CONN **"
else
    echo "  WARNING: No connected non-desktop display found"
fi
echo

# 5. EDID
echo "[5/7] EDID check..."
for conn in /sys/class/drm/card*-DP-*/; do
    [ -d "$conn" ] || continue
    name=$(basename "$conn")
    status=$(cat "$conn/status" 2>/dev/null || echo "?")
    if [ "$status" = "connected" ]; then
        if [ -f "$conn/edid" ] && [ -s "$conn/edid" ]; then
            echo "  $name: EDID present ($(wc -c < "$conn/edid") bytes)"
            if command -v edid-decode >/dev/null 2>&1; then
                edid-decode < "$conn/edid" 2>&1 | grep -E "Manufacturer|Product|Serial|Display" | head -5
            else
                strings "$conn/edid" | head -3
            fi
        else
            echo "  $name: No EDID data"
        fi
    fi
done
echo

# 6. Display modes
echo "[6/7] Display modes..."
for conn in /sys/class/drm/card*-DP-*/; do
    [ -d "$conn" ] || continue
    name=$(basename "$conn")
    status=$(cat "$conn/status" 2>/dev/null || echo "?")
    if [ "$status" = "connected" ]; then
        modes=$(cat "$conn/modes" 2>/dev/null)
        if [ -n "$modes" ]; then
            echo "  $name modes:"
            echo "$modes" | sed 's/^/    /'
        else
            echo "  $name: No modes available"
        fi
    fi
done
echo

# 7. USB devices
echo "[7/7] Beyond USB devices..."
if command -v lsusb >/dev/null 2>&1; then
    lsusb | grep -i "35bd\|bigscreen\|bigeye" || echo "  No Beyond USB devices found"
else
    echo "  lsusb not available"
fi
echo

# 8. hidraw permissions
echo "[bonus] hidraw permissions..."
for h in /dev/hidraw*; do
    [ -c "$h" ] || continue
    perms=$(stat -c '%a %U:%G' "$h")
    # Try to read the device name from sysfs
    hnum=$(basename "$h")
    name=$(cat "/sys/class/hidraw/$hnum/device/uevent" 2>/dev/null | grep HID_NAME | cut -d= -f2 || echo "unknown")
    echo "  $h: $perms ($name)"
done
echo

# Summary
echo "=== Verification Summary ==="
if $FOUND_BEYOND; then
    echo "PASS: Beyond detected as non-desktop display on $BEYOND_CONN"
    echo "Next: Proceed to Phase 4 (bootstrap calibration)"
else
    echo "INCOMPLETE: Beyond display not detected."
    echo
    echo "Troubleshooting:"
    echo "  1. Check DP cable — try other GPU DP port"
    echo "  2. dmesg | grep -i dp    # Link training errors?"
    echo "  3. dmesg | grep -i edid  # EDID detection?"
    echo "  4. dmesg | grep -i amdgpu | tail -20"
    echo "  5. If connector shows 'connected' but non_desktop=0:"
    echo "     echo 1 | sudo tee /sys/class/drm/<connector>/non_desktop"
fi
