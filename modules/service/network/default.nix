{ cairnLib }:
{
  _class = "clan.service";
  manifest.name = "network";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Configures Flannel pod networking on a control-plane or worker node.";

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
