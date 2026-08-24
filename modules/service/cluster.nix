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
