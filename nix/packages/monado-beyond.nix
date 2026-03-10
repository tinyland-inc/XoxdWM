# Monado OpenXR runtime with Bigscreen Beyond build flags
#
# Enables SteamVR Lighthouse driver (for Beyond tracking pucks) and
# the SteamVR plugin.  Prefers nixpkgs-xr's monado if available,
# falls back to nixpkgs monado, and finally builds from source.
{ pkgs, nixpkgs-xr ? null, system ? pkgs.stdenv.hostPlatform.system, ... }:

let
  # nixpkgs-xr exposes monado under packages.<system>.monado
  xrMonado =
    if nixpkgs-xr != null
    then nixpkgs-xr.packages.${system}.monado or null
    else null;

  baseMonado = if xrMonado != null then xrMonado
               else pkgs.monado or null;

  beyondCmakeFlags = [
    "-DXRT_BUILD_DRIVER_STEAMVR_LIGHTHOUSE=ON"
    "-DXRT_FEATURE_STEAMVR_PLUGIN=ON"
    "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
  ];
in
if baseMonado != null then
  baseMonado.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ beyondCmakeFlags;

    # Ensure libuvc + hidapi for Beyond HID/UVC access
    buildInputs = (old.buildInputs or []) ++ (with pkgs; [
      libuvc
      hidapi
    ]);
  })
else
  # Fallback: build from gitlab source
  pkgs.stdenv.mkDerivation {
    pname = "monado";
    version = "main-unstable";

    src = pkgs.fetchFromGitLab {
      domain = "gitlab.freedesktop.org";
      owner = "monado";
      repo = "monado";
      rev = "main";
      hash = pkgs.lib.fakeHash;
    };

    nativeBuildInputs = with pkgs; [ cmake ninja pkg-config glslang ];

    buildInputs = with pkgs; [
      eigen
      libusb1
      libuvc
      hidapi
      vulkan-headers
      vulkan-loader
      wayland
      wayland-protocols
      libdrm
      mesa
      libxkbcommon
      opencv
      udev
    ];

    cmakeFlags = [
      "-GNinja"
      "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"
    ] ++ beyondCmakeFlags;

    meta = with pkgs.lib; {
      description = "Monado OpenXR runtime (Beyond VR config)";
      homepage = "https://monado.freedesktop.org/";
      license = licenses.boost;
      platforms = platforms.linux;
    };
  }
