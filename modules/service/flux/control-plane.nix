{ a2b }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  cfg = config.cluster.cairn.flux;

  flux = a2b.legacyPackages.${system}.lib.flux;

  componentsManifest = flux.install { namespace = "flux-system"; };

  # Assumes the GitOps repository is public, so no deploy-key/secretRef is needed here.
  sourceManifest = flux.createSourceGit {
    name = "flux-system";
    namespace = "flux-system";
    url = cfg.url;
    branch = cfg.branch;
  };

  kustomizationManifest = flux.createKustomization {
    name = "flux-system";
    namespace = "flux-system";
    source = "flux-system";
    path = cfg.path;
    prune = true;
  };

  fluxManifests = pkgs.runCommand "cairn-flux-manifests" { } ''
    mkdir -p $out
    cp ${componentsManifest} $out/gotk-components.yaml
    cat ${sourceManifest} ${kustomizationManifest} > $out/gotk-sync.yaml
  '';

  # manifestFiles content isn't introspectable by Nix, so the bootstrap init
  # container's --allow GVK scoping (normally derived from `manifests`) has to
  # be supplied explicitly. Walk every YAML document in fluxManifests with
  # yq-go and collect the distinct apiVersion/kind pairs actually present.
  fluxManifestGVKsJson =
    pkgs.runCommand "cairn-flux-manifest-gvks.json"
      {
        nativeBuildInputs = [
          pkgs.yq-go
          pkgs.jq
        ];
      }
      ''
        yq eval-all -o=json '{"apiVersion": .apiVersion, "kind": .kind}' \
          ${fluxManifests}/gotk-components.yaml ${fluxManifests}/gotk-sync.yaml \
          | jq -s 'unique' > $out
      '';

  fluxManifestGVKs = map (
    { apiVersion, kind }:
    let
      parts = lib.splitString "/" apiVersion;
    in
    {
      group = if lib.length parts == 2 then lib.head parts else "";
      ver = lib.last parts;
      inherit kind;
    }
  ) (builtins.fromJSON (builtins.readFile fluxManifestGVKsJson));
in
{
  options.cluster.cairn.flux = import ./options.nix { inherit lib; };

  config = {
    services.kubernetes.inoculant = {
      enable = true;
      manifestFiles = [ fluxManifests ];
      additionalAllowedGVKs = fluxManifestGVKs;
    };
  };
}
