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
          # Where CoreDNS pods may land. The machines bootstrapping the
          # manifests are the right guess and the wrong answer once the two
          # sets diverge, so the cluster option tree can name them outright.
          cluster.cairn.coredns.nodeNames = lib.mkDefault (lib.attrNames roles.control-plane.machines);
        };
      };
  };
}
