{ lib }:
{
  vip = lib.mkOption {
    type = lib.types.str;
    description = "Cluster-external VIP fronting the apiserver (keepalived-managed by the loadbalancer service).";
  };

  clusterName = lib.mkOption {
    type = lib.types.str;
    description = "Cluster name; used in TLS certificate subject names and cluster identifiers.";
  };
}
