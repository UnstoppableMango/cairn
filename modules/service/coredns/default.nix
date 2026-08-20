{
  _class = "clan.service";
  manifest.name = "coredns";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "Bootstraps CoreDNS manifests via inoculant.";

    perInstance =
      { lib, roles, ... }:
      {
        nixosModule = {
          imports = [ ./control-plane.nix ];
          cluster.cairn.coredns.nodeNames = lib.attrNames roles.control-plane.machines;
        };
      };
  };
}
