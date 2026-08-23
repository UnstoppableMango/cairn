{ cairnLib }:
{
  _class = "clan.service";
  manifest.name = "kubeconfig";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Installs an admin kubeconfig and kubectl on the machine.";

    interface.options = {
      inherit (cairnLib.options) vip clusterName;
    };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ (import ./node.nix { inherit cairnLib; }) ];
          cluster.cairn = {
            inherit (settings) vip clusterName;
          };
        };
      };
  };
}
