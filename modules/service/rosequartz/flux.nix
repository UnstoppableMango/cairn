{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  cfg = config.cluster.rosequartz;

  flux = inputs.a2b.legacyPackages.${system}.lib.flux;

  # gotk-components.yaml — Flux controller manifests, built at eval time via
  # `flux install --export` (no cluster access needed to generate this).
  componentsManifest = flux.install { namespace = "flux-system"; };

  # gotk-sync.yaml — GitRepository + Kustomization pointing Flux at itself.
  # the-cluster is public, so no deploy-key/secretRef is needed here.
  sourceManifest = flux.createSourceGit {
    name = "flux-system";
    namespace = "flux-system";
    url = "https://github.com/UnstoppableMango/the-cluster";
    branch = "main";
  };

  kustomizationManifest = flux.createKustomization {
    name = "flux-system";
    namespace = "flux-system";
    source = "flux-system";
    path = "./clusters/rosequartz";
    prune = true;
  };

  # Bundled the way `flux bootstrap` lays them out, so this directory can be
  # copied verbatim into the-cluster's clusters/rosequartz/flux-system once
  # the cluster is self-managing. inoculant applies raw manifest files
  # directly, so this is handed to it via `manifestFiles` rather than being
  # re-encoded as Nix attrs.
  fluxManifests = pkgs.runCommand "rosequartz-flux-manifests" { } ''
    mkdir -p $out
    cp ${componentsManifest} $out/gotk-components.yaml
    cat ${sourceManifest} ${kustomizationManifest} > $out/gotk-sync.yaml
  '';

  # nixpkgs computes these attrs (coredns, RBAC bootstrap) regardless of
  # addonManager.enable, which rosequartz keeps false. Hand them to
  # inoculant instead of running kube-addon-manager.
  addonManifests =
    config.services.kubernetes.addonManager.addons
    // config.services.kubernetes.addonManager.bootstrapAddons;
in
{
  imports = [ inputs.inoculant.nixosModules.default ];

  options.cluster.rosequartz.fluxBootstrap = {
    enable = lib.mkEnableOption "coredns + flux bootstrap via inoculant";
  };

  config = lib.mkIf cfg.fluxBootstrap.enable {
    cluster.rosequartz.pki.certs.inoculant-cert = {
      cn = "inoculant";
      org = "system:masters";
      profile = "client";
      owner = "kubernetes";
    };

    # inoculant's own module generates this cert via nixpkgs' certmgr-based
    # easyCerts flow, which rosequartz doesn't run (easyCerts = false).
    # Point it at our own cfssl-issued cert instead. `pki.certs` is a plain
    # `attrs`-typed option (not attrsOf submodule), so mkForce only takes
    # effect on the whole assignment — nested `.inoculant = mkForce {...}`
    # doesn't get unwrapped since inoculant's module also writes this key.
    services.kubernetes.pki.certs = lib.mkForce {
      inoculant = {
        cert = cfg.pki.certs."inoculant-cert".cert;
        key = cfg.pki.certs."inoculant-cert".key;
      };
    };

    services.kubernetes.inoculant = {
      enable = true;
      manifests = addonManifests;
      manifestFiles = [ fluxManifests ];
    };
  };
}
