# Pins every Kubernetes component on this machine to a kubepkgs minor.
#
# nixpkgs' `services.kubernetes` runs apiserver, controller-manager,
# scheduler, proxy and kubelet all from one combined package, so setting it
# here (the kubelet service reaches every machine) moves the whole machine at
# once, the same shape as upgrading a kubeadm node. kubepkgs ships one
# derivation per component, and joins them into `kubernetes` in exactly that
# combined shape, with the `pause` passthru `kubelet.nix` wraps into the
# sandbox image. The whole closure therefore comes from kubepkgs.
{ kubepkgs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  release = import ../releases.nix { inherit kubepkgs; };
  v = config.cluster.cairn.kubernetesVersion;
in
{
  imports = [ ../version.nix ];

  config = lib.mkIf (v != null) {
    services.kubernetes.package =
      (release {
        inherit lib pkgs;
        version = v;
      }).kubernetes;
  };
}
