{ inputs }:
{
  _class = "clan.service";
  manifest.name = "kubeconfig";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Installs an admin kubeconfig and kubectl on the machine.";

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
          cluster.cairn.kubeconfig = {
            inherit (settings) vip clusterName;
          };
        };
      };
  };
}
