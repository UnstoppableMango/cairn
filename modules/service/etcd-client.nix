# The etcd client certificate, declared where both of its consumers can see
# it. The apiserver dials etcd with it, and etcd's own `etcdctl` uses it, so
# it belongs to neither service alone. It is shared cluster-wide, so every
# machine importing this gets the same material.
{ config, ... }:
{
  imports = [ ./admin.nix ];

  cluster.cairn.pki.certs.etcd-client-cert = {
    cn = "kube-apiserver-etcd-client";
    profile = "client";
    owner = "kubernetes";
    group = config.cluster.cairn.adminGroup;
  };

  # nixpkgs creates this account only on machines with a Kubernetes role, and
  # sops-install-secrets rejects the whole manifest if an owner is missing.
  users.users.kubernetes = {
    uid = config.ids.uids.kubernetes;
    group = "kubernetes";
  };
  users.groups.kubernetes.gid = config.ids.gids.kubernetes;
}
