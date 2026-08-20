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
          imports = [ ./control-plane.nix ];
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

        options.vip = lib.mkOption {
          type = lib.types.str;
          description = "Cluster-external VIP fronting the apiserver.";
        };

        options.clusterName = lib.mkOption {
          type = lib.types.str;
          description = "Cluster name; used in TLS certificate subject names.";
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ ./worker.nix ];
          cluster.cairn.kubelet = {
            inherit (settings) vip clusterName;
            advertiseAddress = settings.ip;
          };
        };
      };
  };
}
