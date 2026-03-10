# Sway 1.10 built against patched wlroots for Beyond VR
#
# Uses wlroots-beyond (with non_desktop detection) so that Sway correctly
# ignores the Beyond headset display and exposes it for DRM lease.
{ pkgs, wlroots-beyond, ... }:

(pkgs.sway-unwrapped.override {
  wlroots = wlroots-beyond;
}).overrideAttrs (_old: {
  # Placeholder for any future sway-specific patches
})
