# The etcd client certificate, declared where both of its consumers can see
# it. The apiserver dials etcd with it, and etcd's own `etcdctl` uses it, so
# it belongs to neither service alone. It is shared cluster-wide, so every
# machine importing this gets the same material.
{
  cluster.cairn.pki.certs.etcd-client-cert = {
    cn = "kube-apiserver-etcd-client";
    profile = "client";
    owner = "kubernetes";
  };
}
