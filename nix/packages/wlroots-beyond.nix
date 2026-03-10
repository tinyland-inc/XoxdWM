# Patched wlroots with Bigscreen Beyond non_desktop detection
#
# The Beyond 2e headset lacks an EDID quirk in most kernels, so compositors
# treat DP-2 as a regular monitor.  This patch forces non_desktop=true when
# the EDID manufacturer string contains "Bigscreen", allowing Monado to
# acquire the display via DRM lease.
{ pkgs, ... }:

pkgs.wlroots_0_18.overrideAttrs (old: {
  patches = (old.patches or []) ++ [
    ../../patches/wlroots-bigscreen-non-desktop.patch
  ];

  # Ensure XWayland support (needed for Steam/SteamVR)
  mesonFlags = (old.mesonFlags or []) ++ [
    "-Dxwayland=enabled"
  ];
})
