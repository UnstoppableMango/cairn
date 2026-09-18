{ lib }:
{
  vip = lib.mkOption {
    type = lib.types.str;
    description = "Cluster-external VIP fronting the apiserver (keepalived-managed by the loadbalancer service).";
  };

  kubernetesVersion = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "1.36";
    description = ''
      Kubernetes minor this machine runs, from kubepkgs' per-minor package
      sets. `null` follows nixpkgs. Every component on the machine moves
      together, etcd included; see docs/UPGRADES.md.
    '';
  };

  clusterName = lib.mkOption {
    type = lib.types.str;
    description = "Cluster name; used in TLS certificate subject names and cluster identifiers.";
  };

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
