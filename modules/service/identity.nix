# The cluster's own name, the one cluster-wide fact that says nothing about
# reaching the apiserver. It is split out of ./cluster.nix so a machine that
# holds cluster state without serving the API, an etcd member on its own
# machine, can name its cluster without a `vip` it has no use for.
{ lib, ... }:
let
  cairnOptions = import ../../lib/options.nix { inherit lib; };
in
{
  options.cluster.cairn = {
    inherit (cairnOptions) clusterName;
  };
}
