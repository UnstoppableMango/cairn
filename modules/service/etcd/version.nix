# Pins the member's etcd to the cluster's Kubernetes minor. kubeadm ships one
# etcd version per Kubernetes minor, so a cluster held at a minor holds its
# data store with it instead of following whatever nixpkgs is locked to.
#
# kubepkgs splits etcd into server, etcdctl and etcdutl derivations where
# nixpkgs ships all three in one package, hence the separate `tools`.
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
      inherit
        (release {
          inherit lib pkgs;
          version = v;
        })
        deps
        ;
    in
    {
      # mkDefault: an explicit `versions.etcdPackage` still wins over the pin.
      cluster.cairn.etcd = {
        package = lib.mkDefault deps.etcd;
        tools = lib.mkDefault [
          deps.etcdctl
          deps.etcdutl
        ];
      };
    }
  );
}
