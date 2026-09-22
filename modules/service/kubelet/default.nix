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

          maxPods = lib.mkOption {
            type = lib.types.ints.positive;
            default = 110;
            description = ''
              Pods this kubelet will admit. The node's podCIDR is the
              ceiling: a /24 leaves 254 addresses.
            '';
          };

          systemReserved = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = {
              cpu = "2";
              memory = "2Gi";
            };
            description = ''
              Resources withheld from pods for the kernel, the container
              runtime, and anything else this machine runs. Subtracted from
              capacity to give allocatable, which is what the scheduler
              places against.
            '';
          };

          kubeReserved = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = {
              cpu = "1";
              memory = "1Gi";
            };
            description = ''
              Resources withheld for the kubelet and the container runtime
              themselves.
            '';
          };

          evictionHard = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = {
              "memory.available" = "1Gi";
            };
            description = ''
              Thresholds at which this kubelet evicts pods with no grace
              period. The memory threshold also subtracts from allocatable.
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
              inherit (settings)
                schedulable
                maxPods
                systemReserved
                kubeReserved
                evictionHard
                ;
            };
            kubernetesVersion = settings.kubernetesVersion;
          };
        };
      };
  };
}
