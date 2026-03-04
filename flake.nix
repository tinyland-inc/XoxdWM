{
  description = "EXWM-VR: VR-first transhuman Emacs window manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # VR hardware support (Monado, WiVRn, OpenComposite)
    nixpkgs-xr = {
      url = "github:nix-community/nixpkgs-xr";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, emacs-overlay, rust-overlay, flake-utils, nix2container, home-manager, nixpkgs-xr }:
    let
      version = "0.5.0";

      # Shared helper: build the Wayland/DRM library list for any pkgs set
      # (used by both the per-system block and the cross-compilation blocks)
      mkWaylandLibs = pkgs: with pkgs; [
        wayland
        wayland-protocols
        wayland-scanner
        libdrm
        libgbm
        mesa
        libinput
        libxkbcommon
        seatd
        libffi
        pixman
        udev
      ];

      # NixOS modules (not per-system)
      nixosModuleOutputs = {
        nixosModules = {
          exwm-vr = import ./nix/modules/exwm-vr.nix;
          monado = import ./nix/modules/monado.nix;
          default = self.nixosModules.exwm-vr;
        };

        homeManagerModules = {
          exwm-vr = import ./nix/home-manager/exwm-vr.nix;
          default = self.homeManagerModules.exwm-vr;
        };

        # Kernel overlay: Bigscreen Beyond EDID non-desktop quirk patch
        # Usage in NixOS config:
        #   boot.kernelPackages = pkgs.linuxPackages_latest.extend (self: super: {
        #     kernel = super.kernel.override {
        #       kernelPatches = [{ name = "bigscreen-beyond-non-desktop";
        #         patch = ewwm.packages.${system}.bigscreen-beyond-edid-patch; }];
        #     };
        #   });
        overlays.kernel-beyond = final: prev: {
          linuxPackages_beyond = prev.linuxPackages_latest.extend (lpSelf: lpPrev: {
            kernel = lpPrev.kernel.override {
              kernelPatches = (lpPrev.kernel.kernelPatches or []) ++ [{
                name = "bigscreen-beyond-non-desktop";
                patch = ./patches/bigscreen-beyond-edid.patch;
              }];
            };
          });
        };
      };

      # Per-system outputs
      perSystemOutputs = flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              emacs-overlay.overlays.default
              rust-overlay.overlays.default
            ];
          };

          n2c = nix2container.packages.${system}.nix2container;

          rustToolchain = pkgs.rust-bin.nightly.latest.default.override {
            extensions = [
              "rustc"
              "cargo"
              "clippy"
              "rustfmt"
              "rust-analyzer"
              "rust-src"
            ];
          };

          emacsPkg = pkgs.emacs-pgtk.overrideAttrs (old: {
            configureFlags = (old.configureFlags or [ ]) ++ [
              "--with-native-compilation=aot"
            ];
          });

          waylandLibs = mkWaylandLibs pkgs;

          buildInputs = with pkgs; [
            # Rust
            rustToolchain
            pkg-config
            clang
            llvmPackages.libclang

            # Emacs
            emacsPkg

            # Wayland / compositor deps
          ] ++ waylandLibs ++ [
            # OpenXR / VR
            monado
            openxr-loader

            # Dev tools
            just
            git-cliff
            nixpkgs-fmt
            direnv
            cachix

            # Testing
            cage   # single-window Wayland compositor for testing
            weston # headless Wayland compositor
          ];

          # Common function to build the compositor with given features
          mkCompositor = { pname, features ? [ ], extraBuildInputs ? [ ] }:
            pkgs.rustPlatform.buildRustPackage {
              inherit pname version;
              src = ./compositor;
              cargoLock.lockFile = ./compositor/Cargo.lock;

              nativeBuildInputs = with pkgs; [
                pkg-config
                clang
                llvmPackages.libclang
              ];

              buildInputs = waylandLibs ++ extraBuildInputs;

              buildNoDefaultFeatures = (features == [ ]);
              buildFeatures = features;

              LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

              # Ensure linker can find all native libraries (mesa/gbm, etc.)
              LIBRARY_PATH = pkgs.lib.makeLibraryPath (waylandLibs ++ extraBuildInputs);

              meta = with pkgs.lib; {
                description = "EXWM-VR Wayland compositor built on Smithay";
                license = licenses.gpl3Plus;
                platforms = platforms.linux;
              };
            };

        in {
          devShells.default = pkgs.mkShell {
            inherit buildInputs;

            shellHook = ''
              export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
              export PKG_CONFIG_PATH="${pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" waylandLibs}"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath waylandLibs}"
              export XDG_DATA_DIRS="$XDG_DATA_DIRS:${pkgs.monado}/share"
              export OPENXR_RUNTIME_JSON="${pkgs.monado}/share/openxr/1/openxr_monado.json"
              echo "exwm-vr dev shell ready"
              echo "  rustc: $(rustc --version)"
              echo "  emacs: $(emacs --version | head -1)"
              echo ""
              echo "  cachix: use 'cachix use exwm-vr' to enable binary cache"
            '';
          };

          # Full compositor with VR support
          packages.compositor = mkCompositor {
            pname = "ewwm-compositor";
            features = [ "full-backend" "vr" ];
            extraBuildInputs = [ pkgs.openxr-loader ];
          };

          # Headless compositor (no full-backend, no VR) for s390x / minimal
          packages.compositor-headless = mkCompositor {
            pname = "ewwm-compositor-headless";
            features = [ ];
          };

          # --- OCI container images via nix2container ---

          packages.oci-headless = n2c.buildImage {
            name = "ewwm-compositor-headless";
            tag = "latest";
            config = {
              entrypoint = [ "${self.packages.${system}.compositor-headless}/bin/ewwm-compositor" ];
              cmd = [ "--headless" ];
            };
          };

          packages.oci-compositor = n2c.buildImage {
            name = "ewwm-compositor";
            tag = "latest";
            config = {
              entrypoint = [ "${self.packages.${system}.compositor}/bin/ewwm-compositor" ];
            };
          };

          packages.oci-full = n2c.buildImage {
            name = "ewwm-compositor-full";
            tag = "latest";
            copyToRoot = [ emacsPkg ];
            config = {
              entrypoint = [ "${self.packages.${system}.compositor}/bin/ewwm-compositor" ];
            };
          };

          packages.default = self.packages.${system}.compositor;

          # Elisp package: all .el files for load-path
          packages.ewwm-elisp = pkgs.runCommand "ewwm-elisp-${version}" { } ''
            mkdir -p $out/share/emacs/site-lisp/ewwm/{core,vr,ext}
            cp ${./lisp/core}/*.el $out/share/emacs/site-lisp/ewwm/core/ 2>/dev/null || true
            cp ${./lisp/vr}/*.el $out/share/emacs/site-lisp/ewwm/vr/ 2>/dev/null || true
            cp ${./lisp/ext}/*.el $out/share/emacs/site-lisp/ewwm/ext/ 2>/dev/null || true
          '';
        } // (pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # NixOS VM integration tests (require KVM)
          checks.boot-test = import ./nix/tests/boot-test.nix {
            inherit pkgs self;
          };
          checks.full-stack-test = import ./nix/tests/full-stack-test.nix {
            inherit pkgs self home-manager;
          };
        })
      );

      # Cross-compilation outputs (not produced by eachDefaultSystem)
      crossOutputs = {
        # Cross-compile for aarch64-linux from x86_64-linux
        packages.aarch64-linux = let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            crossSystem.config = "aarch64-unknown-linux-gnu";
            overlays = [
              rust-overlay.overlays.default
            ];
          };
          waylandLibs = mkWaylandLibs pkgs;
        in {
          compositor = pkgs.rustPlatform.buildRustPackage {
            pname = "ewwm-compositor";
            inherit version;
            src = ./compositor;
            cargoLock.lockFile = ./compositor/Cargo.lock;

            nativeBuildInputs = with pkgs.buildPackages; [
              pkg-config
              clang
              llvmPackages.libclang
            ];

            buildInputs = waylandLibs ++ [ pkgs.openxr-loader ];

            buildFeatures = [ "full-backend" "vr" ];

            LIBCLANG_PATH = "${pkgs.buildPackages.llvmPackages.libclang.lib}/lib";
            LIBRARY_PATH = pkgs.lib.makeLibraryPath (waylandLibs ++ [ pkgs.openxr-loader ]);

            meta = with pkgs.lib; {
              description = "EXWM-VR Wayland compositor built on Smithay (aarch64)";
              license = licenses.gpl3Plus;
              platforms = [ "aarch64-linux" ];
            };
          };

          compositor-headless = pkgs.rustPlatform.buildRustPackage {
            pname = "ewwm-compositor-headless";
            inherit version;
            src = ./compositor;
            cargoLock.lockFile = ./compositor/Cargo.lock;

            nativeBuildInputs = with pkgs.buildPackages; [
              pkg-config
              clang
              llvmPackages.libclang
            ];

            buildInputs = waylandLibs;

            buildNoDefaultFeatures = true;

            LIBCLANG_PATH = "${pkgs.buildPackages.llvmPackages.libclang.lib}/lib";
            LIBRARY_PATH = pkgs.lib.makeLibraryPath waylandLibs;

            meta = with pkgs.lib; {
              description = "EXWM-VR Wayland compositor headless (aarch64)";
              license = licenses.gpl3Plus;
              platforms = [ "aarch64-linux" ];
            };
          };
        };

        # Cross-compile for s390x-linux from x86_64-linux
        packages.s390x-linux = let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            crossSystem.config = "s390x-unknown-linux-gnu";
            overlays = [
              rust-overlay.overlays.default
            ];
          };
          waylandLibs = mkWaylandLibs pkgs;
        in {
          compositor-headless = pkgs.rustPlatform.buildRustPackage {
            pname = "ewwm-compositor-headless";
            inherit version;
            src = ./compositor;
            cargoLock.lockFile = ./compositor/Cargo.lock;

            nativeBuildInputs = with pkgs.buildPackages; [
              pkg-config
              clang
              llvmPackages.libclang
            ];

            buildInputs = waylandLibs;

            buildNoDefaultFeatures = true;

            LIBCLANG_PATH = "${pkgs.buildPackages.llvmPackages.libclang.lib}/lib";
            LIBRARY_PATH = pkgs.lib.makeLibraryPath waylandLibs;

            meta = with pkgs.lib; {
              description = "EXWM-VR Wayland compositor headless (s390x)";
              license = licenses.gpl3Plus;
              platforms = [ "s390x-linux" ];
            };
          };
        };
      };

    in
    nixpkgs.lib.recursiveUpdate
      (nixosModuleOutputs // perSystemOutputs)
      crossOutputs;
}
