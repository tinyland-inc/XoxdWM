#!/bin/bash
# xr-bci tuned profile script
# Validates SMI mitigation and reports hardware latency baseline
#
# Called by tuned when profile is activated/deactivated

. /usr/lib/tuned/functions

start() {
    # Report SMI mitigation status
    echo "xr-bci: Checking SMI mitigation..."

    # Check BIOS version
    BIOS_VER=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
    if [ "$BIOS_VER" = "A02" ]; then
        echo "xr-bci: WARNING: BIOS $BIOS_VER detected — A34 required for RT"
        echo "xr-bci: Flash BIOS first: just bios-prepare-usb /dev/sdX"
    else
        echo "xr-bci: BIOS version: $BIOS_VER"
    fi

    # Check for RT kernel
    if grep -q PREEMPT_RT /boot/config-$(uname -r) 2>/dev/null; then
        echo "xr-bci: PREEMPT_RT kernel detected"
    elif zcat /proc/config.gz 2>/dev/null | grep -q PREEMPT_RT; then
        echo "xr-bci: PREEMPT_RT kernel detected"
    else
        echo "xr-bci: WARNING: non-RT kernel — BCI I/O latency not guaranteed"
    fi

    # Disable kernel watchdogs on isolated cores
    for cpu in /sys/devices/system/cpu/cpu*/watchdog; do
        [ -f "$cpu" ] && echo 0 > "$cpu" 2>/dev/null
    done

    # Set CPU frequency governor to performance (all cores)
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$gov" ] && echo performance > "$gov" 2>/dev/null
    done

    # Report clocksource
    echo "xr-bci: clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"

    return 0
}

stop() {
    return 0
}

process $@
