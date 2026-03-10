# Sway built against patched wlroots for Beyond VR
#
# Uses wlroots-beyond (with non_desktop detection) so that Sway correctly
# ignores the Beyond headset display and exposes it for DRM lease.
#
# Note: nixpkgs-unstable sway 1.11 expects wlroots_0_19, but our patch
# targets wlroots 0.18. We override sway-unwrapped to use our patched
# wlroots regardless of version expectations.
{ pkgs, wlroots-beyond, ... }:

pkgs.sway-unwrapped.overrideAttrs (old: {
  buildInputs = map (dep:
    if (dep.pname or "") == "wlroots" then wlroots-beyond else dep
  ) (old.buildInputs or []);
})
