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
        options.ip = lib.mkOption {
          type = lib.types.str;
          description = "IP address of this worker node.";
        };

        options.vip = cairnLib.options.vip;
        options.clusterName = cairnLib.options.clusterName;
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ (import ./worker.nix { inherit cairnLib; }) ];
          cluster.cairn.kubelet = {
            inherit (settings) vip clusterName;
            advertiseAddress = settings.ip;
          };
        };
      };
  };
}
