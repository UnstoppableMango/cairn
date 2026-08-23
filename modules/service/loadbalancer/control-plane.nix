{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.loadbalancer;
  cluster = config.cluster.cairn;
in
{
  imports = [ ../cluster.nix ];

  options.cluster.cairn.loadbalancer = (import ./options.nix { inherit lib; }) // {
    apiserverBackends = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "apiserver backend dial targets (\"ip:port\"), from the apiserver service's exports.";
    };
  };

  config = {
    # -------------------------------------------------------------------------
    # keepalived — floating VIP
    # -------------------------------------------------------------------------
    services.keepalived = {
      enable = true;
      openFirewall = true;
      vrrpInstances.VI_K8S = {
        interface = cfg.interface;
        state = "BACKUP";
        virtualRouterId = cfg.virtualRouterId;
        priority = cfg.keepalivedPriority;
        virtualIps = [ { addr = "${cluster.vip}/24"; } ];
      };
    };

    # -------------------------------------------------------------------------
    # HAProxy — LB from the VIP to the apiserver nodes
    # -------------------------------------------------------------------------
    services.haproxy = {
      enable = true;
      config = ''
        global
          log /dev/log local0
          maxconn 4000

        defaults
          log global
          mode tcp
          timeout connect 5s
          timeout client 1h
          timeout server 1h
          timeout tunnel 1h

        frontend k8s-api
          bind *:${toString cluster.apiServerPort}
          default_backend k8s-api-backend

        backend k8s-api-backend
          balance roundrobin
          option tcp-check
          ${lib.concatMapStringsSep "\n          " (
            backend: "server ${backend} ${backend} check"
          ) cfg.apiserverBackends}
      '';
    };

    networking.firewall.allowedTCPPorts = [
      cluster.apiServerPort # HAProxy (external VIP)
    ];
  };
}
