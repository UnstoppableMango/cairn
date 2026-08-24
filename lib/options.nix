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

  # Paired with `inventory.nodesOf`, which builds this shape from a role's
  # `machines` attrset.
  mkNodes =
    description:
    lib.mkOption {
      inherit description;
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            ip = lib.mkOption { type = lib.types.str; };
          };
        }
      );
    };
}
