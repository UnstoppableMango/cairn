{
  _class = "clan.service";
  manifest.name = "kubeconfig";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Installs an admin kubeconfig and kubectl on the machine.";

    interface =
      { lib, ... }:
      {
        options.vip = lib.mkOption {
          type = lib.types.str;
          description = "Cluster-external VIP fronting the apiserver.";
        };

        options.clusterName = lib.mkOption {
          type = lib.types.str;
          description = "Cluster name; used in the kubeconfig context.";
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ ./node.nix ];
          cluster.cairn.kubeconfig = {
            inherit (settings) vip clusterName;
          };
        };
      };
  };
}
