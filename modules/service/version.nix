# The Kubernetes minor this machine runs. Declared here rather than in
# cluster.nix because etcd members pin the same minor without carrying the
# rest of the cluster-scoped options. Several role modules import this file;
# the module system keys imports by path, so the option is declared once on a
# machine that runs both a kubelet and an etcd member.
{ lib, ... }:
{
  options.cluster.cairn.kubernetesVersion = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "1.36";
    description = ''
      Kubernetes minor to run, from kubepkgs' per-minor package sets. `null`
      follows nixpkgs instead, coupling the cluster version to the nixpkgs
      pin. See docs/UPGRADES.md for how this drives rolling upgrades.
    '';
  };
}
