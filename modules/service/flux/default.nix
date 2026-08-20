{
  _class = "clan.service";
  manifest.name = "flux";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "Bootstraps Flux (GitOps) manifests via inoculant.";

    interface =
      { lib, ... }:
      {
        options.url = lib.mkOption {
          type = lib.types.str;
          default = "https://github.com/UnstoppableMango/the-cluster";
          description = "Git URL of the GitOps repository Flux syncs from.";
        };

        options.branch = lib.mkOption {
          type = lib.types.str;
          default = "main";
          description = "Branch of the GitOps repository to track.";
        };

        options.path = lib.mkOption {
          type = lib.types.str;
          default = "./clusters/cairn";
          description = "Path within the GitOps repository that Flux's root Kustomization targets.";
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ ./control-plane.nix ];
          cluster.cairn.flux = {
            inherit (settings) url branch path;
          };
        };
      };
  };
}
