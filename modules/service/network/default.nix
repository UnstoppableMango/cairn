{
  _class = "clan.service";
  manifest.name = "network";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Configures Flannel pod networking on a control-plane or worker node.";

    interface =
      { lib, ... }:
      {
        options.vip = lib.mkOption {
          type = lib.types.str;
          description = "Cluster-external VIP fronting the apiserver.";
        };

        options.clusterName = lib.mkOption {
          type = lib.types.str;
          description = "Cluster name; used in the flannel kubeconfig context.";
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ ./node.nix ];
          cluster.cairn.network = {
            inherit (settings) vip clusterName;
          };
        };
      };
  };
}
