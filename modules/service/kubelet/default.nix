{ cairnLib, kubepkgs }:
{ lib, ... }:
let
  versionModule = lib.modules.importApply ./version.nix { inherit kubepkgs; };

  kubernetesVersion =
    { lib, ... }:
    {
      options.kubernetesVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "1.36";
        description = ''
          Kubernetes minor to run on this machine, from kubepkgs' per-minor
          package sets. `null` follows nixpkgs' `pkgs.kubernetes`. Every
          component on the machine moves together; see docs/UPGRADES.md.
        '';
      };
    };
in
{
  _class = "clan.service";
  manifest.name = "kubelet";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "kubelet running alongside kube-apiserver on a control-plane node.";

    interface =
      { lib, ... }:
      {
        imports = [ kubernetesVersion ];

        options.ip = lib.mkOption {
          type = lib.types.str;
          description = "IP address of this control-plane node.";
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [
            ./common.nix
            versionModule
          ];
          cluster.cairn.kubelet.advertiseAddress = settings.ip;
          cluster.cairn.kubernetesVersion = settings.kubernetesVersion;
        };
      };
  };

  roles.worker = {
    description = "kubelet running on a worker (node-only) machine.";

    interface =
      { lib, ... }:
      {
        imports = [ kubernetesVersion ];

        options = {
          ip = lib.mkOption {
            type = lib.types.str;
            description = "IP address of this worker node.";
          };

          inherit (cairnLib.options) vip clusterName;
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [
            ./worker.nix
            versionModule
          ];
          cluster.cairn = {
            inherit (settings) vip clusterName;
            kubelet.advertiseAddress = settings.ip;
            kubernetesVersion = settings.kubernetesVersion;
          };
        };
      };
  };
}
