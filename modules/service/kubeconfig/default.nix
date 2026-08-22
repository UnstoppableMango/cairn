{
  _class = "clan.service";
  manifest.name = "kubeconfig";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Installs an admin kubeconfig and kubectl on the machine.";

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
          cluster.cairn.kubeconfig = {
            inherit (settings) vip clusterName;
          };
        };
      };
  };
}
