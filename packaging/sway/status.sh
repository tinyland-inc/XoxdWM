#!/bin/sh
# Sway status bar for VR development hosts.
# Shows date/time and HMD connector status.
while :; do
    hmd=$(cat /sys/class/drm/card0-DP-2/status 2>/dev/null || echo "N/A")
    echo "$(date +'%Y-%m-%d %H:%M') | HMD:${hmd}"
    sleep 5
done
