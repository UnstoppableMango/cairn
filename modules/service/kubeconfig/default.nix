{ cairnLib, kubepkgs }:
{ lib, ... }:
let
  versionModule = lib.modules.importApply ./version.nix { inherit kubepkgs; };
in
{
  _class = "clan.service";
  manifest.name = "kubeconfig";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Installs an admin kubeconfig and kubectl on the machine.";

    interface.options = {
      inherit (cairnLib.options) vip clusterName kubernetesVersion;
    };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [
            (import ./node.nix { inherit cairnLib; })
            versionModule
          ];
          cluster.cairn = {
            inherit (settings) vip clusterName kubernetesVersion;
          };
        };
      };
  };
}
