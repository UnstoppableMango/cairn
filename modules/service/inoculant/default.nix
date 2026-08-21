{ inoculant }:
{
  _class = "clan.service";
  manifest.name = "inoculant";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Wires inoculant's clusterAdmin cert so other services can bootstrap manifests.";
    perInstance.nixosModule = import ./node.nix { inherit inoculant; };
  };
}
