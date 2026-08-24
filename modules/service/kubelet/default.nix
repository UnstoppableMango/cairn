{ cairnLib }:
{
  _class = "clan.service";
  manifest.name = "kubelet";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "kubelet running alongside kube-apiserver on a control-plane node.";

    interface =
      { lib, ... }:
      {
        options.ip = lib.mkOption {
          type = lib.types.str;
          description = "IP address of this control-plane node.";
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ ./common.nix ];
          cluster.cairn.kubelet.advertiseAddress = settings.ip;
        };
      };
  };

  roles.worker = {
    description = "kubelet running on a worker (node-only) machine.";

    interface =
      { lib, ... }:
      {
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
          imports = [ ./worker.nix ];
          cluster.cairn = {
            inherit (settings) vip clusterName;
            kubelet.advertiseAddress = settings.ip;
          };
        };
      };
  };
}
