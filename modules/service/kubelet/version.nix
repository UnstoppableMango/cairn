# Pins every Kubernetes component on this machine to a kubepkgs minor.
#
# nixpkgs' `services.kubernetes` runs apiserver, controller-manager,
# scheduler, proxy and kubelet all from one combined package, so setting it
# here (the kubelet service reaches every machine) moves the whole machine at
# once, the same shape as upgrading a kubeadm node. kubepkgs ships one
# derivation per component instead, hence the symlinkJoin. The `pause`
# passthru is what `kubelet.nix` wraps into the sandbox image; the shim is
# version-insensitive, so nixpkgs' copy serves every minor (#77).
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

  config = lib.mkIf (v != null) (
    let
      components = release {
        inherit lib pkgs;
        version = v;
      };
    in
    {
      services.kubernetes.package = pkgs.symlinkJoin {
        name = "kubernetes-${components.kubelet.version}";
        # The per-minor set carries the `sigs` and `deps` rosters alongside
        # the core binaries; only the binaries belong in the join.
        paths = lib.filter lib.isDerivation (lib.attrValues components);
        passthru.pause = pkgs.kubernetes.pause;
      };
    }
  );
}
