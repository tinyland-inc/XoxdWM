{ config, lib, pkgs, ... }:

let
  cfg = config.services.exwm-vr;

  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkMerge
    types
    optional
    optionalString
    concatStringsSep
    literalExpression
    mdDoc
    ;

  # Build the Emacs package with EWWM elisp packages loaded
  emacsWithPackages = cfg.emacs.package.pkgs.emacsWithPackages (epkgs:
    cfg.emacs.extraPackages epkgs
  );

  # Compositor command line assembly
  compositorCmd = concatStringsSep " " ([
    "${cfg.compositor.package}/bin/ewwm-compositor"
  ] ++ cfg.compositor.extraArgs);

  # OpenXR runtime JSON paths by provider
  xrRuntimeJson = {
    monado = "${pkgs.monado}/share/openxr/1/openxr_monado.json";
    steamvr = "/run/current-system/sw/share/steamvr/openxr/openxr_steamvr.json";
  };

  # BrainFlow board ID mapping
  brainflowBoardId = {
    cyton = "0";
    cyton-daisy = "2";
    synthetic = "-1";
  };

  # Whether graphics support is declared in the NixOS config.
  # Handles both the legacy hardware.opengl and the newer hardware.graphics.
  hasGraphics =
    (config.hardware.graphics.enable or false)
    || (config.hardware.opengl.enable or false);

