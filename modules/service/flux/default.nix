{ a2b }:
{
  _class = "clan.service";
  manifest.name = "flux";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "Bootstraps Flux (GitOps) manifests via inoculant.";

    interface =
      { lib, ... }:
      {
        options = import ./options.nix { inherit lib; };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ (import ./control-plane.nix { inherit a2b; }) ];
          cluster.cairn.flux = {
            inherit (settings) url branch path;
          };
        };
      };
  };
}
