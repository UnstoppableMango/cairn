# Who may run etcdctl and kubectl as themselves. The group reads the etcd
# client key, the admin kubeconfig and the admin key, which is the whole of
# root's access to the cluster, so it belongs to people who could reach it
# through sudo anyway. Imported by every role that hands out one of those.
{ lib, ... }:
{
  options.cluster.cairn.adminGroup = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = "wheel";
    description = ''
      Group allowed to read the etcd client key and the admin kubeconfig, so
      its members run `etcdctl` and `kubectl` without sudo. `null` leaves
      them readable by their owners alone.
    '';
  };
}
