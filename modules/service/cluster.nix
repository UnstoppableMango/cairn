# Cluster-wide facts every service needs to agree on, declared once instead of
# once per service. Imported by path from each role's NixOS module, so the
# module system collapses the repeated imports into a single declaration.
#
# `vip` and `clusterName` are `types.str`, which merges definitions that agree
# and errors on ones that don't — so several services all forwarding the same
# inventory setting is fine, while two instances disagreeing about the cluster's
# VIP on one machine is caught at eval time.
{ config, lib, ... }:
let
  cfg = config.cluster.cairn;

  cairnOptions = import ../../lib/options.nix { inherit lib; };
in
{
  options.cluster.cairn = {
    inherit (cairnOptions) vip clusterName;

    apiServerPort = lib.mkOption {
      type = lib.types.port;
      default = 6443;
      description = "Port the apiserver is reached on at the VIP (what loadbalancer's HAProxy binds).";
    };

    apiServerURL = lib.mkOption {
      type = lib.types.str;
      default = "https://${cfg.vip}:${toString cfg.apiServerPort}";
      description = "External URL for the apiserver, fronted by the loadbalancer at the VIP.";
    };
  };
}
