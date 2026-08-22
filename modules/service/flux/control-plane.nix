{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  cfg = config.cluster.cairn.flux;

  flux = inputs.a2b.legacyPackages.${system}.lib.flux;

  # gotk-components.yaml — Flux controller manifests, built at eval time via
  # `flux install --export` (no cluster access needed to generate this).
  componentsManifest = flux.install { namespace = "flux-system"; };

  # gotk-sync.yaml — GitRepository + Kustomization pointing Flux at itself.
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

  # Bundled the way `flux bootstrap` lays them out, so this directory can be
  # copied verbatim into the GitOps repository's flux-system path once
  # the cluster is self-managing. inoculant applies raw manifest files
  # directly, so this is handed to it via `manifestFiles` rather than being
  # re-encoded as Nix attrs.
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
  options.cluster.cairn.flux = {
    url = lib.mkOption {
      type = lib.types.str;
      description = "Git URL of the GitOps repository Flux syncs from.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch of the GitOps repository to track.";
    };

    path = lib.mkOption {
      type = lib.types.str;
      default = "./clusters/cairn";
      description = "Path within the GitOps repository that Flux's root Kustomization targets.";
    };
  };

  config = {
    services.kubernetes.inoculant = {
      enable = true;
      manifestFiles = [ fluxManifests ];
      additionalAllowedGVKs = fluxManifestGVKs;
    };
  };
}
