# nixpkgs runs every Kubernetes component from one combined package, which kubepkgs' `kubernetes` matches, `pause` passthru included, so the whole machine moves at once like a kubeadm node.
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
