{ cairnLib, kubepkgs }:
{ lib, ... }:
let
  controlPlane = lib.modules.importApply ./control-plane.nix { inherit kubepkgs; };
in
{
  _class = "clan.service";
  manifest.name = "coredns";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "Bootstraps CoreDNS manifests via inoculant.";

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
            # Where CoreDNS pods may land. The machines bootstrapping the
            # manifests are the right guess and the wrong answer once the two
            # sets diverge, so the cluster option tree can name them outright.
            coredns.nodeNames = lib.mkDefault (lib.attrNames roles.control-plane.machines);
          };
        };
      };
  };
}
