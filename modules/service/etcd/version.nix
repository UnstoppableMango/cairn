# kubeadm ships one etcd per Kubernetes minor, so a cluster held at a minor holds its data store with it.
# kubepkgs splits out etcdctl and etcdutl, hence the separate `tools`.
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
