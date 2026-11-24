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
            # The bootstrapping machines are the default, which is wrong once the two sets diverge.
            coredns.nodeNames = lib.mkDefault (lib.attrNames roles.control-plane.machines);
          };
        };
      };
  };
}
