{ cairnLib, kubepkgs }:
{ lib, ... }:
let
  controlPlane = lib.modules.importApply ./control-plane.nix { inherit kubepkgs; };
in
{
  _class = "clan.service";
  manifest.name = "metrics-server";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "Bootstraps metrics-server manifests via inoculant.";

    interface =
      { lib, ... }:
      {
        options = {
          inherit (cairnLib.options) kubernetesVersion;
        };
      };

    perInstance =
      { settings, roles, ... }:
      {
        nixosModule = {
          imports = [ controlPlane ];
          cluster.cairn = {
            inherit (settings) kubernetesVersion;
            # Same default as coredns: the machines bootstrapping the
            # manifests are the right guess, and the cluster option tree can
            # name the nodes outright once the two sets diverge.
            metricsServer.nodeNames = lib.mkDefault (lib.attrNames roles.control-plane.machines);
          };
        };
      };
  };
}
