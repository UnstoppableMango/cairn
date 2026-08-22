{
  _class = "clan.service";
  manifest.name = "network";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Configures Flannel pod networking on a control-plane or worker node.";

    interface =
      { lib, ... }:
      let
        cairnOptions = import ../../../lib/options.nix { inherit lib; };
      in
      {
        options.vip = cairnOptions.vip;
        options.clusterName = cairnOptions.clusterName;
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
