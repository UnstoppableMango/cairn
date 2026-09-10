# Pins every Kubernetes component on this machine to a kubepkgs minor.
#
# nixpkgs' `services.kubernetes` runs apiserver, controller-manager,
# scheduler, proxy and kubelet all from one combined package, so setting it
# here (the kubelet service reaches every machine) moves the whole machine at
# once, the same shape as upgrading a kubeadm node. kubepkgs ships one
# derivation per component instead, hence the symlinkJoin. The `pause`
# passthru is what `kubelet.nix` wraps into the sandbox image; the shim is
# version-insensitive, so nixpkgs' copy serves every minor.
{ kubepkgs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  v = config.cluster.cairn.kubernetesVersion;
  releases = kubepkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.kubernetes;
  supported = lib.remove "latest" (lib.attrNames releases);
in
{
  options.cluster.cairn.kubernetesVersion = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "1.36";
    description = ''
      Kubernetes minor to run, from kubepkgs' per-minor package sets. `null`
      follows nixpkgs' `pkgs.kubernetes` instead, coupling the cluster
      version to the nixpkgs pin. See docs/UPGRADES.md for how this drives
      rolling upgrades.
    '';
  };

  config = lib.mkIf (v != null) {
    services.kubernetes.package =
      lib.throwIfNot (releases ? ${v})
        "cluster.cairn.kubernetesVersion: kubepkgs does not ship ${v}; supported minors are ${lib.concatStringsSep ", " supported}."
        pkgs.symlinkJoin
        {
          name = "kubernetes-${releases.${v}.kubelet.version}";
          paths = lib.filter lib.isDerivation (lib.attrValues releases.${v});
          passthru.pause = pkgs.kubernetes.pause;
        };
  };
}
