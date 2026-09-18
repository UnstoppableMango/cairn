{ cairnLib, kubepkgs }:
{ lib, ... }:
let
  versionModule = lib.modules.importApply ./version.nix { inherit kubepkgs; };
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
              appear as a Node, one that also runs an apiserver: nixpkgs
              taints a master-only machine unschedulable.

              The kubelet itself comes from the NixOS `node` role or from a
              co-located apiserver's `master` role, so `schedulable = false`
              on a machine with no apiserver leaves no kubelet running at
              all.
            '';
          };

          inherit (cairnLib.options) vip clusterName kubernetesVersion;
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
