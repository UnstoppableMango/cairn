{ cairnLib }:
{
  _class = "clan.service";
  manifest.name = "kubeconfig";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Installs an admin kubeconfig and kubectl on the machine.";

    interface = {
      options.vip = cairnLib.options.vip;
      options.clusterName = cairnLib.options.clusterName;
    };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ (import ./node.nix { inherit cairnLib; }) ];
          cluster.cairn.kubeconfig = {
            inherit (settings) vip clusterName;
          };
        };
      };
  };
}