in {

  #
  # ── Interface ──────────────────────────────────────────────────────────
  #

  options.services.exwm-vr = {

    enable = mkEnableOption (mdDoc "EXWM-VR window manager");

    # ── Compositor ──────────────────────────────────────────────────────

    compositor = {
      package = mkOption {
        type = types.package;
        description = mdDoc "The ewwm-compositor package to use.";
        example = literalExpression "pkgs.ewwm-compositor";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "--log-level" "debug" "--backend" "drm" ];
        description = mdDoc ''
          Extra command-line arguments passed to the ewwm-compositor binary.
        '';
      };
    };

    # ── Emacs ───────────────────────────────────────────────────────────

    emacs = {
      package = mkOption {
        type = types.package;
        default = pkgs.emacs-pgtk;
        defaultText = literalExpression "pkgs.emacs-pgtk";
        description = mdDoc ''
          The Emacs package to use.  Must be built with pgtk (pure GTK)
          support for native Wayland rendering.
        '';
      };

      extraPackages = mkOption {
        type = types.functionTo (types.listOf types.package);
        default = _epkgs: [ ];
        defaultText = literalExpression "epkgs: [ ]";
        example = literalExpression "epkgs: [ epkgs.magit epkgs.use-package ]";
        description = mdDoc ''
          Extra Emacs packages to include in the Emacs wrapper.
          This is passed directly to `emacsWithPackages`.
        '';
      };

      initFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression "./init.el";
        description = mdDoc ''
          Path to an Emacs init file that will be loaded at startup.
          When null, Emacs loads the user's default init file.
        '';
      };
    };

    # ── VR / OpenXR ─────────────────────────────────────────────────────

    vr = {
      enable = mkEnableOption (mdDoc "OpenXR/VR subsystem");

      runtime = mkOption {
        type = types.enum [ "monado" "steamvr" ];
        default = "monado";
        description = mdDoc ''
          Which OpenXR runtime to use.

          - `monado` -- open-source OpenXR runtime (recommended)
          - `steamvr` -- Valve's SteamVR runtime
        '';
      };
    };

    # ── Eye Tracking ────────────────────────────────────────────────────

    eyeTracking = {
      enable = mkEnableOption (mdDoc "eye tracking");

      backend = mkOption {
        type = types.enum [ "pupil" "openxr" ];
        default = "pupil";
        description = mdDoc ''
          Eye-tracking data source.

          - `pupil` -- Pupil Labs Neon / Invisible via Pupil Capture
          - `openxr` -- OpenXR `XR_EXT_eye_gaze_interaction` extension
        '';
      };
    };

    # ── Brain-Computer Interface ────────────────────────────────────────

    bci = {
      enable = mkEnableOption (mdDoc "brain-computer interface");

      device = mkOption {
        type = types.enum [ "cyton" "cyton-daisy" "synthetic" ];
        default = "cyton";
        description = mdDoc ''
          OpenBCI board type for BrainFlow.

          - `cyton`       -- 8-channel Cyton board
          - `cyton-daisy` -- 16-channel Cyton + Daisy
          - `synthetic`   -- synthetic data for development/testing
        '';
      };
    };

    # ── Computed (read-only) ────────────────────────────────────────────

    requiredGroups = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = mdDoc ''
        Groups that users must belong to in order to run EXWM-VR.
        Add these to `users.users.<name>.extraGroups`.
      '';
    };
  };

  #
  # ── Implementation ─────────────────────────────────────────────────────
  #

  config = mkIf cfg.enable (mkMerge [

    # ════════════════════════════════════════════════════════════════════
    # Base configuration (always active when enable = true)
    # ════════════════════════════════════════════════════════════════════
    {
      # Computed group list ────────────────────────────────────────────
      services.exwm-vr.requiredGroups =
        [ "ewwm" "video" "input" ]
        ++ optional cfg.bci.enable "dialout";

      # Assertions ─────────────────────────────────────────────────────
      assertions = [
        {
          assertion = cfg.vr.enable -> hasGraphics;
          message = ''
            services.exwm-vr.vr.enable requires GPU support.
            Ensure hardware.graphics.enable (or hardware.opengl.enable) is true
            and that /dev/dri is present on the target machine.
          '';
        }
        {
          assertion = cfg.bci.enable -> (cfg.bci.device == "synthetic" || cfg.bci.device != "");
          message = ''
            services.exwm-vr.bci.enable requires a valid BrainFlow device.
            Add brainflow to environment.systemPackages or use
            device = "synthetic" for development.
          '';
        }
      ];

      # ── Session variables ───────────────────────────────────────────
      environment.sessionVariables = {
        XDG_CURRENT_DESKTOP = "EXWM-VR";
        XDG_SESSION_TYPE = "wayland";
        # Prefer Wayland backends for toolkit applications
        GDK_BACKEND = "wayland,x11";
        QT_QPA_PLATFORM = "wayland";
        SDL_VIDEODRIVER = "wayland";
        CLUTTER_BACKEND = "wayland";
        MOZ_ENABLE_WAYLAND = "1";
        _JAVA_AWT_WM_NONREPARENTING = "1";
        ELECTRON_OZONE_PLATFORM_HINT = "auto";
        XCURSOR_THEME = "Adwaita";
        XCURSOR_SIZE = "24";
      };

      # ── Display manager session registration ─────────────────────
      services.displayManager.sessionPackages = [
        (pkgs.runCommand "exwm-vr-session" { } ''
          mkdir -p $out/share/wayland-sessions
          cat > $out/share/wayland-sessions/exwm-vr.desktop << 'EOF'
          [Desktop Entry]
          Name=EXWM-VR
          Comment=VR-first Emacs Window Manager (Wayland)
          Exec=${cfg.compositor.package}/bin/ewwm-compositor
          TryExec=${cfg.compositor.package}/bin/ewwm-compositor
          Type=Application
          DesktopNames=EXWM-VR;
          EOF
        '')
      ];

      # ── Required system packages ────────────────────────────────────
      environment.systemPackages = [
        cfg.compositor.package
        emacsWithPackages
      ];

      # ── User groups ─────────────────────────────────────────────────
      users.groups.ewwm = { };

      # Raise the open-file limit for compositor users (GPU buffer handles).
      security.pam.loginLimits = [
        { domain = "@ewwm"; item = "nofile"; type = "soft"; value = "524288"; }
        { domain = "@ewwm"; item = "nofile"; type = "hard"; value = "524288"; }
      ];

      # ── Compositor systemd user service ─────────────────────────────
      systemd.user.services.ewwm-compositor = {
        description = "EWWM Wayland Compositor";
        documentation = [ "https://github.com/Jesssullivan/XoxdWM" ];

        wantedBy = [ "graphical-session.target" ];
        before = [ "ewwm-emacs.service" ];

        environment = {
          XDG_CURRENT_DESKTOP = "EXWM-VR";
          __EGL_VENDOR_LIBRARY_DIRS = "/run/opengl-driver/share/glvnd/egl_vendor.d";
        };

        serviceConfig = {
          ExecStart = compositorCmd;
          Restart = "on-failure";
          RestartSec = 2;
          # Hardening
          ProtectHome = "read-only";
          NoNewPrivileges = true;
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = false; # GPU JIT requires W+X pages
          SupplementaryGroups = [ "video" "input" ];
        };
      };

      # ── Emacs systemd user service ──────────────────────────────────
      systemd.user.services.ewwm-emacs = {
        description = "EWWM Emacs Window Manager Brain";
        documentation = [ "https://github.com/Jesssullivan/XoxdWM" ];

        requires = [ "ewwm-compositor.service" ];
        after = [ "ewwm-compositor.service" ];
        wantedBy = [ "graphical-session.target" ];

        environment = {
          XDG_CURRENT_DESKTOP = "EXWM-VR";
        };

        serviceConfig = let
          emacsArgs = concatStringsSep " " ([
            "${emacsWithPackages}/bin/emacs"
            "--daemon=ewwm"
          ] ++ optional (cfg.emacs.initFile != null)
            "--load ${cfg.emacs.initFile}"
          );
        in {
          ExecStart = emacsArgs;
          ExecStop = "${emacsWithPackages}/bin/emacsclient --socket-name=ewwm --eval (kill-emacs)";
          Restart = "on-failure";
          RestartSec = 3;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };
      };

      # ── Session target ──────────────────────────────────────────────
      systemd.user.targets.ewwm-session = {
        description = "EWWM-VR Session";
        requires = [ "ewwm-compositor.service" "ewwm-emacs.service" ];
        after = [ "ewwm-compositor.service" "ewwm-emacs.service" ];
        wantedBy = [ "graphical-session.target" ];
      };
    }

    # ════════════════════════════════════════════════════════════════════
    # VR / OpenXR subsystem
    # ════════════════════════════════════════════════════════════════════
    (mkIf cfg.vr.enable {
      environment.sessionVariables = {
        XR_RUNTIME_JSON = xrRuntimeJson.${cfg.vr.runtime};
      };

      environment.systemPackages = [
        pkgs.openxr-loader
      ] ++ optional (cfg.vr.runtime == "monado") pkgs.monado;

      systemd.user.services.ewwm-compositor.environment = {
        XR_RUNTIME_JSON = xrRuntimeJson.${cfg.vr.runtime};
      };

      # VR HMD udev rules: USB access + hidraw permissions
      services.udev.extraRules = ''
        # Meta Quest / Oculus
        SUBSYSTEM=="usb", ATTR{idVendor}=="2833", MODE="0664", GROUP="video", TAG+="uaccess"
        # HTC Vive
        SUBSYSTEM=="usb", ATTR{idVendor}=="0bb4", MODE="0664", GROUP="video", TAG+="uaccess"
        # Valve Index
        SUBSYSTEM=="usb", ATTR{idVendor}=="28de", MODE="0664", GROUP="video", TAG+="uaccess"
        # Generic USB audio (HMD built-in)
        SUBSYSTEM=="usb", ATTR{idVendor}=="0d8c", MODE="0664", TAG+="uaccess"
        # Bigscreen Beyond HMD (HID interface)
        KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="0101", MODE="0660", GROUP="video", TAG+="uaccess"
        # Bigscreen Bigeye eye tracking
        KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="0202", MODE="0660", GROUP="video", TAG+="uaccess"
        # Bigscreen Audio Strap
        KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="0105", MODE="0660", GROUP="video", TAG+="uaccess"
        # Bigscreen firmware update (DFU)
        KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="4004", MODE="0660", GROUP="video", TAG+="uaccess"
        # Bigscreen Beyond USB (all devices)
        SUBSYSTEM=="usb", ATTR{idVendor}=="35bd", MODE="0666"
        # Bigscreen Beyond non-desktop flag (EDID quirk workaround)
        # Note: "BIG" is the binary EDID manufacturer code (not strings-extractable).
        # We match on the product name "Beyond" which is a plain ASCII string in EDID.
        # Note: non_desktop sysfs attr only exists if kernel/driver supports it.
        ACTION=="change", SUBSYSTEM=="drm", ENV{HOTPLUG}=="1", RUN+="/bin/sh -c 'for c in /sys/class/drm/card*-DP-*/; do if [ -f $$c/edid ] && ${pkgs.binutils-unwrapped}/bin/strings $$c/edid 2>/dev/null | grep -q Beyond; then [ -w $$c/non_desktop ] && echo 1 > $$c/non_desktop 2>/dev/null; fi; done'"
        # Beyond auto power-on: trigger systemd service when HMD hidraw appears
        KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", ATTRS{idProduct}=="0101", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}="exwm-vr-beyond-power.service"
      '';

      # Beyond display power-on system service
      systemd.services.exwm-vr-beyond-power = {
        description = "Bigscreen Beyond Display Power-On";
        documentation = [ "https://github.com/Jesssullivan/XoxdWM" ];
        after = [ "systemd-udev-settle.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
          ExecStart = "${cfg.compositor.package}/libexec/beyond-power-on";
        };
      };

      # DRM lease capability for direct HMD display access
      security.wrappers.ewwm-compositor-drm = mkIf (cfg.vr.runtime == "monado") {
        source = "${cfg.compositor.package}/bin/ewwm-compositor";
        capabilities = "cap_sys_admin+ep";
        owner = "root";
        group = "video";
      };
    })

    # ════════════════════════════════════════════════════════════════════
    # Eye tracking
    # ════════════════════════════════════════════════════════════════════
    (mkIf cfg.eyeTracking.enable {
      # Pupil Labs cameras need UVC access
      services.udev.extraRules = optionalString (cfg.eyeTracking.backend == "pupil") ''
        # Pupil Labs: world + eye cameras
        SUBSYSTEM=="usb", ATTR{idVendor}=="2df1", MODE="0664", TAG+="uaccess"
        SUBSYSTEM=="video4linux", ATTR{idVendor}=="2df1", MODE="0664", TAG+="uaccess"
      '';

      systemd.user.services.ewwm-compositor.environment = {
        EWWM_EYE_TRACKING_BACKEND = cfg.eyeTracking.backend;
      };
    })

    # ════════════════════════════════════════════════════════════════════
    # BCI / BrainFlow
    # ════════════════════════════════════════════════════════════════════
    (mkIf cfg.bci.enable {
      # OpenBCI Cyton: FTDI FT2232H USB-serial chip
      services.udev.extraRules = ''
        # OpenBCI Cyton (vendor 0403, product 6015)
        SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6015", \
          MODE="0664", TAG+="uaccess", SYMLINK+="openbci_cyton"
      '';

      # BrainFlow data-acquisition service
      systemd.user.services.ewwm-brainflow = {
        description = "EWWM BrainFlow BCI Data Acquisition";
        documentation = [ "https://brainflow.readthedocs.io" ];

        after = [ "ewwm-compositor.service" ];
        wantedBy = [ "ewwm-session.target" ];

        environment = {
          BRAINFLOW_BOARD_ID = brainflowBoardId.${cfg.bci.device};
        };

        serviceConfig = {
          # The actual BrainFlow session is driven by the compositor over IPC.
          # This unit ensures the serial device is accessible and exports the
          # board-id environment variable for the compositor to read.
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          NoNewPrivileges = true;
          SupplementaryGroups = [ "dialout" ];
        };
      };
    })
  ]);
}
