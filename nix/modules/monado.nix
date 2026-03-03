{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf mkMerge types;
  cfg = config.services.monado;

  # Monado's OpenXR runtime manifest
  activeRuntimeJson = pkgs.writeText "active_runtime.json" (builtins.toJSON {
    file_format_version = "1.0.0";
    runtime = {
      name = "monado";
      library_path = "${cfg.package}/lib/libopenxr_monado.so";
    };
  });

  # Environment variables common to all headset modes
  baseEnv = {
    XR_RUNTIME_JSON = "${cfg.package}/share/openxr/1/openxr_monado.json";
  };

  # Extra environment variables per headset mode
  headsetEnv = {
    "auto" = { };
    "simulated" = {
      XRT_COMPOSITOR_FORCE_HEADLESS = "1";
    };
    "valve-index" = { };
    "quest3-wivrn" = { };
    "bigscreen-beyond" = {
      XRT_COMPOSITOR_DESIRED_MODE = "1";  # 90 Hz native for Beyond 2/2e
      P_OVERRIDE_ACTIVE_CONFIG = "Bigscreen Beyond";
    };
  };

  serviceEnv = baseEnv // headsetEnv.${cfg.headset};

in
{
  options.services.monado = {
    enable = mkEnableOption "Monado OpenXR runtime";

    package = mkOption {
      type = types.package;
      default = pkgs.monado;
      defaultText = lib.literalExpression "pkgs.monado";
      description = "The Monado package to use.";
    };

    headset = mkOption {
      type = types.enum [ "auto" "simulated" "valve-index" "quest3-wivrn" "bigscreen-beyond" ];
      default = "auto";
      description = ''
        Headset driver selection.

        - `auto`: let Monado probe for connected hardware.
        - `simulated`: force headless compositor (no HMD required).
        - `valve-index`: Valve Index via SteamVR/Lighthouse.
        - `quest3-wivrn`: Meta Quest 3 via WiVRn streaming.
        - `bigscreen-beyond`: Bigscreen Beyond (1, 2, 2e) via USB.
      '';
    };

    wivrn = {
      enable = mkEnableOption "WiVRn streaming for Quest headsets";

      package = mkOption {
        type = types.package;
        default = pkgs.wivrn or (builtins.throw
          "pkgs.wivrn is not available in your nixpkgs; provide services.monado.wivrn.package explicitly");
        defaultText = lib.literalExpression "pkgs.wivrn";
        description = "The WiVRn package to use.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [

    # ---- Core: monado service, socket, runtime manifest, session vars ----
    {
      systemd.user.services.monado = {
        description = "Monado OpenXR runtime service";
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.package}/bin/monado-service";
          Restart = "on-failure";
          RestartSec = 3;
          Environment = lib.mapAttrsToList (k: v: "${k}=${v}") serviceEnv;
        };
      };

      systemd.user.sockets.monado = {
        description = "Monado OpenXR IPC socket";
        wantedBy = [ "sockets.target" ];

        socketConfig = {
          ListenStream = "%t/monado_comp_ipc";
        };
      };

      # Install the active_runtime.json so OpenXR loaders discover Monado
      environment.etc."xdg/openxr/1/active_runtime.json".source = activeRuntimeJson;

      # Session-wide variable so every process finds the runtime
      environment.sessionVariables.XR_RUNTIME_JSON =
        "${cfg.package}/share/openxr/1/openxr_monado.json";
    }

    # ---- Quest 3 + WiVRn ----
    (mkIf (cfg.headset == "quest3-wivrn" || cfg.wivrn.enable) {
      systemd.user.services.wivrn-server = {
        description = "WiVRn streaming server for Quest headsets";
        after = [ "monado.service" ];
        bindsTo = [ "monado.service" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.wivrn.package}/bin/wivrn-server";
          Restart = "on-failure";
          RestartSec = 5;
          Environment = lib.mapAttrsToList (k: v: "${k}=${v}") baseEnv;
        };

        wantedBy = [ "monado.service" ];
      };
    })

    # ---- Simulated headset: force headless ----
    (mkIf (cfg.headset == "simulated") {
      environment.sessionVariables.XRT_COMPOSITOR_FORCE_HEADLESS = "1";
    })

  ]);
}
