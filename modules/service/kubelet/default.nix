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

  roles.node = {
    description = "Kubernetes node: a kubelet, schedulable or not.";

    interface =
      { lib, ... }:
      {
        imports = [ kubernetesVersion ];

        options = {
          ip = lib.mkOption {
            type = lib.types.str;
            description = "IP address of this node.";
          };

          schedulable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Give the machine the NixOS `node` role, so pods can schedule
              onto it. Set it false on a machine that runs a kubelet only to
              appear as a Node, typically one that also runs an apiserver:
              nixpkgs taints a master-only machine unschedulable.
            '';
          };

          inherit (cairnLib.options) vip clusterName;
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [
            ./node.nix
            versionModule
          ];
          cluster.cairn = {
            inherit (settings) vip clusterName;
            kubelet = {
              advertiseAddress = settings.ip;
              inherit (settings) schedulable;
            };
            kubernetesVersion = settings.kubernetesVersion;
          };
        };
      };
  };
}
