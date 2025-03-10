{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.podman;

  podman-lib = import ./podman-lib.nix { inherit pkgs lib config; };

  createQuadletSource = name: volumeDef:
    let
      volumeConfig = podman-lib.deepMerge {
        Install = {
          WantedBy = optionals volumeDef.autoStart [
            "default.target"
            "multi-user.target"
          ];
        };
        Service = {
          Environment = {
            PATH = (builtins.concatStringsSep ":" [
              "${podman-lib.newuidmapPaths}"
              "${makeBinPath [ pkgs.su pkgs.coreutils ]}"
            ]);
          };
          ExecStartPre = [ "${podman-lib.awaitPodmanUnshare}" ];
          TimeoutStartSec = 15;
          RemainAfterExit = "yes";
        };
        Unit = { Description = volumeDef.description; };
        Volume = {
          Copy = volumeDef.copy;
          Device = volumeDef.device;
          Driver = volumeDef.driver;
          Group = volumeDef.group;
          Image = volumeDef.image;
          Label = volumeDef.labels // {
            "nix.home-manager.managed" = true;
            "nix.home-manager.preserve" = volumeDef.preserve;
          };
          PodmanArgs = volumeDef.extraPodmanArgs;
          Type = volumeDef.type;
          User = volumeDef.user;
          VolumeName = name;
        };
      } volumeDef.extraConfig;
    in ''
      # Automatically generated by home-manager for podman volume configuration
      # DO NOT EDIT THIS FILE DIRECTLY
      #
      # ${name}.volume
      ${podman-lib.toQuadletIni volumeConfig}
    '';

  toQuadletInternal = name: volumeDef: {
    assertions = podman-lib.buildConfigAsserts name volumeDef.extraConfig;
    serviceName =
      "podman-${name}"; # quadlet service name: 'podman-<name>-volume.service'
    source = podman-lib.removeBlankLines (createQuadletSource name volumeDef);
    resourceType = "volume";
  };

in let
  volumeDefinitionType = types.submodule ({ name, ... }: {
    options = {

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to create the volume on boot.";
      };

      copy = mkOption {
        type = types.bool;
        default = true;
        description =
          "Copy content of the image located at the mountpoint of the volume on first run.";
      };

      description = mkOption {
        type = with types; nullOr str;
        default = "Service for volume ${name}";
        defaultText = "Service for volume \${name}";
        example = "My Volume";
        description = "The description of the volume.";
      };

      device = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "tmpfs";
        description = "The path of a device which is mounted for the volume.";
      };

      driver = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "image";
        description = "The volume driver to use.";
      };

      extraConfig = mkOption {
        type = podman-lib.extraConfigType;
        default = { };
        example = literalExpression ''
          {
            Volume = {
              ContainerConfModule = "/etc/nvd.conf";
            };
          }
        '';
        description = "INI sections and values to populate the Volume Quadlet.";
      };

      extraPodmanArgs = mkOption {
        type = with types; listOf str;
        default = [ ];
        example = [ "--opt copy" ];
        description =
          "Extra arguments to pass to the podman volume create command.";
      };

      group = mkOption {
        type = with types; nullOr (either int str);
        default = null;
        description = "The group ID owning the volume inside the container.";
      };

      image = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "quay.io/centos/centos:latest";
        description =
          "Specifies the image the volume is based on when Driver is set to the image.";
      };

      labels = mkOption {
        type = with types; attrsOf str;
        default = { };
        example = {
          app = "myapp";
          some-label = "somelabel";
        };
        description = "The labels to apply to the volume.";
      };

      preserve = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the volume should be preserved if it is removed from the configuration.
          Setting this to false will cause the volume to be deleted if the volume is removed from the configuration
        '';
      };

      type = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "tmpfs";
        description =
          "Filesystem type of Device. (used as -t in mount commands)";
      };

      user = mkOption {
        type = with types; nullOr (either int str);
        default = null;
        description = "The user ID owning the volume inside the container.";
      };
    };
  });
in {
  options.services.podman.volumes = mkOption {
    type = types.attrsOf volumeDefinitionType;
    default = { };
    description = "Defines Podman volume quadlet configurations.";
  };

  config = let volumeQuadlets = mapAttrsToList toQuadletInternal cfg.volumes;
  in mkIf cfg.enable {
    services.podman.internal.quadletDefinitions = volumeQuadlets;
    assertions = flatten (map (volume: volume.assertions) volumeQuadlets);

    xdg.configFile."podman/volumes.manifest".text =
      podman-lib.generateManifestText volumeQuadlets;
  };
}
