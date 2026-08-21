{ cairnLib }:
{
  _class = "clan.service";
  manifest.name = "network";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Configures Flannel pod networking on a control-plane or worker node.";

    interface = {
      options.vip = cairnLib.options.vip;
      options.clusterName = cairnLib.options.clusterName;
    };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ (import ./node.nix { inherit cairnLib; }) ];
          cluster.cairn.network = {
            inherit (settings) vip clusterName;
          };
        };
      };
  };
}
