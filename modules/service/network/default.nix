{ inputs }:
{
  _class = "clan.service";
  manifest.name = "network";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Configures Flannel pod networking on a control-plane or worker node.";

    interface =
      { lib, ... }:
      {
        options.vip = inputs.self.lib.options.vip;
        options.clusterName = inputs.self.lib.options.clusterName;
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
