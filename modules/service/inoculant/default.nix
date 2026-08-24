{ inoculant }:
{
  _class = "clan.service";
  manifest.name = "inoculant";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Wires inoculant's clusterAdmin cert so other services can bootstrap manifests, and applies node labels.";

    interface =
      { lib, ... }:
      {
        options.nodeLabels = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Labels applied to this node by inoculant's label-node container, covering the node-role.kubernetes.io/* labels kubelet is forbidden from setting itself.";
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ (import ./node.nix { inherit inoculant; }) ];
          services.kubernetes.inoculant.nodeLabels = settings.nodeLabels;
        };
      };
  };
}
